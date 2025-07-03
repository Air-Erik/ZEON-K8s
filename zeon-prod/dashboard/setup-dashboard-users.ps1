#!/usr/bin/env powershell
# Kubernetes Dashboard User Setup Script
# Автоматизация создания и настройки пользователей для Kubernetes Dashboard

param(
    [string]$Namespace = "kubernetes-dashboard",
    [switch]$SkipHelmInstall = $false,
    [switch]$ForceRecreate = $false
)

# Определяем пользователей и их роли
$Users = @{
    "admin" = @{
        "role" = "cluster-admin"
        "description" = "Super-admin с полными правами"
    }
    "air-erik" = @{
        "role" = "edit"
        "description" = "Пользователь с правами на редактирование"
    }
    "soothemysoul" = @{
        "role" = "edit"
        "description" = "Пользователь с правами на редактирование"
    }
}

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
    Write-ColorOutput "📁 Создаём структуру папок..." "Cyan"

    if (-not (Test-Path "tokens")) {
        New-Item -ItemType Directory -Path "tokens" -Force | Out-Null
        Write-ColorOutput "  └── Создана папка: tokens/" "Gray"
    }

    if (-not (Test-Path "manifests")) {
        New-Item -ItemType Directory -Path "manifests" -Force | Out-Null
        Write-ColorOutput "  └── Создана папка: manifests/" "Gray"
    }
}

Write-ColorOutput "🚀 Начинаем настройку Kubernetes Dashboard" "Blue"
Write-ColorOutput "=====================================================" "Blue"

# Создаём структуру папок
Initialize-DirectoryStructure

# Шаг 1: Установка Helm Chart (если не пропущена)
if (-not $SkipHelmInstall) {
    Write-ColorOutput "📦 Шаг 1: Установка Kubernetes Dashboard через Helm" "Yellow"

    # Добавляем репозиторий
    Write-ColorOutput "  └── Добавляем Helm репозиторий..." "Cyan"
    helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/

    # Обновляем индекс
    Write-ColorOutput "  └── Обновляем локальный индекс..." "Cyan"
    helm repo update

    # Устанавливаем chart
    Write-ColorOutput "  └── Устанавливаем Dashboard..." "Cyan"
    helm install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard `
        --namespace $Namespace --create-namespace `
        --set metricsScraper.enabled=true `
        --set adminAccessLog.enabled=true

    Write-ColorOutput "  ✅ Dashboard установлен!" "Green"
} else {
    Write-ColorOutput "⏭️  Пропускаем установку Helm Chart" "Yellow"
}

# Шаг 2: Создание ServiceAccount'ов
Write-ColorOutput "👥 Шаг 2: Создание ServiceAccount'ов" "Yellow"

foreach ($username in $Users.Keys) {
    $userInfo = $Users[$username]

    if (Test-KubernetesResource "serviceaccount" $username $Namespace) {
        if ($ForceRecreate) {
            Write-ColorOutput "  └── Удаляем существующий ServiceAccount: $username" "Cyan"
            kubectl delete serviceaccount $username -n $Namespace
        } else {
            Write-ColorOutput "  └── ServiceAccount $username уже существует, пропускаем" "Yellow"
            continue
        }
    }

    Write-ColorOutput "  └── Создаём ServiceAccount: $username ($($userInfo.description))" "Cyan"
    kubectl create serviceaccount $username -n $Namespace

    if ($LASTEXITCODE -eq 0) {
        Write-ColorOutput "    ✅ ServiceAccount $username создан!" "Green"
    } else {
        Write-ColorOutput "    ❌ Ошибка создания ServiceAccount $username" "Red"
    }
}

# Шаг 3: Настройка прав (ClusterRoleBinding)
Write-ColorOutput "🔐 Шаг 3: Настройка прав доступа" "Yellow"

foreach ($username in $Users.Keys) {
    $userInfo = $Users[$username]
    $bindingName = "$username-binding"

    if (Test-KubernetesResource "clusterrolebinding" $bindingName) {
        if ($ForceRecreate) {
            Write-ColorOutput "  └── Удаляем существующий ClusterRoleBinding: $bindingName" "Cyan"
            kubectl delete clusterrolebinding $bindingName
        } else {
            Write-ColorOutput "  └── ClusterRoleBinding $bindingName уже существует, пропускаем" "Yellow"
            continue
        }
    }

    Write-ColorOutput "  └── Создаём ClusterRoleBinding: $bindingName (роль: $($userInfo.role))" "Cyan"
    kubectl create clusterrolebinding $bindingName `
        --clusterrole=$($userInfo.role) `
        --serviceaccount="$Namespace`:$username"

    if ($LASTEXITCODE -eq 0) {
        Write-ColorOutput "    ✅ ClusterRoleBinding $bindingName создан!" "Green"
    } else {
        Write-ColorOutput "    ❌ Ошибка создания ClusterRoleBinding $bindingName" "Red"
    }
}

