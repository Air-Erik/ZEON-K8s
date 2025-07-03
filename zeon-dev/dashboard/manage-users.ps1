#!/usr/bin/env powershell
# Kubernetes Dashboard User Management Script
# Управление пользователями Kubernetes Dashboard

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("add", "remove", "list", "token")]
    [string]$Action,

    [string]$UserName,

    [ValidateSet("view", "edit", "admin", "cluster-admin")]
    [string]$Role = "edit",

    [string]$Namespace = "kubernetes-dashboard",

    [switch]$Force = $false
)

# Функция для вывода цветного текста
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )

    switch ($Color) {
        "Red" { Write-Host $Message -ForegroundColor Red }
        "Green" { Write-Host $Message -ForegroundColor Green }
        "Yellow" { Write-Host $Message -ForegroundColor Yellow }
        "Blue" { Write-Host $Message -ForegroundColor Blue }
        "Cyan" { Write-Host $Message -ForegroundColor Cyan }
        "Magenta" { Write-Host $Message -ForegroundColor Magenta }
        default { Write-Host $Message }
    }
}

# Функция для проверки, существует ли ресурс
function Test-KubernetesResource {
    param(
        [string]$ResourceType,
        [string]$ResourceName,
        [string]$Namespace = $null
    )

    $cmd = if ($Namespace) {
        "kubectl get $ResourceType $ResourceName -n $Namespace --ignore-not-found"
    } else {
        "kubectl get $ResourceType $ResourceName --ignore-not-found"
    }

    $result = Invoke-Expression $cmd 2>$null
    return $result -ne $null -and $result.Length -gt 0
}

# Функция для создания YAML манифеста секрета
function New-SecretManifest {
    param(
        [string]$UserName,
        [string]$Namespace
    )

    return @"
apiVersion: v1
kind: Secret
metadata:
  name: $UserName-token
  namespace: $Namespace
  annotations:
    kubernetes.io/service-account.name: $UserName
type: kubernetes.io/service-account-token
"@
}

# Функция для создания необходимых папок
function Initialize-DirectoryStructure {
    if (-not (Test-Path "tokens")) {
        New-Item -ItemType Directory -Path "tokens" -Force | Out-Null
    }

    if (-not (Test-Path "manifests")) {
        New-Item -ItemType Directory -Path "manifests" -Force | Out-Null
    }
}

# Функция для добавления пользователя
function Add-DashboardUser {
    param(
        [string]$UserName,
        [string]$Role,
        [string]$Namespace
    )

    Write-ColorOutput "➕ Добавляем пользователя: $UserName" "Blue"

    # Создаём структуру папок
    Initialize-DirectoryStructure

    # Проверяем, что пользователь не существует
    if (Test-KubernetesResource "serviceaccount" $UserName $Namespace) {
        if (-not $Force) {
            Write-ColorOutput "❌ Пользователь $UserName уже существует! Используйте -Force для пересоздания." "Red"
            return $false
        } else {
            Write-ColorOutput "🔄 Пересоздаём пользователя $UserName" "Yellow"
            Remove-DashboardUser -UserName $UserName -Namespace $Namespace
        }
    }

    # Создаём ServiceAccount
    Write-ColorOutput "  └── Создаём ServiceAccount..." "Cyan"
    kubectl create serviceaccount $UserName -n $Namespace

    if ($LASTEXITCODE -ne 0) {
        Write-ColorOutput "    ❌ Ошибка создания ServiceAccount" "Red"
        return $false
    }

    # Создаём ClusterRoleBinding
    $bindingName = "$UserName-binding"
    Write-ColorOutput "  └── Создаём ClusterRoleBinding ($Role)..." "Cyan"
    kubectl create clusterrolebinding $bindingName `
        --clusterrole=$Role `
        --serviceaccount="$Namespace`:$UserName"

    if ($LASTEXITCODE -ne 0) {
        Write-ColorOutput "    ❌ Ошибка создания ClusterRoleBinding" "Red"
        return $false
    }

    # Создаём Secret для токена
    $secretName = "$UserName-token"
    $secretFile = "manifests/secret.$UserName.yaml"

    Write-ColorOutput "  └── Создаём Secret для токена..." "Cyan"
    $secretContent = New-SecretManifest -UserName $UserName -Namespace $Namespace
    $secretContent | Out-File -FilePath $secretFile -Encoding UTF8

    kubectl apply -f $secretFile

    if ($LASTEXITCODE -ne 0) {
        Write-ColorOutput "    ❌ Ошибка создания Secret" "Red"
        return $false
    }

    # Получаем токен
    Write-ColorOutput "  └── Получаем токен..." "Cyan"
    Start-Sleep -Seconds 3

    $maxRetries = 10
    $retryCount = 0

    do {
        $token = kubectl get secret $secretName -n $Namespace -o "go-template={{.data.token | base64decode}}" 2>$null

        if ($token -and $token.Length -gt 10) {
            $tokenFile = "tokens/$UserName-token.txt"
            $token | Out-File -FilePath $tokenFile -Encoding UTF8 -NoNewline
            Write-ColorOutput "    ✅ Токен сохранён в $tokenFile" "Green"
            break
        } else {
            $retryCount++
            Write-ColorOutput "    ⏳ Ждём генерации токена (попытка $retryCount/$maxRetries)" "Yellow"
            Start-Sleep -Seconds 2
        }
    } while ($retryCount -lt $maxRetries)

    if ($retryCount -eq $maxRetries) {
        Write-ColorOutput "    ❌ Не удалось получить токен" "Red"
        return $false
    }

    Write-ColorOutput "✅ Пользователь $UserName успешно добавлен!" "Green"
    return $true
}

