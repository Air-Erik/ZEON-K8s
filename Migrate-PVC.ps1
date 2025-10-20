<#
.SYNOPSIS
  Универсальная миграция PVC на другой StorageClass/датастор через VolumeSnapshot (vSphere CSI).
  Поддерживает StatefulSet и Deployment.

.DESCRIPTION
  Скрипт выполняет безопасную миграцию PersistentVolumeClaim на новый StorageClass
  с использованием VolumeSnapshot. Автоматически определяет тип приложения
  (StatefulSet или Deployment) и выполняет соответствующую стратегию миграции.

.PARAMETER Namespace
  Namespace, где находится PVC и приложение.

.PARAMETER PvcName
  Имя PVC для миграции.

.PARAMETER NewStorageClass
  StorageClass для целевого датастора/политики.

.PARAMETER ApplicationName
  Имя приложения (StatefulSet или Deployment). Если не указано - автоопределение.

.PARAMETER ApplicationType
  Тип приложения: StatefulSet или Deployment. Если не указано - автоопределение.

.PARAMETER NewPvcName
  Новое имя PVC для Deployment (опционально). Если не указано - используется исходное имя.

.PARAMETER SnapshotClass
  Имя VolumeSnapshotClass (по умолчанию volumesnapshotclass-delete).

.PARAMETER TimeoutSeconds
  Глобальный таймаут (по умолчанию 1800 сек = 30 мин).

.PARAMETER PollSeconds
  Интервал опроса (по умолчанию 5 сек).

.PARAMETER CreateTempClone
  Создать временный клон для проверки данных перед cutover.

.PARAMETER ScaleDownBeforeSnapshot
  Снизить реплики до 0 ПЕРЕД созданием снапшота (рекомендовано для БД).

.PARAMETER AutoContinue
  Не спрашивать подтверждение перед cutover.

.PARAMETER KeepSnapshot
  Не удалять снапшот в конце.

.EXAMPLE
  .\Migrate-PVC.ps1 -Namespace opensearch -PvcName data-opensearch-cluster-0 -NewStorageClass k8s-sha-zeon-storage-policy

.EXAMPLE
  .\Migrate-PVC.ps1 -Namespace app -PvcName app-data -NewStorageClass fast-ssd -ApplicationName myapp -ApplicationType Deployment -NewPvcName app-data-new

.EXAMPLE
  .\Migrate-PVC.ps1 -Namespace postgres -PvcName data-postgres-0 -NewStorageClass premium-storage -CreateTempClone -ScaleDownBeforeSnapshot
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]  [string] $Namespace,
  [Parameter(Mandatory=$true)]  [string] $PvcName,
  [Parameter(Mandatory=$true)]  [string] $NewStorageClass,
  [Parameter()]                 [string] $ApplicationName,
  [Parameter()]                 [ValidateSet("StatefulSet", "Deployment")] [string] $ApplicationType,
  [Parameter()]                 [string] $NewPvcName,
  [Parameter()]                 [string] $SnapshotClass = "volumesnapshotclass-delete",
  [Parameter()]                 [int]    $TimeoutSeconds = 1800,
  [Parameter()]                 [int]    $PollSeconds = 5,
  [switch] $CreateTempClone,
  [switch] $ScaleDownBeforeSnapshot,
  [switch] $AutoContinue,
  [switch] $KeepSnapshot
)

# --- Global Variables ----------------------------------------------------------

$script:TotalSteps = 9
$script:CurrentStep = 0

# --- Helper Functions ----------------------------------------------------------

function Write-ProgressStep {
  param(
    [string]$Message,
    [string]$Status = "Running"  # Running, Completed, Failed, Warning
  )

  $script:CurrentStep++

  $emoji = switch ($Status) {
    "Running"   { "[RUNNING]" }
    "Completed" { "[OK]" }
    "Failed"    { "[FAILED]" }
    "Warning"   { "[WARNING]" }
    "Info"      { "[INFO]" }
  }

  $color = switch ($Status) {
    "Running"   { "Cyan" }
    "Completed" { "Green" }
    "Failed"    { "Red" }
    "Warning"   { "Yellow" }
    "Info"      { "Blue" }
  }

  $progress = "[$script:CurrentStep/$script:TotalSteps]"
  Write-Host "$emoji $progress $Message" -ForegroundColor $color
}