# Шаг 4: Создание и применение Secret'ов для токенов
Write-ColorOutput "🔑 Шаг 4: Создание токенов" "Yellow"

foreach ($username in $Users.Keys) {
    $secretName = "$username-token"
    $secretFile = "manifests/secret.$username.yaml"

    if (Test-KubernetesResource "secret" $secretName $Namespace) {
        if ($ForceRecreate) {
            Write-ColorOutput "  └── Удаляем существующий Secret: $secretName" "Cyan"
            kubectl delete secret $secretName -n $Namespace
        } else {
            Write-ColorOutput "  └── Secret $secretName уже существует, пропускаем" "Yellow"
            continue
        }
    }

    Write-ColorOutput "  └── Создаём Secret манифест: $secretFile" "Cyan"
    $secretContent = New-SecretManifest -UserName $username -Namespace $Namespace
    $secretContent | Out-File -FilePath $secretFile -Encoding UTF8

    Write-ColorOutput "  └── Применяем Secret: $secretName" "Cyan"
    kubectl apply -f $secretFile

    if ($LASTEXITCODE -eq 0) {
        Write-ColorOutput "    ✅ Secret $secretName создан!" "Green"
    } else {
        Write-ColorOutput "    ❌ Ошибка создания Secret $secretName" "Red"
    }
}

# Шаг 5: Получение и сохранение токенов
Write-ColorOutput "💾 Шаг 5: Получение и сохранение токенов" "Yellow"

# Ждём несколько секунд, чтобы токены были сгенерированы
Write-ColorOutput "  └── Ждём генерации токенов..." "Cyan"
Start-Sleep -Seconds 5

foreach ($username in $Users.Keys) {
    $secretName = "$username-token"
    $tokenFile = "tokens/$username-token.txt"

    Write-ColorOutput "  └── Получаем токен для: $username" "Cyan"

    # Проверяем, что секрет существует и содержит токен
    $maxRetries = 10
    $retryCount = 0

    do {
        $token = kubectl get secret $secretName -n $Namespace -o "go-template={{.data.token | base64decode}}" 2>$null

        if ($token -and $token.Length -gt 10) {
            $token | Out-File -FilePath $tokenFile -Encoding UTF8 -NoNewline
            Write-ColorOutput "    ✅ Токен для $username сохранён в $tokenFile" "Green"
            break
        } else {
            $retryCount++
            Write-ColorOutput "    ⏳ Ждём генерации токена для $username (попытка $retryCount/$maxRetries)" "Yellow"
            Start-Sleep -Seconds 2
        }
    } while ($retryCount -lt $maxRetries)

    if ($retryCount -eq $maxRetries) {
        Write-ColorOutput "    ❌ Не удалось получить токен для $username" "Red"
    }
}

# Шаг 6: Итоговая информация
Write-ColorOutput "📋 Итоговая информация" "Yellow"

Write-ColorOutput "Созданные пользователи:" "Cyan"
foreach ($username in $Users.Keys) {
    $userInfo = $Users[$username]
    $tokenFile = "tokens/$username-token.txt"

    Write-ColorOutput "  🔹 $username" "White"
    Write-ColorOutput "     └── Роль: $($userInfo.role)" "Gray"
    Write-ColorOutput "     └── Описание: $($userInfo.description)" "Gray"
    Write-ColorOutput "     └── Токен: $tokenFile" "Gray"

    if (Test-Path $tokenFile) {
        $tokenLength = (Get-Content $tokenFile -Raw).Length
        Write-ColorOutput "     └── Токен готов (длина: $tokenLength символов)" "Green"
    } else {
        Write-ColorOutput "     └── ❌ Токен не найден!" "Red"
    }
}

Write-ColorOutput "🌐 Для доступа к Dashboard:" "Cyan"
Write-ColorOutput "  1. Выполните port-forward:" "White"
Write-ColorOutput "     kubectl -n $Namespace port-forward svc/kubernetes-dashboard-kong-proxy 8443:443" "Gray"
Write-ColorOutput "  2. Откройте в браузере:" "White"
Write-ColorOutput "     https://localhost:8443" "Gray"
Write-ColorOutput "  3. Используйте токен из файла в папке tokens/" "White"

Write-ColorOutput "📁 Структура файлов:" "Cyan"
Write-ColorOutput "  tokens/     - токены пользователей" "Gray"
Write-ColorOutput "  manifests/  - YAML манифесты" "Gray"

Write-ColorOutput "=====================================================" "Blue"
Write-ColorOutput "✅ Настройка завершена!" "Green"

# Параметры запуска
Write-ColorOutput "💡 Полезные параметры:" "Yellow"
Write-ColorOutput "  -SkipHelmInstall    : Пропустить установку Helm Chart" "Gray"
Write-ColorOutput "  -ForceRecreate      : Пересоздать существующие ресурсы" "Gray"
Write-ColorOutput "  -Namespace <name>   : Указать пространство имён (по умолчанию: kubernetes-dashboard)" "Gray"
