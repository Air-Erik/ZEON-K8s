#!/usr/bin/env powershell
# Ingress NGINX Setup Script
# Автоматическая установка ingress-nginx controller через Helm

param(
    [string]$Namespace = "ingress-nginx",
    [string]$ReleaseName = "ingress-nginx",
    [string]$ServiceType = "LoadBalancer",
    [switch]$EnableMetrics = $true,
    [switch]$SkipDashboardIngress = $false,
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

# Функция для проверки существования Helm релиза
function Test-HelmRelease {
    param(
        [string]$ReleaseName,
        [string]$Namespace
    )

    $release = helm list -n $Namespace --filter $ReleaseName --short 2>$null
    return $release -ne $null -and $release.Length -gt 0
}

Write-ColorOutput "🌐 Установка Ingress NGINX Controller" "Blue"
Write-ColorOutput "=====================================" "Blue"

# Проверка доступности инструментов
Write-ColorOutput "🛠️  Проверка инструментов:" "Yellow"

if (-not (Test-Command "kubectl")) {
    Write-ColorOutput "❌ kubectl не найден! Установите kubectl." "Red"
    exit 1
}
Write-ColorOutput "  ✅ kubectl - доступен" "Green"

if (-not (Test-Command "helm")) {
    Write-ColorOutput "❌ helm не найден! Установите Helm." "Red"
    exit 1
}
Write-ColorOutput "  ✅ helm - доступен" "Green"

# Проверка подключения к кластеру
Write-ColorOutput "🔗 Проверка подключения к кластеру:" "Yellow"

$clusterInfo = kubectl cluster-info --request-timeout=5s 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-ColorOutput "❌ Нет подключения к кластеру!" "Red"
    exit 1
}

$currentContext = kubectl config current-context 2>$null
Write-ColorOutput "  ✅ Подключение к кластеру - OK" "Green"
Write-ColorOutput "  └── Текущий контекст: $currentContext" "Gray"

# Проверка существующего релиза
if (Test-HelmRelease $ReleaseName $Namespace) {
    if (-not $Force) {
        Write-ColorOutput "⚠️  Ingress NGINX уже установлен!" "Yellow"
        Write-ColorOutput "Используйте -Force для переустановки" "Yellow"
        exit 0
    } else {
        Write-ColorOutput "🔄 Удаляем существующий релиз..." "Yellow"
        helm uninstall $ReleaseName -n $Namespace
        Start-Sleep -Seconds 5
    }
}

# Шаг 1: Добавление репозитория
Write-ColorOutput "📦 Шаг 1: Настройка Helm репозитория" "Yellow"

Write-ColorOutput "  └── Добавляем репозиторий ingress-nginx..." "Cyan"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

if ($LASTEXITCODE -ne 0) {
    Write-ColorOutput "    ❌ Ошибка добавления репозитория" "Red"
    exit 1
}

Write-ColorOutput "  └── Обновляем локальный индекс..." "Cyan"
helm repo update

if ($LASTEXITCODE -ne 0) {
    Write-ColorOutput "    ❌ Ошибка обновления репозиториев" "Red"
    exit 1
}

Write-ColorOutput "  ✅ Репозиторий настроен!" "Green"

# Шаг 2: Установка ingress-nginx
Write-ColorOutput "🚀 Шаг 2: Установка Ingress NGINX Controller" "Yellow"

# Формируем параметры установки
$installArgs = @(
    "install", $ReleaseName, "ingress-nginx/ingress-nginx",
    "--namespace", $Namespace, "--create-namespace",
    "--set", "controller.service.type=$ServiceType"
)

if ($EnableMetrics) {
    $installArgs += "--set", "controller.metrics.enabled=true"
}

# Отключаем PodSecurityPolicy для совместимости
$installArgs += "--set", "controller.podSecurityPolicy.enabled=false"

Write-ColorOutput "  └── Устанавливаем Ingress NGINX Controller..." "Cyan"
Write-ColorOutput "      Namespace: $Namespace" "Gray"
Write-ColorOutput "      Service Type: $ServiceType" "Gray"
Write-ColorOutput "      Metrics: $EnableMetrics" "Gray"

& helm @installArgs

if ($LASTEXITCODE -ne 0) {
    Write-ColorOutput "    ❌ Ошибка установки Ingress NGINX" "Red"
    exit 1
}

Write-ColorOutput "  ✅ Ingress NGINX Controller установлен!" "Green"

# Шаг 3: Ожидание готовности
Write-ColorOutput "⏳ Шаг 3: Ожидание готовности подов" "Yellow"

Write-ColorOutput "  └── Ожидаем запуска подов..." "Cyan"

$maxWaitTime = 180 # 3 минуты
$startTime = Get-Date

do {
    Start-Sleep -Seconds 5
    $pods = kubectl get pods -n $Namespace --no-headers 2>$null

    if ($pods) {
        $readyPods = ($pods -split "`n" | Where-Object { $_ -match '\s+1/1\s+Running' }).Count
        $totalPods = ($pods -split "`n").Count

        Write-ColorOutput "    └── Готовых подов: $readyPods/$totalPods" "Gray"

        if ($readyPods -eq $totalPods -and $totalPods -gt 0) {
            Write-ColorOutput "  ✅ Все поды готовы!" "Green"
            break
        }
    }

    $elapsedTime = (Get-Date) - $startTime
    if ($elapsedTime.TotalSeconds -gt $maxWaitTime) {
        Write-ColorOutput "  ⚠️  Превышено время ожидания, но установка может быть в процессе..." "Yellow"
        break
    }
} while ($true)