function Write-StatusMessage {
  param([string]$Message, [string]$Color = "Gray")
  Write-Host "    $Message" -ForegroundColor $Color
}

function ThrowIfFailed($ok, $msg) {
  if (-not $ok) { throw $msg }
}

function Invoke-Kubectl {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
  $out = & kubectl @Args 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Error ($out | Out-String)
    throw "kubectl failed: kubectl $($Args -join ' ')"
  }
  return $out
}

function Apply-KubectlYaml {
  param([Parameter(ValueFromPipeline=$true)][string]$YamlContent)

  $tempFile = [System.IO.Path]::GetTempFileName()
  try {
    $YamlContent | Out-File -FilePath $tempFile -Encoding utf8
    $out = & kubectl apply -f $tempFile 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Error ($out | Out-String)
      throw "kubectl apply failed"
    }
    return $out
  } finally {
    Remove-Item $tempFile -ErrorAction SilentlyContinue
  }
}

function Invoke-KubectlJson {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
  $raw = Invoke-Kubectl @Args
  try { return ($raw | ConvertFrom-Json) }
  catch {
    Write-Error "Failed to parse JSON from: kubectl $($Args -join ' ')"
    Write-Error $raw
    throw
  }
}

function Wait-Until {
  param(
    [scriptblock]$Condition,
    [int]$TimeoutSec,
    [int]$IntervalSec,
    [string]$WaitingMessage = "waiting..."
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (& $Condition) { return $true }
    Write-StatusMessage $WaitingMessage
    Start-Sleep -Seconds $IntervalSec
  }
  return $false
}

function Wait-VolumeSnapshotReady {
  param([string]$NS,[string]$Snap,[int]$TimeoutSec,[int]$IntervalSec)
  return Wait-Until -TimeoutSec $TimeoutSec -IntervalSec $IntervalSec `
    -WaitingMessage "Waiting VolumeSnapshot '$Snap' to be ready..." `
    -Condition {
      try {
        $vs = Invoke-KubectlJson -n $NS get volumesnapshot $Snap "-o" json
        return ($vs.status.readyToUse -eq $true)
      } catch { return $false }
    }
}

function Wait-PvcBound {
  param([string]$NS,[string]$PVC,[int]$TimeoutSec,[int]$IntervalSec)
  return Wait-Until -TimeoutSec $TimeoutSec -IntervalSec $IntervalSec `
    -WaitingMessage "Waiting PVC '$PVC' to be Bound..." `
    -Condition {
      try {
        $o = Invoke-KubectlJson -n $NS get pvc $PVC "-o" json
        return ($o.status.phase -eq "Bound")
      } catch { return $false }
    }
}

function Wait-ApplicationPodsGone {
  param([string]$NS,[string]$AppName,[string]$AppType,[int]$TimeoutSec,[int]$IntervalSec)

  $labelSelector = switch ($AppType) {
    "StatefulSet" { "app=$AppName" }
    "Deployment"  { "app=$AppName" }
    default       { "app=$AppName" }
  }

  return Wait-Until -TimeoutSec $TimeoutSec -IntervalSec $IntervalSec `
    -WaitingMessage "Waiting $AppType '$AppName' pods to disappear..." `
    -Condition {
      try {
        $pods = Invoke-KubectlJson -n $NS get pods "-l" $labelSelector "-o" json
        return ($pods.items.Count -eq 0)
      } catch { return $false }
    }
}

function Wait-ApplicationReady {
  param([string]$NS,[string]$AppName,[string]$AppType,[int]$TimeoutSec)

  switch ($AppType) {
    "StatefulSet" {
      Invoke-Kubectl -n $NS rollout status sts/$AppName "--timeout" "${TimeoutSec}s" | Out-Null
    }
    "Deployment" {
      Invoke-Kubectl -n $NS rollout status deployment/$AppName "--timeout" "${TimeoutSec}s" | Out-Null
    }
  }
}