# Функция для удаления пользователя
function Remove-DashboardUser {
    param(
        [string]$UserName,
        [string]$Namespace
    )

    Write-ColorOutput "🗑️  Удаляем пользователя: $UserName" "Blue"

    # Удаляем ServiceAccount
    if (Test-KubernetesResource "serviceaccount" $UserName $Namespace) {
        Write-ColorOutput "  └── Удаляем ServiceAccount..." "Cyan"
        kubectl delete serviceaccount $UserName -n $Namespace
    }

    # Удаляем ClusterRoleBinding
    $bindingName = "$UserName-binding"
    if (Test-KubernetesResource "clusterrolebinding" $bindingName) {
        Write-ColorOutput "  └── Удаляем ClusterRoleBinding..." "Cyan"
        kubectl delete clusterrolebinding $bindingName
    }

    # Удаляем Secret
    $secretName = "$UserName-token"
    if (Test-KubernetesResource "secret" $secretName $Namespace) {
        Write-ColorOutput "  └── Удаляем Secret..." "Cyan"
        kubectl delete secret $secretName -n $Namespace
    }

    # Удаляем файлы
    $secretFile = "manifests/secret.$UserName.yaml"
    $tokenFile = "tokens/$UserName-token.txt"

    if (Test-Path $secretFile) {
        Write-ColorOutput "  └── Удаляем файл манифеста..." "Cyan"
        Remove-Item $secretFile
    }

    if (Test-Path $tokenFile) {
        Write-ColorOutput "  └── Удаляем файл токена..." "Cyan"
        Remove-Item $tokenFile
    }

    Write-ColorOutput "✅ Пользователь $UserName удалён!" "Green"
}

# Функция для получения токена пользователя
function Get-UserToken {
    param(
        [string]$UserName,
        [string]$Namespace
    )

    $secretName = "$UserName-token"
    $tokenFile = "tokens/$UserName-token.txt"

    # Создаём папку если её нет
    Initialize-DirectoryStructure

    # Проверяем, что пользователь существует
    if (-not (Test-KubernetesResource "serviceaccount" $UserName $Namespace)) {
        Write-ColorOutput "❌ Пользователь $UserName не найден!" "Red"
        return
    }

    # Получаем токен
    Write-ColorOutput "🔑 Получаем токен для пользователя: $UserName" "Blue"

    $token = kubectl get secret $secretName -n $Namespace -o "go-template={{.data.token | base64decode}}" 2>$null

    if ($token -and $token.Length -gt 10) {
        $token | Out-File -FilePath $tokenFile -Encoding UTF8 -NoNewline
        Write-ColorOutput "✅ Токен сохранён в $tokenFile" "Green"

        # Показываем первые и последние символы токена
        $tokenPreview = $token.Substring(0, 20) + "..." + $token.Substring($token.Length - 20)
        Write-ColorOutput "🔍 Превью токена: $tokenPreview" "Cyan"
    } else {
        Write-ColorOutput "❌ Не удалось получить токен для $UserName" "Red"
    }
}

