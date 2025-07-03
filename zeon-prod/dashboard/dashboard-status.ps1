#!/usr/bin/env powershell
# Kubernetes Dashboard Status and Access Script
# Проверка состояния Dashboard и быстрый доступ

param(
    [string]$Namespace = "kubernetes-dashboard",
    [switch]$StartPortForward = $false,
    [int]$Port = 8443,
    [switch]$ShowTokens = $false,
    [switch]$OpenBrowser = $false
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
        "Gray" { Write-Host $Message -ForegroundColor Gray }
        default { Write-Host $Message }
    }
}

# Функция для проверки доступности команды
function Test-Command {
    param([string]$Command)

    try {
        Get-Command $Command -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

# Функция для получения статуса ресурса
function Get-ResourceStatus {
    param(
        [string]$ResourceType,
        [string]$Namespace,
        [string]$LabelSelector = $null
    )

    $cmd = if ($LabelSelector) {
        "kubectl get $ResourceType -n $Namespace -l $LabelSelector --no-headers"
    } else {
        "kubectl get $ResourceType -n $Namespace --no-headers"
    }

    $result = Invoke-Expression $cmd 2>$null
    return $result
}

Write-ColorOutput "🔍 Kubernetes Dashboard Status Check" "Magenta"
Write-ColorOutput "===================================" "Magenta"

# Проверка доступности инструментов
Write-ColorOutput "🛠️  Проверка инструментов:" "Blue"

if (Test-Command "kubectl") {
    Write-ColorOutput "  ✅ kubectl - доступен" "Green"
} else {
    Write-ColorOutput "  ❌ kubectl - не найден!" "Red"
    exit 1
}

if (Test-Command "helm") {
    Write-ColorOutput "  ✅ helm - доступен" "Green"
} else {
    Write-ColorOutput "  ⚠️  helm - не найден (может потребоваться для обновлений)" "Yellow"
}

# Проверка подключения к кластеру
Write-ColorOutput "🔗 Проверка подключения к кластеру:" "Blue"

$clusterInfo = kubectl cluster-info --request-timeout=5s 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-ColorOutput "  ✅ Подключение к кластеру - OK" "Green"
    $currentContext = kubectl config current-context 2>$null
    Write-ColorOutput "  └── Текущий контекст: $currentContext" "Gray"
} else {
    Write-ColorOutput "  ❌ Нет подключения к кластеру!" "Red"
    exit 1
}

# Проверка namespace
Write-ColorOutput "📦 Проверка namespace:" "Blue"

$namespaceExists = kubectl get namespace $Namespace --ignore-not-found 2>$null
if ($namespaceExists) {
    Write-ColorOutput "  ✅ Namespace '$Namespace' - существует" "Green"
} else {
    Write-ColorOutput "  ❌ Namespace '$Namespace' - не найден!" "Red"
    Write-ColorOutput "  💡 Запустите: kubectl create namespace $Namespace" "Yellow"
    exit 1
}

# Проверка Helm релиза
Write-ColorOutput "🎯 Проверка Helm релиза:" "Blue"

if (Test-Command "helm") {
    $helmRelease = helm list -n $Namespace --filter kubernetes-dashboard --short 2>$null
    if ($helmRelease) {
        Write-ColorOutput "  ✅ Helm релиз 'kubernetes-dashboard' - установлен" "Green"
        $releaseInfo = helm status kubernetes-dashboard -n $Namespace --output json 2>$null | ConvertFrom-Json
        Write-ColorOutput "  └── Статус: $($releaseInfo.info.status)" "Gray"
        Write-ColorOutput "  └── Версия: $($releaseInfo.chart.metadata.version)" "Gray"
    } else {
        Write-ColorOutput "  ❌ Helm релиз 'kubernetes-dashboard' - не найден!" "Red"
        Write-ColorOutput "  💡 Запустите: .\setup-dashboard-users.ps1" "Yellow"
    }
} else {
    Write-ColorOutput "  ⚠️  Helm недоступен - пропускаем проверку релиза" "Yellow"
}

# Проверка подов
Write-ColorOutput "🚀 Проверка подов Dashboard:" "Blue"

$pods = Get-ResourceStatus "pods" $Namespace
if ($pods) {
    $podLines = $pods -split "`n" | Where-Object { $_ -match "dashboard|kong" }

    foreach ($podLine in $podLines) {
        $parts = $podLine -split '\s+'
        $podName = $parts[0]
        $ready = $parts[1]
        $status = $parts[2]

        if ($status -eq "Running" -and $ready -match "(\d+)/(\d+)" -and $matches[1] -eq $matches[2]) {
            Write-ColorOutput "  ✅ $podName - $status ($ready)" "Green"
        } else {
            Write-ColorOutput "  ❌ $podName - $status ($ready)" "Red"
        }
    }
} else {
    Write-ColorOutput "  ❌ Поды Dashboard не найдены!" "Red"
}

# Проверка сервисов
Write-ColorOutput "🌐 Проверка сервисов:" "Blue"

$services = Get-ResourceStatus "services" $Namespace
if ($services) {
    $serviceLines = $services -split "`n" | Where-Object { $_ -match "dashboard|kong" }

    foreach ($serviceLine in $serviceLines) {
        $parts = $serviceLine -split '\s+'
        $serviceName = $parts[0]
        $type = $parts[1]
        $clusterIP = $parts[2]
        $ports = $parts[4]

        Write-ColorOutput "  ✅ $serviceName - $type ($clusterIP`:${ports})" "Green"
    }
} else {
    Write-ColorOutput "  ❌ Сервисы Dashboard не найдены!" "Red"
}

# Проверка пользователей
Write-ColorOutput "👥 Проверка пользователей:" "Blue"

$serviceAccounts = kubectl get serviceaccount -n $Namespace -o jsonpath='{.items[*].metadata.name}' 2>$null
if ($serviceAccounts) {
    $users = $serviceAccounts -split ' ' | Where-Object { $_ -notmatch '^default$|^kubernetes-dashboard' }

    if ($users.Count -gt 0) {
        Write-ColorOutput "  ✅ Найдено пользователей: $($users.Count)" "Green"

        foreach ($user in $users) {
            $tokenFile = "tokens/$user-token.txt"
            $tokenExists = Test-Path $tokenFile

            if ($tokenExists) {
                Write-ColorOutput "  └── $user - токен готов" "Green"
            } else {
                Write-ColorOutput "  └── $user - токен отсутствует" "Yellow"
            }
        }
    } else {
        Write-ColorOutput "  ⚠️  Пользователи не найдены" "Yellow"
        Write-ColorOutput "  💡 Запустите: .\setup-dashboard-users.ps1" "Yellow"
    }
} else {
    Write-ColorOutput "  ❌ Ошибка получения ServiceAccount'ов" "Red"
}

# Показать токены, если запрошено
if ($ShowTokens) {
    Write-ColorOutput "🔑 Токены пользователей:" "Blue"

    $tokenFiles = Get-ChildItem -Path "tokens" -Filter "*-token.txt" -ErrorAction SilentlyContinue

    if ($tokenFiles) {
        foreach ($tokenFile in $tokenFiles) {
            $userName = $tokenFile.Name -replace '-token\.txt$', ''
            $tokenContent = Get-Content $tokenFile.FullName -Raw -ErrorAction SilentlyContinue

            if ($tokenContent) {
                $tokenPreview = $tokenContent.Substring(0, [Math]::Min(30, $tokenContent.Length)) + "..."
                Write-ColorOutput "  🔹 $userName" "Cyan"
                Write-ColorOutput "     └── $tokenPreview" "Gray"
            }
        }
    } else {
        Write-ColorOutput "  ❌ Файлы токенов не найдены в папке tokens/" "Red"
    }
}

# Проверка Ingress
Write-ColorOutput "🔀 Проверка Ingress:" "Blue"

if (Test-Path "ingress-dashboard.yaml") {
    $ingress = kubectl get ingress -n $Namespace kubernetes-dashboard-ingress --ignore-not-found 2>$null
    if ($ingress) {
        Write-ColorOutput "  ✅ Ingress настроен" "Green"

        # Получаем хост из манифеста
        $ingressContent = Get-Content "ingress-dashboard.yaml" -Raw
        if ($ingressContent -match 'host:\s*(.+)') {
            $hostName = $matches[1].Trim()
            Write-ColorOutput "  └── Хост: $hostName" "Gray"
        }
    } else {
        Write-ColorOutput "  ⚠️  Ingress не применён" "Yellow"
        Write-ColorOutput "  💡 Запустите: kubectl apply -f ingress-dashboard.yaml" "Yellow"
    }
} else {
    Write-ColorOutput "  ⚠️  Файл ingress-dashboard.yaml не найден" "Yellow"
}

# Инструкции по доступу
Write-ColorOutput "🌐 Доступ к Dashboard:" "Blue"

$kongService = kubectl get service -n $Namespace kubernetes-dashboard-kong-proxy --ignore-not-found 2>$null
if ($kongService) {
    Write-ColorOutput "  📡 Port-forward:" "Cyan"
    Write-ColorOutput "     kubectl -n $Namespace port-forward svc/kubernetes-dashboard-kong-proxy ${Port}:443" "Gray"
    Write-ColorOutput "     Затем откройте: https://localhost:$Port" "Gray"

    if ($StartPortForward) {
        Write-ColorOutput "  🚀 Запускаем port-forward..." "Yellow"

        if ($OpenBrowser) {
            # Запускаем port-forward в фоне
            Start-Process -FilePath "kubectl" -ArgumentList "-n $Namespace port-forward svc/kubernetes-dashboard-kong-proxy ${Port}:443" -WindowStyle Hidden
            Start-Sleep -Seconds 2

            # Открываем браузер
            Start-Process "https://localhost:$Port"
            Write-ColorOutput "  ✅ Браузер открыт!" "Green"
        } else {
            # Запускаем port-forward в интерактивном режиме
            kubectl -n $Namespace port-forward svc/kubernetes-dashboard-kong-proxy ${Port}:443
        }
    }
} else {
    Write-ColorOutput "  ❌ Сервис Kong proxy не найден!" "Red"
}

# Резюме
Write-ColorOutput "📊 Резюме:" "Blue"

# Подсчёт статуса - исправленная логика
$allPods = Get-ResourceStatus "pods" $Namespace
$dashboardPods = if ($allPods) {
    $allPods -split "`n" | Where-Object { $_ -match "dashboard|kong" }
} else {
    @()
}

$podsOK = 0
foreach ($podLine in $dashboardPods) {
    if ($podLine -match '\s+') {
        $parts = $podLine -split '\s+'
        if ($parts.Length -ge 3) {
            $ready = $parts[1]
            $status = $parts[2]

            if ($status -eq "Running" -and $ready -match "(\d+)/(\d+)" -and $matches[1] -eq $matches[2]) {
                $podsOK++
            }
        }
    }
}

$servicesOK = (Get-ResourceStatus "services" $Namespace | Where-Object { $_ -match "dashboard|kong" }).Count
$usersCount = if ($serviceAccounts) { ($serviceAccounts -split ' ' | Where-Object { $_ -notmatch '^default$|^kubernetes-dashboard' }).Count } else { 0 }

if ($podsOK -gt 0 -and $servicesOK -gt 0) {
    Write-ColorOutput "  ✅ Dashboard готов к использованию!" "Green"
} elseif ($podsOK -gt 0) {
    Write-ColorOutput "  ⚠️  Dashboard частично готов" "Yellow"
} else {
    Write-ColorOutput "  ❌ Dashboard не готов!" "Red"
}

Write-ColorOutput "  └── Работающих подов: $podsOK" "Gray"
Write-ColorOutput "  └── Доступных сервисов: $servicesOK" "Gray"
Write-ColorOutput "  └── Настроенных пользователей: $usersCount" "Gray"

Write-ColorOutput "===================================" "Magenta"

# Полезные команды
Write-ColorOutput "💡 Полезные параметры:" "Yellow"
Write-ColorOutput "  -StartPortForward   : Запустить port-forward" "Gray"
Write-ColorOutput "  -OpenBrowser        : Открыть браузер (с -StartPortForward)" "Gray"
Write-ColorOutput "  -ShowTokens         : Показать превью токенов" "Gray"
Write-ColorOutput "  -Port <number>      : Указать порт для port-forward (по умолчанию: 8443)" "Gray"
Write-ColorOutput "  -Namespace <name>   : Указать namespace (по умолчанию: kubernetes-dashboard)" "Gray"