function Find-ApplicationUsingPvc {
  param([string]$NS, [string]$PvcName)

  Write-StatusMessage "Searching for StatefulSet using PVC '$PvcName'..."

  # Поиск StatefulSet
  try {
    $statefulSets = Invoke-KubectlJson -n $NS get sts "-o" json
    foreach ($sts in $statefulSets.items) {
      $volumeClaimTemplates = $sts.spec.volumeClaimTemplates
      if ($volumeClaimTemplates) {
        foreach ($template in $volumeClaimTemplates) {
          # Проверяем паттерн именования StatefulSet: <template-name>-<sts-name>-<ordinal>
          $pattern = "$($template.metadata.name)-$($sts.metadata.name)-\d+"
          if ($PvcName -match "^$pattern$") {
            Write-StatusMessage "Found StatefulSet: $($sts.metadata.name)" "Green"
            return @{Type="StatefulSet"; Name=$sts.metadata.name; Replicas=$sts.spec.replicas}
          }
        }
      }
    }
  } catch {
    Write-StatusMessage "Error searching StatefulSets: $_" "Red"
  }

  Write-StatusMessage "Searching for Deployment using PVC '$PvcName'..."

  # Поиск Deployment
  try {
    $deployments = Invoke-KubectlJson -n $NS get deployments "-o" json
    foreach ($deployment in $deployments.items) {
      $volumes = $deployment.spec.template.spec.volumes
      if ($volumes) {
        foreach ($volume in $volumes) {
          if ($volume.persistentVolumeClaim -and $volume.persistentVolumeClaim.claimName -eq $PvcName) {
            Write-StatusMessage "Found Deployment: $($deployment.metadata.name)" "Green"
            return @{Type="Deployment"; Name=$deployment.metadata.name; Replicas=$deployment.spec.replicas}
          }
        }
      }
    }
  } catch {
    Write-StatusMessage "Error searching Deployments: $_" "Red"
  }

  throw "Could not find StatefulSet or Deployment using PVC '$PvcName' in namespace '$NS'"
}

function Update-DeploymentPvcName {
  param([string]$NS, [string]$DeploymentName, [string]$OldPvcName, [string]$NewPvcName)

  Write-StatusMessage "Updating Deployment '$DeploymentName': $OldPvcName -> $NewPvcName"

  # Получаем текущий Deployment
  $deployment = Invoke-KubectlJson -n $NS get deployment $DeploymentName "-o" json

  # Обновляем все volume mounts с нужным PVC
  $volumes = $deployment.spec.template.spec.volumes
  $updated = $false

  foreach ($volume in $volumes) {
    if ($volume.persistentVolumeClaim -and $volume.persistentVolumeClaim.claimName -eq $OldPvcName) {
      $volume.persistentVolumeClaim.claimName = $NewPvcName
      $updated = $true
      Write-StatusMessage "Updated volume '$($volume.name)' to use PVC '$NewPvcName'" "Green"
    }
  }

  if (-not $updated) {
    throw "Could not find volume using PVC '$OldPvcName' in Deployment '$DeploymentName'"
  }

  # Применяем изменения
  $deploymentJson = $deployment | ConvertTo-Json -Depth 10
  $deploymentJson | Apply-KubectlYaml | Out-Null

  Write-StatusMessage "Deployment updated successfully" "Green"
}

# --- Main Script ---------------------------------------------------------------

Write-Host "[START] PVC Migration Script" -ForegroundColor Magenta
Write-Host "=====================================" -ForegroundColor Magenta
Write-Host "Source PVC: $PvcName (namespace: $Namespace)" -ForegroundColor Gray
Write-Host "Target StorageClass: $NewStorageClass" -ForegroundColor Gray
Write-Host ""

