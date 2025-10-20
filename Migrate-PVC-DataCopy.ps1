<#
.SYNOPSIS
  Миграция PVC на другой StorageClass через копирование данных в Pod (без snapshots).

.DESCRIPTION
  Скрипт выполняет миграцию PVC путем создания нового PVC на целевом StorageClass
  и копирования данных через utility Pod с rsync. Не использует VolumeSnapshot,
  что позволяет мигрировать между различными датасторами.

.PARAMETER Namespace
  Namespace, где находится PVC и приложение.

.PARAMETER PvcName
  Имя исходного PVC для миграции.

.PARAMETER NewStorageClass
  StorageClass для нового PVC.

.PARAMETER NewPvcName
  Новое имя PVC (опционально). Если не указано - используется <PvcName>-new.

.PARAMETER ApplicationName
  Имя приложения (StatefulSet или Deployment). Если не указано - автоопределение.

.PARAMETER ApplicationType
  Тип приложения: StatefulSet или Deployment. Если не указано - автоопределение.

.PARAMETER CopyImage
  Docker образ для copy Pod (по умолчанию ubuntu:22.04).

.PARAMETER TimeoutSeconds
  Глобальный таймаут (по умолчанию 3600 сек = 1 час).

.PARAMETER DryRun
  Режим проверки без выполнения изменений.

.PARAMETER KeepCopyPod
  Не удалять copy Pod после завершения (для отладки).

.EXAMPLE
  .\Migrate-PVC-DataCopy.ps1 -Namespace minio -PvcName minio-storage-minio-0 -NewStorageClass k8s-sha-zeon-storage-policy

.EXAMPLE
  .\Migrate-PVC-DataCopy.ps1 -Namespace webapp -PvcName app-data -NewStorageClass premium-ssd -NewPvcName app-data-v2 -DryRun
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]  [string] $Namespace,
  [Parameter(Mandatory=$true)]  [string] $PvcName,
  [Parameter(Mandatory=$true)]  [string] $NewStorageClass,
  [Parameter()]                 [string] $NewPvcName,
  [Parameter()]                 [string] $ApplicationName,
  [Parameter()]                 [ValidateSet("StatefulSet", "Deployment")] [string] $ApplicationType,
  [Parameter()]                 [string] $CopyImage = "ubuntu:22.04",
  [Parameter()]                 [int]    $TimeoutSeconds = 3600,
  [switch] $DryRun,
  [switch] $KeepCopyPod
)

# --- Global Variables ----------------------------------------------------------

$script:TotalSteps = 8
$script:CurrentStep = 0

# --- Helper Functions ----------------------------------------------------------

function Write-ProgressStep {
  param(
    [string]$Message,
    [string]$Status = "Running"  # Running, Completed, Failed, Warning, Info
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
  if ($DryRun -and ($Args -contains "apply" -or $Args -contains "delete" -or $Args -contains "scale" -or $Args -contains "patch")) {
    Write-StatusMessage "[DRY-RUN] Would execute: kubectl $($Args -join ' ')" "Yellow"
    return @()
  }

  $out = & kubectl @Args 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Error ($out | Out-String)
    throw "kubectl failed: kubectl $($Args -join ' ')"
  }
  return $out
}

function Invoke-KubectlJson {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
  $raw = Invoke-Kubectl @Args
  if ($DryRun -and $raw.Count -eq 0) {
    return @{items=@(); metadata=@{}}
  }
  try { return ($raw | ConvertFrom-Json) }
  catch {
    Write-Error "Failed to parse JSON from: kubectl $($Args -join ' ')"
    Write-Error $raw
    throw
  }
}

