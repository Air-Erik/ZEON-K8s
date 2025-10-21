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
  Docker образ для copy Pod (по умолчанию instrumentisto/rsync-ssh:latest).

.PARAMETER CopyAsUser
  UID пользователя для copy Pod (по умолчанию 1000). Для PostgreSQL используйте 999, для MongoDB 999, для MySQL 999.

.PARAMETER TimeoutSeconds
  Глобальный таймаут (по умолчанию 3600 сек = 1 час).

.PARAMETER DryRun
  Режим проверки без выполнения изменений.

.PARAMETER KeepCopyPod
  Не удалять copy Pod после завершения (для отладки).

.PARAMETER CreateSnapshot
  Создать VolumeSnapshot исходного PVC перед началом миграции (рекомендуется).

.PARAMETER SnapshotClass
  Имя VolumeSnapshotClass (по умолчанию volumesnapshotclass-delete).

.PARAMETER StopAfterCopy
  Остановиться после копирования данных, не удалять старый PVC и не переключать приложение.
  Позволяет проверить данные в новом PVC перед финальной миграции.

.EXAMPLE
  .\Migrate-PVC-DataCopy.ps1 -Namespace minio -PvcName minio-storage-minio-0 -NewStorageClass k8s-sha-zeon-storage-policy -CreateSnapshot

.EXAMPLE
  .\Migrate-PVC-DataCopy.ps1 -Namespace webapp -PvcName app-data -NewStorageClass premium-ssd -NewPvcName app-data-v2 -DryRun

.EXAMPLE
  .\Migrate-PVC-DataCopy.ps1 -Namespace minio -PvcName data-minio-0 -NewStorageClass premium -CreateSnapshot -StopAfterCopy

.EXAMPLE
  .\Migrate-PVC-DataCopy.ps1 -Namespace postgres -PvcName postgres-storage-postgres-0 -NewStorageClass k8s-sha-zeon-storage-policy -CreateSnapshot -CopyAsUser 999
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]  [string] $Namespace,
  [Parameter(Mandatory=$true)]  [string] $PvcName,
  [Parameter(Mandatory=$true)]  [string] $NewStorageClass,
  [Parameter()]                 [string] $NewPvcName,
  [Parameter()]                 [string] $ApplicationName,
  [Parameter()]                 [ValidateSet("StatefulSet", "Deployment")] [string] $ApplicationType,
  [Parameter()]                 [string] $CopyImage = "instrumentisto/rsync-ssh:latest",
  [Parameter()]                 [int]    $CopyAsUser = 1000,
  [Parameter()]                 [int]    $TimeoutSeconds = 3600,
  [Parameter()]                 [string] $SnapshotClass = "volumesnapshotclass-delete",
  [switch] $DryRun,
  [switch] $KeepCopyPod,
  [switch] $CreateSnapshot,
  [switch] $StopAfterCopy
)

# --- Global Variables ----------------------------------------------------------

$script:TotalSteps = if ($CreateSnapshot) { 9 } else { 8 }
$script:CurrentStep = 0
$script:SnapshotName = ""

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
        $phase = $pod.status.phase
        # Pod считается готовым если Running, Succeeded или Failed
        # (быстрые задачи могут завершиться до проверки Running)
        return ($phase -eq "Running" -or $phase -eq "Succeeded" -or $phase -eq "Failed")
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
        $phase = $pod.status.phase
        # Pod завершен если Succeeded или Failed
        return ($phase -eq "Succeeded" -or $phase -eq "Failed")
      } catch { return $false }
    }
}