try {
  # Step 1: Validation
  Write-ProgressStep "Validating environment and parameters" "Running"

  # Проверка kubectl
  try {
    $kubectlTest = Get-Command kubectl -ErrorAction Stop
    Write-StatusMessage "kubectl available: $($kubectlTest.Source)" "Green"
  } catch {
    throw "kubectl is not available in PATH"
  }

  # Проверка контекста
  $currentContext = kubectl config current-context 2>$null
  Write-StatusMessage "Current context: $currentContext" "Green"

  # Проверка PVC
  $pvcJson = Invoke-KubectlJson -n $Namespace get pvc $PvcName "-o" json
  $pvcPhase = $pvcJson.status.phase
  ThrowIfFailed ($pvcPhase -eq "Bound") "PVC '$PvcName' is not Bound (phase=$pvcPhase)"
  Write-StatusMessage "PVC '$PvcName' is Bound" "Green"

  # Получим PV и включим Retain
  $pvName = $pvcJson.spec.volumeName
  ThrowIfFailed ($pvName) "PVC has no spec.volumeName (not bound?)"
  Write-StatusMessage "Using PV: $pvName"
  # Patch через временный файл из-за проблем с экранированием JSON в PowerShell
  $tempFile = [System.IO.Path]::GetTempFileName()
  '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' | Out-File -FilePath $tempFile -Encoding utf8
  try {
    Invoke-Kubectl patch pv $pvName "--type" "merge" "--patch-file" $tempFile | Out-Null
  } finally {
    Remove-Item $tempFile -ErrorAction SilentlyContinue
  }
  Write-StatusMessage "PV reclaimPolicy set to Retain" "Green"

  # Проверка VolumeSnapshotClass
  try {
    $vsc = Invoke-KubectlJson get volumesnapshotclass $SnapshotClass "-o" json
    Write-StatusMessage "VolumeSnapshotClass '$SnapshotClass' exists" "Green"
  } catch {
    throw "VolumeSnapshotClass '$SnapshotClass' not found"
  }

  # Проверка целевого StorageClass
  try {
    $scNew = Invoke-KubectlJson get sc $NewStorageClass "-o" json
    Write-StatusMessage "Target StorageClass '$NewStorageClass' exists" "Green"
  } catch {
    throw "StorageClass '$NewStorageClass' not found"
  }

  Write-ProgressStep "Environment validation completed" "Completed"

  # Step 2: Discover Application
  Write-ProgressStep "Discovering application using PVC" "Running"

  if ($ApplicationName -and $ApplicationType) {
    Write-StatusMessage "Using provided application: $ApplicationType '$ApplicationName'" "Info"
    $app = @{Type=$ApplicationType; Name=$ApplicationName; Replicas=1}
  } else {
    $app = Find-ApplicationUsingPvc -NS $Namespace -PvcName $PvcName
    Write-StatusMessage "Auto-discovered: $($app.Type) '$($app.Name)'" "Green"
  }

  $ApplicationName = $app.Name
  $ApplicationType = $app.Type
  $originalReplicas = $app.Replicas

  Write-ProgressStep "Application discovery completed: $ApplicationType '$ApplicationName'" "Completed"

  # Step 3: Optional Scale Down Before Snapshot
  if ($ScaleDownBeforeSnapshot) {
    Write-ProgressStep "Scaling down application before snapshot" "Running"

    switch ($ApplicationType) {
      "StatefulSet" { Invoke-Kubectl -n $Namespace scale sts/$ApplicationName "--replicas" "0" | Out-Null }
      "Deployment"  { Invoke-Kubectl -n $Namespace scale deployment/$ApplicationName "--replicas" "0" | Out-Null }
    }

    $ok = Wait-ApplicationPodsGone -NS $Namespace -AppName $ApplicationName -AppType $ApplicationType -TimeoutSec $TimeoutSeconds -IntervalSec $PollSeconds
    ThrowIfFailed $ok "Pods of $ApplicationType '$ApplicationName' did not disappear in time"

    Write-ProgressStep "Application scaled down" "Completed"
  } else {
    Write-ProgressStep "Skipping pre-snapshot scale down" "Info"
  }

  # Step 4: Create Snapshot
  Write-ProgressStep "Creating VolumeSnapshot" "Running"

  $snapName = "$PvcName-snap"
  Write-StatusMessage "Creating snapshot '$snapName'..."

  @"
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $snapName
  namespace: $Namespace
spec:
  volumeSnapshotClassName: $SnapshotClass
  source:
    persistentVolumeClaimName: $PvcName
"@ | Apply-KubectlYaml | Out-Null

  $ok = Wait-VolumeSnapshotReady -NS $Namespace -Snap $snapName -TimeoutSec $TimeoutSeconds -IntervalSec $PollSeconds
  ThrowIfFailed $ok "VolumeSnapshot '$snapName' did not become ready in time"

  $snapJson = Invoke-KubectlJson -n $Namespace get volumesnapshot $snapName "-o" json
  $restoreSize = $snapJson.status.restoreSize
  ThrowIfFailed $restoreSize "Snapshot has no status.restoreSize (driver not ready?)"

  Write-StatusMessage "Snapshot ready, restore size: $restoreSize" "Green"
  Write-ProgressStep "VolumeSnapshot created successfully" "Completed"

  # Step 5: Optional Temporary Clone
  $tempCloneName = "$PvcName-migr"
  if ($CreateTempClone) {
    Write-ProgressStep "Creating temporary clone for validation" "Running"

    @"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $tempCloneName
  namespace: $Namespace
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: $NewStorageClass
  resources:
    requests:
      storage: $restoreSize
  dataSource:
    name: $snapName
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
"@ | Apply-KubectlYaml | Out-Null

    $ok = Wait-PvcBound -NS $Namespace -PVC $tempCloneName -TimeoutSec $TimeoutSeconds -IntervalSec $PollSeconds
    ThrowIfFailed $ok "Temporary clone PVC '$tempCloneName' did not become Bound in time"

    Write-StatusMessage "Temporary clone '$tempCloneName' is ready for validation" "Green"

    if (-not $AutoContinue) {
      Write-Host ""
      Write-Host "[WARNING] Temporary clone created for data validation:" -ForegroundColor Yellow
      Write-Host "   kubectl -n $Namespace get pvc $tempCloneName" -ForegroundColor Gray
      Write-Host "   You can mount it to a test pod to verify data integrity" -ForegroundColor Gray
      Read-Host "Press Enter to proceed with cutover"
    }

    Write-ProgressStep "Temporary clone validation completed" "Completed"
  } else {
    Write-ProgressStep "Skipping temporary clone creation" "Info"
  }

  # Step 6: Cutover Process
  Write-ProgressStep "Starting cutover process" "Running"

  # Определяем имя нового PVC
  $finalPvcName = if ($ApplicationType -eq "Deployment" -and $NewPvcName) { $NewPvcName } else { $PvcName }
  Write-StatusMessage "Target PVC name: $finalPvcName"

  # Scale down application
  Write-StatusMessage "Scaling down $ApplicationType '$ApplicationName'..."
  switch ($ApplicationType) {
    "StatefulSet" { Invoke-Kubectl -n $Namespace scale sts/$ApplicationName "--replicas" "0" | Out-Null }
    "Deployment"  { Invoke-Kubectl -n $Namespace scale deployment/$ApplicationName "--replicas" "0" | Out-Null }
  }

  $ok = Wait-ApplicationPodsGone -NS $Namespace -AppName $ApplicationName -AppType $ApplicationType -TimeoutSec $TimeoutSeconds -IntervalSec $PollSeconds
  ThrowIfFailed $ok "Pods of $ApplicationType '$ApplicationName' did not scale down in time"

  # Удаляем старый PVC (только если имя не меняется)
  if ($finalPvcName -eq $PvcName) {
    Write-StatusMessage "Deleting old PVC '$PvcName' (PV will be retained)..."
    Invoke-Kubectl -n $Namespace delete pvc $PvcName | Out-Null
  }

  # Создаем новый PVC
  Write-StatusMessage "Creating new PVC '$finalPvcName' from snapshot..."
  @"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $finalPvcName
  namespace: $Namespace
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: $NewStorageClass
  resources:
    requests:
      storage: $restoreSize
  dataSource:
    name: $snapName
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
"@ | Apply-KubectlYaml | Out-Null

  $ok = Wait-PvcBound -NS $Namespace -PVC $finalPvcName -TimeoutSec $TimeoutSeconds -IntervalSec $PollSeconds
  ThrowIfFailed $ok "New PVC '$finalPvcName' did not become Bound in time"

  # Обновляем Deployment если нужно
  if ($ApplicationType -eq "Deployment" -and $NewPvcName -and $NewPvcName -ne $PvcName) {
    Write-StatusMessage "Updating Deployment to use new PVC name..."
    Update-DeploymentPvcName -NS $Namespace -DeploymentName $ApplicationName -OldPvcName $PvcName -NewPvcName $NewPvcName
  }

  Write-ProgressStep "Cutover completed successfully" "Completed"

  # Step 7: Restore Application
  Write-ProgressStep "Restoring application operation" "Running"

  Write-StatusMessage "Scaling $ApplicationType '$ApplicationName' back to $originalReplicas replica(s)..."
  switch ($ApplicationType) {
    "StatefulSet" { Invoke-Kubectl -n $Namespace scale sts/$ApplicationName "--replicas" "$originalReplicas" | Out-Null }
    "Deployment"  { Invoke-Kubectl -n $Namespace scale deployment/$ApplicationName "--replicas" "$originalReplicas" | Out-Null }
  }

  Wait-ApplicationReady -NS $Namespace -AppName $ApplicationName -AppType $ApplicationType -TimeoutSec $TimeoutSeconds
  Write-StatusMessage "$ApplicationType '$ApplicationName' is running with new PVC" "Green"

  Write-ProgressStep "Application restored successfully" "Completed"

  # Step 8: Finalization
  Write-ProgressStep "Finalizing migration" "Running"

  # Cleanup временного клона
  if ($CreateTempClone) {
    Write-StatusMessage "Cleaning up temporary clone '$tempCloneName'..."
    try {
      Invoke-Kubectl -n $Namespace delete pvc $tempCloneName | Out-Null
      Write-StatusMessage "Temporary clone deleted" "Green"
    } catch {
      Write-StatusMessage "Failed to delete temporary clone (you can delete it manually)" "Warning"
    }
  }

  Write-ProgressStep "Migration completed successfully!" "Completed"

  # Final Summary
  Write-Host ""
  Write-Host "[SUCCESS] Migration Summary:" -ForegroundColor Green
  Write-Host "=====================================" -ForegroundColor Green
  Write-Host "[OK] Source PVC: $PvcName" -ForegroundColor Gray
  Write-Host "[OK] Target PVC: $finalPvcName" -ForegroundColor Gray
  Write-Host "[OK] New StorageClass: $NewStorageClass" -ForegroundColor Gray
  Write-Host "[OK] Application: $ApplicationType '$ApplicationName'" -ForegroundColor Gray
  Write-Host "[OK] VolumeSnapshot: $snapName (preserved)" -ForegroundColor Gray
  Write-Host "[OK] Old PV: $pvName (Retain policy)" -ForegroundColor Gray
  Write-Host ""
  Write-Host "[CLEANUP] Manual cleanup commands:" -ForegroundColor Yellow
  if (-not $KeepSnapshot) {
    Write-Host "   kubectl -n $Namespace delete volumesnapshot $snapName" -ForegroundColor Gray
  }
  Write-Host "   kubectl delete pv $pvName  # when you're sure migration is successful" -ForegroundColor Gray
  Write-Host ""
  Write-Host "[VERIFY] Verification commands:" -ForegroundColor Blue
  Write-Host "   kubectl -n $Namespace get pvc $finalPvcName" -ForegroundColor Gray
  Write-Host "   kubectl -n $Namespace get $($ApplicationType.ToLower()) $ApplicationName" -ForegroundColor Gray
  Write-Host "   kubectl -n $Namespace logs -l app=$ApplicationName" -ForegroundColor Gray

} catch {
  Write-ProgressStep "Migration failed: $_" "Failed"
  Write-Host ""
  Write-Host "[FAILED] Migration failed!" -ForegroundColor Red
  Write-Host "Error: $_" -ForegroundColor Red
  Write-Host ""
  Write-Host "[ROLLBACK] Rollback information:" -ForegroundColor Yellow
  Write-Host "   - VolumeSnapshot '$snapName' is preserved (if created)" -ForegroundColor Gray
  Write-Host "   - Original PV '$pvName' has Retain policy" -ForegroundColor Gray
  Write-Host "   - Scale application back up: kubectl -n $Namespace scale $($ApplicationType.ToLower())/$ApplicationName --replicas=$originalReplicas" -ForegroundColor Gray
  exit 1
}
