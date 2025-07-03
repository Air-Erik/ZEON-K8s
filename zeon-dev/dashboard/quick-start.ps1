#!/usr/bin/env powershell
# Quick Start Examples for Kubernetes Dashboard Management

Write-Host "🚀 Kubernetes Dashboard - Quick Start" -ForegroundColor Blue
Write-Host "=====================================" -ForegroundColor Blue

Write-Host "`n📋 Основные команды:" -ForegroundColor Yellow

Write-Host "`n1. Полная настройка (первый запуск):" -ForegroundColor Cyan
Write-Host "   .\setup-dashboard-users.ps1" -ForegroundColor White

Write-Host "`n2. Настройка только пользователей (Dashboard уже установлен):" -ForegroundColor Cyan
Write-Host "   .\setup-dashboard-users.ps1 -SkipHelmInstall" -ForegroundColor White

Write-Host "`n3. Пересоздание пользователей:" -ForegroundColor Cyan
Write-Host "   .\setup-dashboard-users.ps1 -ForceRecreate" -ForegroundColor White

Write-Host "`n4. Проверка статуса:" -ForegroundColor Cyan
Write-Host "   .\dashboard-status.ps1" -ForegroundColor White

Write-Host "`n5. Быстрый доступ (port-forward + браузер):" -ForegroundColor Cyan
Write-Host "   .\dashboard-status.ps1 -StartPortForward -OpenBrowser" -ForegroundColor White

Write-Host "`n6. Управление пользователями:" -ForegroundColor Cyan
Write-Host "   .\manage-users.ps1 -Action list" -ForegroundColor White
Write-Host "   .\manage-users.ps1 -Action add -UserName `"new-user`" -Role `"edit`"" -ForegroundColor White
Write-Host "   .\manage-users.ps1 -Action token -UserName `"admin`"" -ForegroundColor White

Write-Host "`n🔑 Токены пользователей:" -ForegroundColor Yellow
if (Test-Path "tokens/admin-token.txt") {
    Write-Host "   ✅ tokens/admin-token.txt - готов" -ForegroundColor Green
} else {
    Write-Host "   ❌ tokens/admin-token.txt - не найден" -ForegroundColor Red
}

if (Test-Path "tokens/air-erik-token.txt") {
    Write-Host "   ✅ tokens/air-erik-token.txt - готов" -ForegroundColor Green
} else {
    Write-Host "   ❌ tokens/air-erik-token.txt - не найден" -ForegroundColor Red
}

if (Test-Path "tokens/soothemysoul-token.txt") {
    Write-Host "   ✅ tokens/soothemysoul-token.txt - готов" -ForegroundColor Green
} else {
    Write-Host "   ❌ tokens/soothemysoul-token.txt - не найден" -ForegroundColor Red
}

Write-Host "`n🌐 Доступ к Dashboard:" -ForegroundColor Yellow
Write-Host "   1. Запустите port-forward:" -ForegroundColor White
Write-Host "      kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443" -ForegroundColor Gray
Write-Host "   2. Откройте браузер:" -ForegroundColor White
Write-Host "      https://localhost:8443" -ForegroundColor Gray
Write-Host "   3. Выберите 'Token' и вставьте токен из файла в папке tokens/" -ForegroundColor White

Write-Host "`n📁 Структура файлов:" -ForegroundColor Yellow
Write-Host "   tokens/     - токены пользователей" -ForegroundColor Gray
Write-Host "   manifests/  - YAML манифесты" -ForegroundColor Gray

Write-Host "`n📚 Документация:" -ForegroundColor Yellow
Write-Host "   README.md - подробная документация" -ForegroundColor White

Write-Host "`n=====================================" -ForegroundColor Blue