# Функция для отображения списка пользователей
function Get-DashboardUsers {
    param(
        [string]$Namespace
    )

    Write-ColorOutput "👥 Список пользователей Dashboard:" "Blue"
    Write-ColorOutput "=====================================" "Blue"

    # Получаем все ServiceAccount'ы в namespace
    $serviceAccounts = kubectl get serviceaccount -n $Namespace -o jsonpath='{.items[*].metadata.name}' 2>$null

    if (-not $serviceAccounts) {
        Write-ColorOutput "❌ Не найдено ServiceAccount'ов в namespace $Namespace" "Red"
        return
    }

    $users = $serviceAccounts -split ' ' | Where-Object { $_ -notmatch '^default$|^kubernetes-dashboard' }

    if ($users.Count -eq 0) {
        Write-ColorOutput "📭 Пользователи не найдены" "Yellow"
        return
    }

    foreach ($user in $users) {
        Write-ColorOutput "🔹 $user" "Cyan"

        # Получаем роль из ClusterRoleBinding
        $bindingName = "$user-binding"
        $roleInfo = kubectl get clusterrolebinding $bindingName -o jsonpath='{.roleRef.name}' 2>$null

        if ($roleInfo) {
            Write-ColorOutput "   └── Роль: $roleInfo" "White"
        } else {
            Write-ColorOutput "   └── Роль: не найдена" "Yellow"
        }

        # Проверяем наличие токена
        $tokenFile = "tokens/$user-token.txt"
        if (Test-Path $tokenFile) {
            $tokenLength = (Get-Content $tokenFile -Raw).Length
            Write-ColorOutput "   └── Токен: есть (длина: $tokenLength символов)" "Green"
        } else {
            Write-ColorOutput "   └── Токен: отсутствует" "Red"
        }

        # Проверяем статус Secret
        $secretName = "$user-token"
        if (Test-KubernetesResource "secret" $secretName $Namespace) {
            Write-ColorOutput "   └── Secret: существует" "Green"
        } else {
            Write-ColorOutput "   └── Secret: отсутствует" "Red"
        }

        # Проверяем наличие манифеста
        $secretFile = "manifests/secret.$user.yaml"
        if (Test-Path $secretFile) {
            Write-ColorOutput "   └── Манифест: есть" "Green"
        } else {
            Write-ColorOutput "   └── Манифест: отсутствует" "Yellow"
        }

        Write-ColorOutput "" "White"
    }
}

# Основная логика
Write-ColorOutput "🔧 Kubernetes Dashboard User Manager" "Magenta"
Write-ColorOutput "====================================" "Magenta"

switch ($Action) {
    "add" {
        if (-not $UserName) {
            Write-ColorOutput "❌ Не указано имя пользователя! Используйте -UserName <имя>" "Red"
            exit 1
        }

        Add-DashboardUser -UserName $UserName -Role $Role -Namespace $Namespace
    }

    "remove" {
        if (-not $UserName) {
            Write-ColorOutput "❌ Не указано имя пользователя! Используйте -UserName <имя>" "Red"
            exit 1
        }

        if (-not $Force) {
            $confirm = Read-Host "Вы уверены, что хотите удалить пользователя '$UserName'? (y/N)"
            if ($confirm -notmatch '^[yY]') {
                Write-ColorOutput "❌ Операция отменена" "Yellow"
                exit 0
            }
        }

        Remove-DashboardUser -UserName $UserName -Namespace $Namespace
    }

    "list" {
        Get-DashboardUsers -Namespace $Namespace
    }

    "token" {
        if (-not $UserName) {
            Write-ColorOutput "❌ Не указано имя пользователя! Используйте -UserName <имя>" "Red"
            exit 1
        }

        Get-UserToken -UserName $UserName -Namespace $Namespace
    }
}

Write-ColorOutput "✅ Операция завершена!" "Green"