function Apply-KubectlYaml {
  param([Parameter(ValueFromPipeline=$true)][string]$YamlContent)

  if ($DryRun) {
    Write-StatusMessage "[DRY-RUN] Would apply YAML:" "Yellow"
    Write-StatusMessage $YamlContent "Gray"
    return
  }

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

function Wait-Until {
  param(
    [scriptblock]$Condition,
    [int]$TimeoutSec,
    [int]$IntervalSec = 5,
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

function Wait-PvcBound {
  param([string]$NS, [string]$PVC, [int]$TimeoutSec)
  return Wait-Until -TimeoutSec $TimeoutSec `
    -WaitingMessage "Waiting PVC '$PVC' to be Bound..." `
    -Condition {
      try {
        $pvc = Invoke-KubectlJson -n $NS get pvc $PVC "-o" json
        return ($pvc.status.phase -eq "Bound")
      } catch { return $false }
    }
}

function Wait-PodRunning {
  param([string]$NS, [string]$PodName, [int]$TimeoutSec)
  return Wait-Until -TimeoutSec $TimeoutSec `
    -WaitingMessage "Waiting Pod '$PodName' to be Running..." `
    -Condition {
      try {
        $pod = Invoke-KubectlJson -n $NS get pod $PodName "-o" json
        return ($pod.status.phase -eq "Running")
      } catch { return $false }
    }
}

function Wait-PodCompleted {
  param([string]$NS, [string]$PodName, [int]$TimeoutSec)
  return Wait-Until -TimeoutSec $TimeoutSec -IntervalSec 10 `
    -WaitingMessage "Waiting Pod '$PodName' to complete data copy..." `
    -Condition {
      try {
        $pod = Invoke-KubectlJson -n $NS get pod $PodName "-o" json
        return ($pod.status.phase -eq "Succeeded")
      } catch { return $false }
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

  if ($DryRun) {
    Write-StatusMessage "[DRY-RUN] Would update Deployment PVC reference" "Yellow"
    return
  }

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

Write-Host "[START] PVC Data Copy Migration Script" -ForegroundColor Magenta
Write-Host "=====================================" -ForegroundColor Magenta
Write-Host "Source PVC: $PvcName (namespace: $Namespace)" -ForegroundColor Gray
Write-Host "Target StorageClass: $NewStorageClass" -ForegroundColor Gray
if ($DryRun) { Write-Host "MODE: DRY RUN" -ForegroundColor Yellow }
Write-Host ""

try {
  # Auto-generate new PVC name if not provided
  if (-not $NewPvcName) {
    $NewPvcName = "$PvcName-new"
  }

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

  # Проверка исходного PVC
  $sourcePvc = Invoke-KubectlJson -n $Namespace get pvc $PvcName "-o" json
  $pvcPhase = $sourcePvc.status.phase
  ThrowIfFailed ($pvcPhase -eq "Bound") "Source PVC '$PvcName' is not Bound (phase=$pvcPhase)"
  Write-StatusMessage "Source PVC '$PvcName' is Bound (size: $($sourcePvc.spec.resources.requests.storage))" "Green"

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

  # Step 3: Create New PVC
  Write-ProgressStep "Creating new PVC on target StorageClass" "Running"

  $sourceSize = $sourcePvc.spec.resources.requests.storage
  Write-StatusMessage "Creating PVC '$NewPvcName' with size $sourceSize..."

  $newPvcYaml = @"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $NewPvcName
  namespace: $Namespace
spec:
  accessModes: [$($sourcePvc.spec.accessModes | ForEach-Object { """$_""" } | Join-String -Separator ", ")]
  storageClassName: $NewStorageClass
  resources:
    requests:
      storage: $sourceSize
"@

  $newPvcYaml | Apply-KubectlYaml | Out-Null

  if (-not $DryRun) {
    $ok = Wait-PvcBound -NS $Namespace -PVC $NewPvcName -TimeoutSec 300
    ThrowIfFailed $ok "New PVC '$NewPvcName' did not become Bound in time"
  }

  Write-StatusMessage "New PVC '$NewPvcName' is ready" "Green"
  Write-ProgressStep "New PVC created successfully" "Completed"

  # Step 4: Scale Down Application
  Write-ProgressStep "Scaling down application for data copy" "Running"

  Write-StatusMessage "Scaling $ApplicationType '$ApplicationName' to 0 replicas..."
  switch ($ApplicationType) {
    "StatefulSet" { Invoke-Kubectl -n $Namespace scale sts/$ApplicationName "--replicas" "0" | Out-Null }
    "Deployment"  { Invoke-Kubectl -n $Namespace scale deployment/$ApplicationName "--replicas" "0" | Out-Null }
  }

  if (-not $DryRun) {
    # Wait for pods to disappear
    Start-Sleep 10
  }

  Write-ProgressStep "Application scaled down" "Completed"

  # Step 5: Create Copy Pod
  Write-ProgressStep "Creating data copy Pod" "Running"

  $copyPodName = "pvc-copy-$PvcName-$(Get-Random -Minimum 1000 -Maximum 9999)"
  Write-StatusMessage "Creating copy Pod '$copyPodName'..."

  $copyPodYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: $copyPodName
  namespace: $Namespace
  labels:
    app: pvc-migration-copy
spec:
  restartPolicy: Never
  containers:
  - name: copy
    image: $CopyImage
    command: ["/bin/bash"]
    args:
    - "-c"
    - |
      set -e
      echo "Starting PVC data copy..."
      echo "Source: /source"
      echo "Target: /target"

      # Install rsync if not available
      if ! command -v rsync >/dev/null 2>&1; then
        echo "Installing rsync..."
        apt-get update && apt-get install -y rsync
      fi

      # Check source data
      echo "Source directory contents:"
      ls -la /source/ || echo "Source is empty or inaccessible"

      # Ensure target directory exists
      mkdir -p /target

      # Copy data with rsync
      echo "Starting rsync copy..."
      rsync -avx --progress /source/ /target/

      echo "Copy completed successfully!"
      echo "Target directory contents:"
      ls -la /target/

      # Verify copy
      echo "Verifying copy integrity..."
      SOURCE_SIZE=$$(du -sb /source 2>/dev/null | cut -f1 || echo "0")
      TARGET_SIZE=$$(du -sb /target 2>/dev/null | cut -f1 || echo "0")
      echo "Source size: $$SOURCE_SIZE bytes"
      echo "Target size: $$TARGET_SIZE bytes"

      if [ "$$SOURCE_SIZE" -eq "$$TARGET_SIZE" ]; then
        echo "✅ Copy verification successful!"
      else
        echo "⚠️  Size mismatch detected!"
        exit 1
      fi
    volumeMounts:
    - name: source-vol
      mountPath: /source
      readOnly: true
    - name: target-vol
      mountPath: /target
  volumes:
  - name: source-vol
    persistentVolumeClaim:
      claimName: $PvcName
  - name: target-vol
    persistentVolumeClaim:
      claimName: $NewPvcName
"@

  $copyPodYaml | Apply-KubectlYaml | Out-Null

  Write-ProgressStep "Copy Pod created" "Completed"

  # Step 6: Wait for Copy Completion
  Write-ProgressStep "Performing data copy (this may take a while)" "Running"

  if (-not $DryRun) {
    # Wait for pod to start
    $ok = Wait-PodRunning -NS $Namespace -PodName $copyPodName -TimeoutSec 300
    ThrowIfFailed $ok "Copy Pod '$copyPodName' did not start in time"

    Write-StatusMessage "Copy Pod is running, copying data..." "Green"

    # Wait for copy to complete
    $ok = Wait-PodCompleted -NS $Namespace -PodName $copyPodName -TimeoutSec $TimeoutSeconds
    ThrowIfFailed $ok "Data copy did not complete in time (timeout: $TimeoutSeconds seconds)"

    # Show copy logs
    Write-StatusMessage "Copy completed! Final logs:" "Green"
    $logs = kubectl -n $Namespace logs $copyPodName --tail=20
    Write-StatusMessage ($logs | Out-String) "Gray"
  } else {
    Write-StatusMessage "[DRY-RUN] Would wait for copy completion" "Yellow"
  }

  Write-ProgressStep "Data copy completed successfully" "Completed"

  # Step 7: Update Application
  Write-ProgressStep "Updating application to use new PVC" "Running"

  if ($ApplicationType -eq "Deployment") {
    Update-DeploymentPvcName -NS $Namespace -DeploymentName $ApplicationName -OldPvcName $PvcName -NewPvcName $NewPvcName
  } elseif ($ApplicationType -eq "StatefulSet") {
    Write-StatusMessage "StatefulSet detected - manual VolumeClaimTemplate update required" "Warning"
    Write-StatusMessage "You'll need to manually update the StatefulSet or rename the new PVC to match" "Warning"
  }

  Write-ProgressStep "Application updated" "Completed"

  # Step 8: Scale Up Application
  Write-ProgressStep "Scaling up application" "Running"

  Write-StatusMessage "Scaling $ApplicationType '$ApplicationName' back to $originalReplicas replica(s)..."
  switch ($ApplicationType) {
    "StatefulSet" { Invoke-Kubectl -n $Namespace scale sts/$ApplicationName "--replicas" "$originalReplicas" | Out-Null }
    "Deployment"  { Invoke-Kubectl -n $Namespace scale deployment/$ApplicationName "--replicas" "$originalReplicas" | Out-Null }
  }

  Write-ProgressStep "Migration completed successfully!" "Completed"

  # Final Summary
  Write-Host ""
  Write-Host "[SUCCESS] Data Copy Migration Summary:" -ForegroundColor Green
  Write-Host "=====================================" -ForegroundColor Green
  Write-Host "[OK] Source PVC: $PvcName" -ForegroundColor Gray
  Write-Host "[OK] Target PVC: $NewPvcName" -ForegroundColor Gray
  Write-Host "[OK] New StorageClass: $NewStorageClass" -ForegroundColor Gray
  Write-Host "[OK] Application: $ApplicationType '$ApplicationName'" -ForegroundColor Gray
  Write-Host "[OK] Copy Pod: $copyPodName" -ForegroundColor Gray
  Write-Host ""
  Write-Host "[CLEANUP] Manual cleanup commands:" -ForegroundColor Yellow
  Write-Host "   # Verify application is working" -ForegroundColor Gray
  Write-Host "   kubectl -n $Namespace get $($ApplicationType.ToLower()) $ApplicationName" -ForegroundColor Gray
  Write-Host "   kubectl -n $Namespace logs -l app=$ApplicationName" -ForegroundColor Gray
  Write-Host "" -ForegroundColor Gray
  Write-Host "   # After verification, remove old resources:" -ForegroundColor Gray
  if (-not $KeepCopyPod) {
    Write-Host "   kubectl -n $Namespace delete pod $copyPodName" -ForegroundColor Gray
  }
  Write-Host "   kubectl -n $Namespace delete pvc $PvcName  # WARNING: This will delete old data!" -ForegroundColor Gray
  Write-Host ""
  Write-Host "[VERIFY] Verification commands:" -ForegroundColor Blue
  Write-Host "   kubectl -n $Namespace get pvc $NewPvcName" -ForegroundColor Gray
  Write-Host "   kubectl -n $Namespace describe pvc $NewPvcName" -ForegroundColor Gray

} catch {
  Write-ProgressStep "Migration failed: $_" "Failed"
  Write-Host ""
  Write-Host "[FAILED] Migration failed!" -ForegroundColor Red
  Write-Host "Error: $_" -ForegroundColor Red
  Write-Host ""
  Write-Host "[ROLLBACK] Rollback information:" -ForegroundColor Yellow
  Write-Host "   - New PVC '$NewPvcName' may need manual cleanup" -ForegroundColor Gray
  Write-Host "   - Copy Pod '$copyPodName' may need manual cleanup" -ForegroundColor Gray
  Write-Host "   - Scale application back up: kubectl -n $Namespace scale $($ApplicationType.ToLower())/$ApplicationName --replicas=$originalReplicas" -ForegroundColor Gray
  exit 1
} finally {
  # Cleanup copy pod unless requested to keep
  if (-not $KeepCopyPod -and -not $DryRun) {
    try {
      kubectl -n $Namespace delete pod $copyPodName --ignore-not-found 2>$null | Out-Null
    } catch {
      # Ignore cleanup errors
    }
  }
}