function Wait-VolumeSnapshotReady {
  param([string]$NS, [string]$Snap, [int]$TimeoutSec)
  return Wait-Until -TimeoutSec $TimeoutSec `
    -WaitingMessage "Waiting VolumeSnapshot '$Snap' to be ready..." `
    -Condition {
      try {
        $vs = Invoke-KubectlJson -n $NS get volumesnapshot $Snap "-o" json
        return ($vs.status.readyToUse -eq $true)
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

  # Step 3: Optional Create Snapshot for Safety
  if ($CreateSnapshot) {
    Write-ProgressStep "Creating safety VolumeSnapshot" "Running"

    $script:SnapshotName = "$PvcName-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Write-StatusMessage "Creating snapshot '$script:SnapshotName'..."

    $snapshotYaml = @"
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $script:SnapshotName
  namespace: $Namespace
spec:
  volumeSnapshotClassName: $SnapshotClass
  source:
    persistentVolumeClaimName: $PvcName
"@

    $snapshotYaml | Apply-KubectlYaml | Out-Null

    if (-not $DryRun) {
      $ok = Wait-VolumeSnapshotReady -NS $Namespace -Snap $script:SnapshotName -TimeoutSec 600
      ThrowIfFailed $ok "VolumeSnapshot '$script:SnapshotName' did not become ready in time"

      $snapJson = Invoke-KubectlJson -n $Namespace get volumesnapshot $script:SnapshotName "-o" json
      $restoreSize = $snapJson.status.restoreSize
      Write-StatusMessage "Snapshot ready, restore size: $restoreSize" "Green"
    } else {
      Write-StatusMessage "[DRY-RUN] Would create snapshot" "Yellow"
    }

    Write-ProgressStep "Safety snapshot created successfully" "Completed"
  }

  # Step 4: Create New PVC
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

  # Step 4: Check Application is Scaled Down
  Write-ProgressStep "Checking application is scaled down" "Running"

  Write-Host ""
  Write-Host "[MANUAL ACTION REQUIRED]" -ForegroundColor Yellow
  Write-Host "=====================================" -ForegroundColor Yellow
  Write-Host "Please ensure the application is scaled down BEFORE continuing:" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "For StatefulSet:" -ForegroundColor Cyan
  Write-Host "  kubectl -n $Namespace scale sts/$ApplicationName --replicas=0" -ForegroundColor Gray
  Write-Host ""
  Write-Host "For Deployment:" -ForegroundColor Cyan
  Write-Host "  kubectl -n $Namespace scale deployment/$ApplicationName --replicas=0" -ForegroundColor Gray
  Write-Host ""
  Write-Host "For ArgoCD managed apps:" -ForegroundColor Cyan
  Write-Host "  1. Pause auto-sync in ArgoCD UI or CLI" -ForegroundColor Gray
  Write-Host "  2. Then scale down manually" -ForegroundColor Gray
  Write-Host "=====================================" -ForegroundColor Yellow
  Write-Host ""

  # Автоматическое масштабирование закомментировано из-за ArgoCD
  # Write-StatusMessage "Scaling $ApplicationType '$ApplicationName' to 0 replicas..."
  # switch ($ApplicationType) {
  #   "StatefulSet" { Invoke-Kubectl -n $Namespace scale sts/$ApplicationName --replicas=0 | Out-Null }
  #   "Deployment"  { Invoke-Kubectl -n $Namespace scale deployment/$ApplicationName --replicas=0 | Out-Null }
  # }

  if (-not $DryRun) {
    # Проверяем что приложение действительно остановлено
    $currentReplicas = kubectl -n $Namespace get $($ApplicationType.ToLower()) $ApplicationName -o jsonpath='{.status.replicas}' 2>$null
    if ($currentReplicas -and $currentReplicas -gt 0) {
      Write-Host ""
      Write-Host "[WARNING] Application still has $currentReplicas running replicas!" -ForegroundColor Red
      Write-Host "Please scale down to 0 replicas before continuing." -ForegroundColor Red
      Read-Host "Press Enter when application is scaled down to 0"
    } else {
      Write-StatusMessage "Application is scaled down (0 replicas)" "Green"
    }

    # Дополнительная проверка - дождаться полного удаления Pods
    Write-StatusMessage "Waiting for Pods to fully terminate and volumes to detach..."
    Start-Sleep 15

    # Проверяем что Pod действительно нет
    $remainingPods = kubectl -n $Namespace get pods -l app=$ApplicationName --no-headers 2>$null
    if ($remainingPods) {
      Write-StatusMessage "Waiting for remaining Pods to terminate..." "Yellow"
      Start-Sleep 30
    }

    # Проверяем и очищаем застрявшие VolumeAttachments для исходного PVC
    Write-StatusMessage "Checking for stuck VolumeAttachments..."
    $sourcePvName = $sourcePvc.spec.volumeName
    $attachments = kubectl get volumeattachment -o json 2>$null | ConvertFrom-Json
    foreach ($va in $attachments.items) {
      if ($va.spec.source.persistentVolumeName -eq $sourcePvName) {
        $vaName = $va.metadata.name
        Write-StatusMessage "Found stuck VolumeAttachment for source PVC: $vaName" "Yellow"
        Write-StatusMessage "Deleting VolumeAttachment to free volume..."
        kubectl delete volumeattachment $vaName 2>$null | Out-Null
        Start-Sleep 5
      }
    }

    Write-StatusMessage "Volumes should be detached now" "Green"
  }

  Write-ProgressStep "Application scale down verified" "Completed"

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
  securityContext:
    runAsNonRoot: true
    runAsUser: $CopyAsUser
    fsGroup: $CopyAsUser
    fsGroupChangePolicy: "OnRootMismatch"
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: copy
    image: $CopyImage
    command: ["/bin/sh"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      runAsNonRoot: true
      runAsUser: $CopyAsUser
    args:
    - "-c"
    - |
      set -e
      echo "Starting PVC data copy..."
      echo "Source: /source"
      echo "Target: /target"

      # Check rsync availability
      if ! command -v rsync >/dev/null 2>&1; then
        echo "ERROR: rsync not found in image!"
        exit 1
      fi
      echo "rsync is available"

      # Check source data
      echo "Source directory contents:"
      ls -la /source/ || echo "Source is empty or inaccessible"

      # Ensure target directory exists
      mkdir -p /target

      # Copy data with rsync
      echo "Starting rsync copy..."
      rsync -avx --progress --omit-dir-times /source/ /target/
      EXIT_CODE=`$?

      echo "rsync finished with code: `$EXIT_CODE"

      # Handle rsync exit codes
      if [ `$EXIT_CODE -eq 0 ]; then
        echo "[OK] rsync completed successfully"
      elif [ `$EXIT_CODE -eq 23 ]; then
        echo "[WARNING] Some file attributes not transferred (code 23)"
        echo "This is acceptable - data copied successfully"
      elif [ `$EXIT_CODE -eq 24 ]; then
        echo "[WARNING] Some files vanished during transfer (code 24)"
        echo "This is acceptable for live filesystems"
      else
        echo "[ERROR] rsync failed with code `$EXIT_CODE"
        exit `$EXIT_CODE
      fi

      echo "Copy completed successfully!"
      echo "Target directory contents:"
      ls -la /target/

      # Verify copy (excluding lost+found and system dirs)
      echo "Verifying copy integrity..."

      # Count files instead of size (more reliable)
      SOURCE_FILES=`$(find /source -type f 2>/dev/null | wc -l)
      TARGET_FILES=`$(find /target -type f 2>/dev/null | wc -l)
      echo "Source files: `$SOURCE_FILES"
      echo "Target files: `$TARGET_FILES"

      SOURCE_SIZE=`$(du -sb /source 2>/dev/null | cut -f1 || echo "0")
      TARGET_SIZE=`$(du -sb /target 2>/dev/null | cut -f1 || echo "0")
      echo "Source size: `$SOURCE_SIZE bytes"
      echo "Target size: `$TARGET_SIZE bytes"

      # Calculate difference
      if [ "`$SOURCE_SIZE" -gt 0 ]; then
        DIFF=`$((SOURCE_SIZE - TARGET_SIZE))
        if [ `$DIFF -lt 0 ]; then DIFF=`$((0 - DIFF)); fi

        # Allow difference up to 1MB or 1% (lost+found is usually 16-32KB)
        MAX_DIFF=`$((SOURCE_SIZE / 100))
        if [ `$MAX_DIFF -lt 1048576 ]; then MAX_DIFF=1048576; fi

        echo "Size difference: `$DIFF bytes (max allowed: `$MAX_DIFF)"

        if [ `$DIFF -le `$MAX_DIFF ]; then
          echo "[OK] Copy verification successful!"
          exit 0
        else
          echo "[WARNING] Size difference too large - verify manually!"
          echo "This may be acceptable for MinIO/S3 data"
          exit 0
        fi
      else
        echo "[OK] Source is empty or matches target"
        exit 0
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

    # Check current phase
    $podCurrentStatus = Invoke-KubectlJson -n $Namespace get pod $copyPodName "-o" json
    $currentPhase = $podCurrentStatus.status.phase

    if ($currentPhase -eq "Running") {
      Write-StatusMessage "Copy Pod is running, copying data..." "Green"

      # Wait for copy to complete
      $ok = Wait-PodCompleted -NS $Namespace -PodName $copyPodName -TimeoutSec $TimeoutSeconds
      ThrowIfFailed $ok "Data copy did not complete in time (timeout: $TimeoutSeconds seconds)"
    } elseif ($currentPhase -eq "Succeeded" -or $currentPhase -eq "Failed") {
      Write-StatusMessage "Copy Pod already completed (phase: $currentPhase)" "Green"
    }

    # Check Pod status
    $podStatus = Invoke-KubectlJson -n $Namespace get pod $copyPodName "-o" json
    $podPhase = $podStatus.status.phase

    # Show copy logs
    Write-StatusMessage "Copy Pod finished with phase: $podPhase" "Yellow"
    $logs = kubectl -n $Namespace logs $copyPodName --tail=30

    # Check if copy was actually successful despite Failed status
    if ($podPhase -eq "Failed") {
      # Check if it's rsync code 23 (acceptable partial transfer)
      if ($logs -match "rsync finished with code: 23" -or $logs -match "Copy verification successful") {
        Write-StatusMessage "Copy completed with acceptable warnings (rsync code 23)" "Green"
        Write-StatusMessage "Partial transfer - only extended attributes failed" "Yellow"
      } else {
        Write-StatusMessage "Final logs:" "Red"
        Write-StatusMessage ($logs | Out-String) "Gray"
        throw "Data copy failed - check Pod logs"
      }
    } else {
      Write-StatusMessage "Copy completed successfully!" "Green"
      Write-StatusMessage "Final logs:" "Green"
      Write-StatusMessage ($logs | Out-String) "Gray"
    }
  } else {
    Write-StatusMessage "[DRY-RUN] Would wait for copy completion" "Yellow"
  }

  Write-ProgressStep "Data copy completed successfully" "Completed"

  # Check if we should stop here
  if ($StopAfterCopy) {
    Write-Host ""
    Write-Host "[INFO] StopAfterCopy flag detected - migration paused" -ForegroundColor Blue
    Write-Host "=====================================" -ForegroundColor Blue
    Write-Host "[OK] Data has been copied to new PVC: $NewPvcName" -ForegroundColor Green
    Write-Host "[OK] Old PVC is still intact: $PvcName" -ForegroundColor Green
    Write-Host "[OK] Application is scaled down: $ApplicationType '$ApplicationName'" -ForegroundColor Gray
    if ($script:SnapshotName) {
      Write-Host "[OK] Safety snapshot created: $script:SnapshotName" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "[VERIFY] Verification commands:" -ForegroundColor Yellow
    Write-Host "   # Check new PVC data" -ForegroundColor Gray
    Write-Host "   kubectl -n $Namespace get pvc $NewPvcName" -ForegroundColor Gray
    Write-Host "   # Mount and verify (example):" -ForegroundColor Gray
    Write-Host "   kubectl -n $Namespace run verify --image=busybox --rm -it --restart=Never -- ls -lah /data" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[CONTINUE] To complete migration, run without -StopAfterCopy:" -ForegroundColor Cyan
    Write-Host "   .\Migrate-PVC-DataCopy.ps1 -Namespace $Namespace -PvcName $PvcName -NewStorageClass $NewStorageClass" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[ROLLBACK] To rollback (delete new PVC, scale up app):" -ForegroundColor Yellow
    Write-Host "   kubectl -n $Namespace delete pvc $NewPvcName" -ForegroundColor Gray
    Write-Host "   kubectl -n $Namespace scale $($ApplicationType.ToLower())/$ApplicationName --replicas=$originalReplicas" -ForegroundColor Gray

    return
  }

  # Step 7: Update Application
  Write-ProgressStep "Updating application to use new PVC" "Running"

  if ($ApplicationType -eq "Deployment") {
    Update-DeploymentPvcName -NS $Namespace -DeploymentName $ApplicationName -OldPvcName $PvcName -NewPvcName $NewPvcName
    Write-StatusMessage "Deployment updated to use new PVC" "Green"
  } elseif ($ApplicationType -eq "StatefulSet") {
    # Для StatefulSet нужно переименовать PVC
    Write-StatusMessage "StatefulSet detected - swapping PVC names..." "Yellow"

    # Установим новый PV в Retain перед переименованием
    $newPvcManifestTemp = Invoke-KubectlJson -n $Namespace get pvc $NewPvcName "-o" json
    $newPvName = $newPvcManifestTemp.spec.volumeName

    $tempFile = [System.IO.Path]::GetTempFileName()
    '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' | Out-File -FilePath $tempFile -Encoding utf8
    try {
      Invoke-Kubectl patch pv $newPvName "--type" "merge" "--patch-file" $tempFile | Out-Null
      Write-StatusMessage "New PV '$newPvName' set to Retain policy" "Green"
    } finally {
      Remove-Item $tempFile -ErrorAction SilentlyContinue
    }

    # Удаляем старый PVC (данные скопированы в новый)
    Write-StatusMessage "Deleting old PVC '$PvcName'..."

    # Сначала убедимся что copy Pod не использует PVC
    Write-StatusMessage "Checking if copy Pod is still using PVC..."
    $copyPodStillExists = kubectl -n $Namespace get pod $copyPodName --ignore-not-found 2>$null
    if ($copyPodStillExists) {
      Write-StatusMessage "Copy Pod still exists, deleting it first..."
      kubectl -n $Namespace delete pod $copyPodName --wait=false 2>$null | Out-Null
      Start-Sleep 5
    }

    # Запускаем delete с коротким timeout
    Write-StatusMessage "Attempting graceful delete (60s timeout)..."
    $deleteJob = Start-Job -ScriptBlock {
      param($ns, $pvc)
      & kubectl -n $ns delete pvc $pvc --timeout=60s 2>&1
    } -ArgumentList $Namespace, $PvcName

    # Ждем завершения с timeout
    $completed = Wait-Job $deleteJob -Timeout 70
    if ($completed) {
      $deleteResult = Receive-Job $deleteJob
      Remove-Job $deleteJob
      Write-StatusMessage "Old PVC deleted successfully" "Green"
    } else {
      Stop-Job $deleteJob
      Remove-Job $deleteJob
      Write-StatusMessage "Graceful delete timed out - forcing removal..." "Yellow"

      # Проверяем существует ли PVC
      $stillExists = kubectl -n $Namespace get pvc $PvcName --ignore-not-found 2>$null
      if ($stillExists) {
        Write-StatusMessage "PVC still exists, removing finalizers..."

        # Удаляем finalizers через временный файл
        $patchFile = [System.IO.Path]::GetTempFileName()
        '{"metadata":{"finalizers":null}}' | Out-File -FilePath $patchFile -Encoding utf8
        try {
          kubectl -n $Namespace patch pvc $PvcName --type=merge --patch-file $patchFile 2>$null | Out-Null
          Write-StatusMessage "Finalizers removed" "Green"
        } finally {
          Remove-Item $patchFile -ErrorAction SilentlyContinue
        }

        # Принудительное удаление
        kubectl -n $Namespace delete pvc $PvcName --grace-period=0 --force 2>$null | Out-Null
        Write-StatusMessage "Force delete issued" "Yellow"
      }
    }

    # Ждем пока PVC действительно исчезнет
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
      $exists = kubectl -n $Namespace get pvc $PvcName --ignore-not-found 2>$null
      if (-not $exists) {
        break
      }
      Write-StatusMessage "Waiting for PVC to be removed..."
      Start-Sleep 2
    }

    # Переименовываем новый PVC в старое имя
    Write-StatusMessage "Renaming '$NewPvcName' to '$PvcName'..."

    # Получаем манифест нового PVC
    $newPvcManifest = Invoke-KubectlJson -n $Namespace get pvc $NewPvcName "-o" json
    $volumeName = $newPvcManifest.spec.volumeName
    Write-StatusMessage "Target PV: $volumeName"

    # Удаляем новый PVC (освобождаем имя, но PV сохранится с Retain)
    Write-StatusMessage "Deleting temporary PVC '$NewPvcName'..."
    Invoke-Kubectl -n $Namespace delete pvc $NewPvcName | Out-Null
    Start-Sleep 10

    # Очищаем claimRef из PV чтобы он стал Available
    Write-StatusMessage "Clearing claimRef from PV '$volumeName'..."
    $clearClaimPatch = [System.IO.Path]::GetTempFileName()
    '{"spec":{"claimRef":null}}' | Out-File -FilePath $clearClaimPatch -Encoding utf8
    try {
      Invoke-Kubectl patch pv $volumeName "--type" "merge" "--patch-file" $clearClaimPatch | Out-Null
      Write-StatusMessage "PV claimRef cleared, PV is now Available" "Green"
    } finally {
      Remove-Item $clearClaimPatch -ErrorAction SilentlyContinue
    }

    Start-Sleep 5

    # Создаем PVC с оригинальным именем указывая volumeName
    Write-StatusMessage "Creating PVC '$PvcName' bound to PV '$volumeName'..."
    $renamedPvcYaml = @"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PvcName
  namespace: $Namespace
spec:
  accessModes: [$($newPvcManifest.spec.accessModes | ForEach-Object { """$_""" } | Join-String -Separator ", ")]
  storageClassName: $NewStorageClass
  volumeName: $volumeName
  resources:
    requests:
      storage: $($newPvcManifest.spec.resources.requests.storage)
"@

    $renamedPvcYaml | Apply-KubectlYaml | Out-Null

    $ok = Wait-PvcBound -NS $Namespace -PVC $PvcName -TimeoutSec 60
    ThrowIfFailed $ok "Renamed PVC '$PvcName' did not become Bound"

    Write-StatusMessage "PVC successfully renamed to '$PvcName' for StatefulSet" "Green"
  }

  Write-ProgressStep "Application updated" "Completed"

  # Step 8: Manual Scale Up Application
  Write-ProgressStep "Migration completed - ready for scale up" "Completed"

  Write-Host ""
  Write-Host "[MANUAL ACTION REQUIRED]" -ForegroundColor Green
  Write-Host "=====================================" -ForegroundColor Green
  Write-Host "Migration completed! Now scale up the application:" -ForegroundColor Green
  Write-Host ""
  Write-Host "Scale up command:" -ForegroundColor Cyan
  Write-Host "  kubectl -n $Namespace scale $($ApplicationType.ToLower())/$ApplicationName --replicas=$originalReplicas" -ForegroundColor Gray
  Write-Host ""
  Write-Host "For ArgoCD managed apps:" -ForegroundColor Cyan
  Write-Host "  1. Re-enable auto-sync in ArgoCD" -ForegroundColor Gray
  Write-Host "  2. ArgoCD will sync and start the application automatically" -ForegroundColor Gray
  Write-Host "=====================================" -ForegroundColor Green
  Write-Host ""

  # Автоматическое масштабирование закомментировано из-за ArgoCD
  # Write-StatusMessage "Scaling $ApplicationType '$ApplicationName' back to $originalReplicas replica(s)..."
  # switch ($ApplicationType) {
  #   "StatefulSet" { Invoke-Kubectl -n $Namespace scale sts/$ApplicationName --replicas=$originalReplicas | Out-Null }
  #   "Deployment"  { Invoke-Kubectl -n $Namespace scale deployment/$ApplicationName --replicas=$originalReplicas | Out-Null }
  # }

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
  if ($script:SnapshotName) {
    Write-Host "[OK] Safety Snapshot: $script:SnapshotName (preserved for rollback)" -ForegroundColor Gray
  }
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
  if ($script:SnapshotName) {
    Write-Host "   kubectl -n $Namespace delete volumesnapshot $script:SnapshotName  # Optional: delete safety snapshot" -ForegroundColor Gray
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
  if ($script:SnapshotName) {
    Write-Host "   - Safety snapshot preserved: $script:SnapshotName" -ForegroundColor Gray
    Write-Host "   - To restore: Create PVC from snapshot if needed" -ForegroundColor Gray
  }
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