# Шаг 4: Проверка статуса
Write-ColorOutput "🔍 Шаг 4: Проверка статуса установки" "Yellow"

Write-ColorOutput "  └── Поды:" "Cyan"
$pods = kubectl get pods -n $Namespace --no-headers 2>$null
if ($pods) {
    foreach ($podLine in ($pods -split "`n")) {
        $parts = $podLine -split '\s+'
        if ($parts.Length -ge 3) {
            $podName = $parts[0]
            $ready = $parts[1]
            $status = $parts[2]

            if ($status -eq "Running" -and $ready -match "1/1") {
                Write-ColorOutput "    ✅ $podName - $status ($ready)" "Green"
            } else {
                Write-ColorOutput "    ⚠️  $podName - $status ($ready)" "Yellow"
            }
        }
    }
} else {
    Write-ColorOutput "    ❌ Поды не найдены" "Red"
}

Write-ColorOutput "  └── Сервисы:" "Cyan"
$services = kubectl get services -n $Namespace --no-headers 2>$null
if ($services) {
    foreach ($serviceLine in ($services -split "`n")) {
        $parts = $serviceLine -split '\s+'
        if ($parts.Length -ge 4) {
            $serviceName = $parts[0]
            $serviceType = $parts[1]
            $clusterIP = $parts[2]
            $externalIP = $parts[3]
            $ports = $parts[4]

            Write-ColorOutput "    ✅ $serviceName - $serviceType" "Green"
            if ($serviceType -eq "LoadBalancer") {
                if ($externalIP -eq "<pending>") {
                    Write-ColorOutput "      └── External IP: ожидание..." "Yellow"
                } else {
                    Write-ColorOutput "      └── External IP: $externalIP" "Gray"
                }
            }
        }
    }
} else {
    Write-ColorOutput "    ❌ Сервисы не найдены" "Red"
}

# Шаг 5: Применение Dashboard Ingress (опционально)
if (-not $SkipDashboardIngress -and (Test-Path "ingress-dashboard.yaml")) {
    Write-ColorOutput "🔗 Шаг 5: Применение Dashboard Ingress" "Yellow"

    Write-ColorOutput "  └── Применяем ingress-dashboard.yaml..." "Cyan"
    kubectl apply -f ingress-dashboard.yaml

    if ($LASTEXITCODE -eq 0) {
        Write-ColorOutput "  ✅ Dashboard Ingress применён!" "Green"

        # Показываем информацию о хосте
        $ingressContent = Get-Content "ingress-dashboard.yaml" -Raw
        if ($ingressContent -match 'host:\s*(.+)') {
            $hostName = $matches[1].Trim()
            Write-ColorOutput "  └── Dashboard доступен по адресу: https://$hostName" "Gray"
        }
    } else {
        Write-ColorOutput "  ❌ Ошибка применения Dashboard Ingress" "Red"
    }
}

# Итоговая информация
Write-ColorOutput "📋 Итоговая информация" "Yellow"

Write-ColorOutput "✅ Ingress NGINX Controller успешно установлен!" "Green"

Write-ColorOutput "🌐 Полезные команды:" "Cyan"
Write-ColorOutput "  # Проверка статуса" "White"
Write-ColorOutput "  kubectl get pods -n $Namespace" "Gray"
Write-ColorOutput "  kubectl get services -n $Namespace" "Gray"
Write-ColorOutput "" "White"
Write-ColorOutput "  # Просмотр логов" "White"
Write-ColorOutput "  kubectl logs -n $Namespace -l app.kubernetes.io/name=ingress-nginx" "Gray"
Write-ColorOutput "" "White"
Write-ColorOutput "  # Проверка Ingress ресурсов" "White"
Write-ColorOutput "  kubectl get ingress --all-namespaces" "Gray"

if ($ServiceType -eq "LoadBalancer") {
    Write-ColorOutput "💡 Совет:" "Yellow"
    Write-ColorOutput "  Если External IP остается <pending>, возможно нужно:" "White"
    Write-ColorOutput "  - Настроить MetalLB (для bare metal)" "Gray"
    Write-ColorOutput "  - Использовать NodePort вместо LoadBalancer" "Gray"
    Write-ColorOutput "  - Проверить поддержку LoadBalancer в кластере" "Gray"
}

Write-ColorOutput "=====================================" "Blue"
Write-ColorOutput "✅ Установка завершена!" "Green"

# Параметры скрипта
Write-ColorOutput "💡 Параметры скрипта:" "Yellow"
Write-ColorOutput "  -ServiceType <type>        : Тип сервиса (LoadBalancer, NodePort, ClusterIP)" "Gray"
Write-ColorOutput "  -EnableMetrics            : Включить метрики (по умолчанию: true)" "Gray"
Write-ColorOutput "  -SkipDashboardIngress     : Пропустить применение Dashboard Ingress" "Gray"
Write-ColorOutput "  -Force                    : Переустановить, если уже установлен" "Gray"
Write-ColorOutput "  -Namespace <name>         : Namespace для установки (по умолчанию: ingress-nginx)" "Gray"
