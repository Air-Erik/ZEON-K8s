# Делаем все ошибки фатальными
$ErrorActionPreference = 'Stop'

# 1) Хардкодим учётные данные vSphere
$user = "administrator@zeon.loc"
$pass = "Tf34gfasz!"

# 2) Передаём пароль в плагин через переменную окружения
# (kubectl-vsphere начиная с версии 0.0.8 умеет брать пароль из KUBECTL_VSPHERE_PASSWORD) :contentReference[oaicite:0]{index=0}
$env:KUBECTL_VSPHERE_PASSWORD = $pass

# 3) Список кластеров
$clusters = @(
    @{ Server = "172.16.50.194"; Namespace = "zeon-prod";          Name = "zeon-prod-cluster"          },
    @{ Server = "172.16.50.194"; Namespace = "zeon-dev";           Name = "zeon-dev-cluster"           },
    @{ Server = "172.16.50.194"; Namespace = "restore-test"; Name = "restore-test-cluster" }
    @{ Server = "172.16.50.194"; Namespace = "dev-infrastructure"; Name = "dev-infrastructure-cluster" }
)

# 4) Проходим по каждому кластеру и логинимся
foreach ($c in $clusters) {
    Write-Host "`n▶️  Logging into cluster '$($c.Name)' on server $($c.Server) (namespace: $($c.Namespace))..."
    # обращаемся к внешней команде через &, чтобы получить корректный код возврата в $LASTEXITCODE
    & kubectl vsphere login `
        --server $($c.Server) `
        --insecure-skip-tls-verify `
        --tanzu-kubernetes-cluster-namespace $($c.Namespace) `
        --tanzu-kubernetes-cluster-name $($c.Name) `
        -u $user

    if ($LASTEXITCODE -ne 0) {
        Write-Error "❌  Login FAILED for cluster '$($c.Name)' (код $LASTEXITCODE). Прерываю выполнение."
        exit $LASTEXITCODE
    }
}

# 5) (Опционально) Чистим переменную окружения сразу после логинов
Remove-Item Env:KUBECTL_VSPHERE_PASSWORD

Write-Host "`n✅  All logins completed successfully."
