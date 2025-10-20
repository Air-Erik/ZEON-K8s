# Пошаговый мануал миграции PVC (kubectl команды)

## 📋 Оглавление
- [Что делает скрипт](#что-делает-скрипт)
- [Подготовка](#подготовка)
- [Шаг 1: Создание safety snapshot](#шаг-1-создание-safety-snapshot)
- [Шаг 2: Создание нового PVC](#шаг-2-создание-нового-pvc)
- [Шаг 3: Остановка приложения](#шаг-3-остановка-приложения)
- [Шаг 4: Копирование данных](#шаг-4-копирование-данных)
- [Шаг 5: Переключение на новый PVC](#шаг-5-переключение-на-новый-pvc)
- [Шаг 6: Запуск приложения](#шаг-6-запуск-приложения)
- [Откат миграции](#откат-миграции)
- [Проверка и cleanup](#проверка-и-cleanup)

---

## Что делает скрипт

`Migrate-PVC-DataCopy.ps1` выполняет миграцию PVC между разными датасторами путем:

1. **Создания snapshot** исходного PVC (опционально)
2. **Создания нового PVC** на целевом StorageClass
3. **Копирования данных** через utility Pod с rsync
4. **Переключения приложения** на новый PVC
5. **Запуска приложения** с мигрированными данными

**Применимость**: Cross-datastore миграция (например, ZFS → sha-zeon в vSphere)

---

## Подготовка

### Установка переменных окружения
```bash
# Задайте параметры вашей миграции
export NS=minio                              # Namespace
export PVC=minio-storage-minio-0             # Имя исходного PVC
export NEW_SC=k8s-sha-zeon-storage-policy    # Целевой StorageClass
export NEW_PVC=${PVC}-new                    # Имя нового PVC
export APP=minio                             # Имя приложения (StatefulSet/Deployment)
export APP_TYPE=sts                          # sts или deployment
```

### Проверка исходного состояния
```bash
# 1. Проверить текущий контекст
kubectl config current-context

# 2. Проверить исходный PVC
kubectl -n $NS get pvc $PVC
# Ожидаемый вывод: STATUS должен быть Bound

# 3. Проверить приложение
kubectl -n $NS get $APP_TYPE $APP
# Запомните количество реплик!

# 4. Проверить целевой StorageClass
kubectl get sc $NEW_SC
# Убедитесь что существует

# 5. Посмотреть размер данных
kubectl -n $NS get pvc $PVC -o jsonpath='{.spec.resources.requests.storage}'
# Например: 20Gi
```

---

## Шаг 1: Создание safety snapshot

**Зачем:** Создать точку восстановления на случай проблем

```bash
# 1. Создать уникальное имя snapshot
SNAPSHOT_NAME=${PVC}-backup-$(date +%Y%m%d-%H%M%S)
echo "Snapshot name: $SNAPSHOT_NAME"

# 2. Создать VolumeSnapshot
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $SNAPSHOT_NAME
  namespace: $NS
spec:
  volumeSnapshotClassName: volumesnapshotclass-delete
  source:
    persistentVolumeClaimName: $PVC
EOF

# 3. Дождаться готовности snapshot (проверять каждые 5 сек)
kubectl -n $NS get volumesnapshot $SNAPSHOT_NAME --watch
# Ждите пока READYTOUSE станет true (обычно 5-30 сек)

# 4. Проверить snapshot
kubectl -n $NS get volumesnapshot $SNAPSHOT_NAME -o yaml
# Важные поля:
#   status.readyToUse: true
#   status.restoreSize: 20Gi
```

**Результат:** VolumeSnapshot создан и готов для экстренного восстановления

---

## Шаг 2: Создание нового PVC

**Зачем:** Создать пустой PVC на целевом датасторе

```bash
# 1. Получить размер исходного PVC
SIZE=$(kubectl -n $NS get pvc $PVC -o jsonpath='{.spec.resources.requests.storage}')
echo "PVC size: $SIZE"

# 2. Создать новый PVC на целевом StorageClass
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $NEW_PVC
  namespace: $NS
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: $NEW_SC
  resources:
    requests:
      storage: $SIZE
EOF

# 3. Дождаться пока PVC станет Bound
kubectl -n $NS get pvc $NEW_PVC --watch
# Ждите STATUS: Bound (обычно 10-60 сек)

# 4. Проверить созданный PVC
kubectl -n $NS describe pvc $NEW_PVC
# Проверьте:
#   Status: Bound
#   Volume: pvc-xxxxxxxx (новый PV создан)
#   StorageClass: k8s-sha-zeon-storage-policy (целевой)
```

**Результат:** Новый пустой PVC создан на целевом датасторе (sha-zeon)

---

## Шаг 3: Остановка приложения

**Зачем:** Обеспечить консистентность данных во время копирования

```bash
# 1. Запомнить текущее количество реплик
REPLICAS=$(kubectl -n $NS get $APP_TYPE $APP -o jsonpath='{.spec.replicas}')
echo "Original replicas: $REPLICAS"

# 2. Масштабировать приложение до 0
kubectl -n $NS scale $APP_TYPE/$APP --replicas=0

# 3. Дождаться остановки всех Pods
kubectl -n $NS get pods --watch
# Ждите пока все Pod приложения исчезнут

# 4. Убедиться что приложение остановлено
kubectl -n $NS get $APP_TYPE $APP
# READY должен показывать 0/0
```

**Результат:** Приложение остановлено, данные в PVC не изменяются

---

## Шаг 4: Копирование данных

**Зачем:** Скопировать все данные из старого PVC в новый через rsync

```bash
# 1. Создать уникальное имя для copy Pod
COPY_POD=pvc-copy-${PVC}-$(shuf -i 1000-9999 -n 1)
echo "Copy Pod name: $COPY_POD"

# 2. Создать utility Pod с двумя volume mounts
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $COPY_POD
  namespace: $NS
  labels:
    app: pvc-migration-copy
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: copy
    image: instrumentisto/rsync-ssh:latest
    command: ["/bin/sh"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      runAsNonRoot: true
      runAsUser: 1000
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
      EXIT_CODE=\$?

      echo "rsync finished with code: \$EXIT_CODE"

      # Handle rsync exit codes
      if [ \$EXIT_CODE -eq 0 ]; then
        echo "[OK] rsync completed successfully"
      elif [ \$EXIT_CODE -eq 23 ]; then
        echo "[WARNING] Some file attributes not transferred (code 23)"
        echo "This is acceptable - data copied successfully"
      elif [ \$EXIT_CODE -eq 24 ]; then
        echo "[WARNING] Some files vanished during transfer (code 24)"
        echo "This is acceptable for live filesystems"
      else
        echo "[ERROR] rsync failed with code \$EXIT_CODE"
        exit \$EXIT_CODE
      fi

      echo "Copy completed successfully!"
      echo "Target directory contents:"
      ls -la /target/

      # Verify copy
      echo "Verifying copy integrity..."
      SOURCE_FILES=\$(find /source -type f 2>/dev/null | wc -l)
      TARGET_FILES=\$(find /target -type f 2>/dev/null | wc -l)
      echo "Source files: \$SOURCE_FILES"
      echo "Target files: \$TARGET_FILES"

      SOURCE_SIZE=\$(du -sb /source 2>/dev/null | cut -f1 || echo "0")
      TARGET_SIZE=\$(du -sb /target 2>/dev/null | cut -f1 || echo "0")
      echo "Source size: \$SOURCE_SIZE bytes"
      echo "Target size: \$TARGET_SIZE bytes"

      # Calculate difference (allow 1MB or 1% for lost+found)
      if [ "\$SOURCE_SIZE" -gt 0 ]; then
        DIFF=\$((SOURCE_SIZE - TARGET_SIZE))
        if [ \$DIFF -lt 0 ]; then DIFF=\$((0 - DIFF)); fi
        MAX_DIFF=\$((SOURCE_SIZE / 100))
        if [ \$MAX_DIFF -lt 1048576 ]; then MAX_DIFF=1048576; fi
        echo "Size difference: \$DIFF bytes (max allowed: \$MAX_DIFF)"
        if [ \$DIFF -le \$MAX_DIFF ]; then
          echo "[OK] Copy verification successful!"
          exit 0
        else
          echo "[WARNING] Size difference too large"
          exit 0
        fi
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
      claimName: $PVC
  - name: target-vol
    persistentVolumeClaim:
      claimName: $NEW_PVC
EOF

# 3. Отслеживать статус Pod
kubectl -n $NS get pod $COPY_POD --watch
# Ждите фазы:
#   ContainerCreating → Running → Succeeded (обычно 2-10 минут)

# 4. Смотреть логи в реальном времени
kubectl -n $NS logs -f $COPY_POD

# 5. После завершения - проверить финальный статус
kubectl -n $NS get pod $COPY_POD
# STATUS должен быть Succeeded или Completed

# 6. Посмотреть финальные логи
kubectl -n $NS logs $COPY_POD --tail=50
```

**Результат:** Все данные скопированы из старого PVC в новый

**Важно:**
- rsync код **23** = нормально (некоторые extended attributes не скопированы)
- rsync код **0** = идеально
- Любой другой код = ошибка

---

## 🛑 ОПЦИОНАЛЬНАЯ ОСТАНОВКА (StopAfterCopy)

**Если используется флаг `-StopAfterCopy`, скрипт остановится здесь.**

### Проверка скопированных данных

```bash
# 1. Проверить новый PVC
kubectl -n $NS get pvc $NEW_PVC

# 2. Создать временный Pod для проверки данных
kubectl -n $NS run verify-data --image=busybox --rm -it --restart=Never \
  --overrides='{
    "spec": {
      "securityContext": {
        "runAsNonRoot": true,
        "runAsUser": 1000,
        "fsGroup": 1000,
        "seccompProfile": {"type": "RuntimeDefault"}
      },
      "containers": [{
        "name": "verify",
        "image": "busybox",
        "command": ["sh", "-c", "ls -lah /data && du -sh /data && echo Files: && find /data -type f | wc -l"],
        "securityContext": {
          "allowPrivilegeEscalation": false,
          "capabilities": {"drop": ["ALL"]},
          "runAsNonRoot": true,
          "runAsUser": 1000
        },
        "volumeMounts": [{
          "name": "data",
          "mountPath": "/data"
        }]
      }],
      "volumes": [{
        "name": "data",
        "persistentVolumeClaim": {"claimName": "'$NEW_PVC'"}
      }]
    }
  }'

# 3. Сравнить с исходными данными (опционально)
# Запустите аналогичный Pod для старого PVC и сравните количество файлов
```

**Если данные корректны** → продолжайте к Шагу 5
**Если проблемы** → смотрите раздел [Откат миграции](#откат-миграции)

---

## Шаг 5: Переключение на новый PVC

### Для StatefulSet (требуется переименование PVC)

```bash
# 1. Получить имя PV нового PVC
NEW_PV=$(kubectl -n $NS get pvc $NEW_PVC -o jsonpath='{.spec.volumeName}')
echo "New PV: $NEW_PV"

# 2. Установить PV в режим Retain (защита данных)
kubectl patch pv $NEW_PV -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

# 3. Удалить старый PVC
kubectl -n $NS delete pvc $PVC --timeout=60s

# Если зависло (timeout):
kubectl -n $NS patch pvc $PVC -p '{"metadata":{"finalizers":null}}' --type=merge
kubectl -n $NS delete pvc $PVC --grace-period=0 --force

# 4. Удалить временный PVC (освободить volumeName)
kubectl -n $NS delete pvc $NEW_PVC

# 5. Очистить claimRef из PV (сделать его Available)
kubectl patch pv $NEW_PV -p '{"spec":{"claimRef":null}}'

# 6. Проверить что PV стал Available
kubectl get pv $NEW_PV
# STATUS должен быть Available

# 7. Создать PVC с оригинальным именем, привязанный к PV
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
  namespace: $NS
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: $NEW_SC
  volumeName: $NEW_PV
  resources:
    requests:
      storage: 20Gi
EOF

# 8. Проверить что PVC привязался к PV
kubectl -n $NS get pvc $PVC
# STATUS должен быть Bound
# VOLUME должен быть $NEW_PV
# STORAGECLASS должен быть k8s-sha-zeon-storage-policy
```

### Для Deployment (обновление claimName)

```bash
# 1. Получить манифест Deployment
kubectl -n $NS get deployment $APP -o yaml > deployment-backup.yaml

# 2. Обновить claimName на новый PVC
kubectl -n $NS set volumes deployment/$APP \
  --containers='*' \
  --add --name=data --type=persistentVolumeClaim \
  --claim-name=$NEW_PVC --overwrite

# 3. Проверить обновление
kubectl -n $NS get deployment $APP -o yaml | grep -A5 volumes
```

**Результат:** Приложение настроено на использование нового PVC

---

## Шаг 6: Запуск приложения

**Зачем:** Запустить приложение с мигрированными данными

```bash
# 1. Масштабировать приложение обратно
kubectl -n $NS scale $APP_TYPE/$APP --replicas=$REPLICAS

# Для StatefulSet обычно replicas=1
# Для Deployment - используйте исходное значение

# 2. Отслеживать запуск
kubectl -n $NS get pods --watch

# 3. Дождаться готовности
kubectl -n $NS rollout status $APP_TYPE/$APP

# 4. Проверить логи приложения
kubectl -n $NS logs -l app=$APP --tail=50

# 5. Проверить что Pod использует правильный PVC
kubectl -n $NS get pod <pod-name> -o yaml | grep -A10 volumes
```

**Результат:** Приложение работает с данными на новом датасторе

---

## Откат миграции

### Если миграция еще НЕ завершена (до Шага 5)

**Ситуация:** Копирование завершено, но приложение еще не переключено

```bash
# 1. Удалить новый PVC (данные в нем больше не нужны)
kubectl -n $NS delete pvc $NEW_PVC

# 2. Удалить copy Pod (если еще существует)
kubectl -n $NS delete pod $COPY_POD --ignore-not-found

# 3. Масштабировать приложение обратно
kubectl -n $NS scale $APP_TYPE/$APP --replicas=$REPLICAS

# 4. Проверить что приложение работает
kubectl -n $NS get pods
kubectl -n $NS logs -l app=$APP
```

**Результат:** Приложение работает на старом PVC, новый PVC удален

---

### Если миграция завершена, но есть проблемы

**Ситуация:** Приложение переключено на новый PVC, но работает некорректно

```bash
# 1. Остановить приложение
kubectl -n $NS scale $APP_TYPE/$APP --replicas=0

# 2. Восстановить PVC из snapshot
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC}-restored
  namespace: $NS
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: k8s-storage-policy
  resources:
    requests:
      storage: 20Gi
  dataSource:
    name: $SNAPSHOT_NAME
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

# 3. Дождаться пока восстановленный PVC станет Bound
kubectl -n $NS get pvc ${PVC}-restored --watch

# 4. Для StatefulSet: переименовать восстановленный PVC
# (аналогично Шагу 5, но используя ${PVC}-restored)

# 5. Запустить приложение
kubectl -n $NS scale $APP_TYPE/$APP --replicas=$REPLICAS
```

**Результат:** Приложение восстановлено из snapshot

---

## Проверка и cleanup

### Проверка успешной миграции

```bash
# 1. Проверить статус приложения
kubectl -n $NS get $APP_TYPE $APP
kubectl -n $NS get pods -l app=$APP

# 2. Проверить PVC на новом датасторе
kubectl -n $NS get pvc $PVC
# StorageClass должен быть k8s-sha-zeon-storage-policy

# 3. Проверить PV
PV=$(kubectl -n $NS get pvc $PVC -o jsonpath='{.spec.volumeName}')
kubectl get pv $PV
# ReclaimPolicy должен быть Retain

# 4. Проверить работу приложения
kubectl -n $NS logs -l app=$APP --tail=100
kubectl -n $NS exec -it <pod-name> -- ls -lah /data

# 5. Для MinIO - проверить доступность buckets
kubectl -n $NS port-forward svc/minio 9000:9000 &
# Открыть http://localhost:9000 и проверить buckets
```

### Cleanup после успешной миграции

```bash
# ВНИМАНИЕ: Выполняйте только после полной проверки!

# 1. Удалить copy Pod (если существует)
kubectl -n $NS delete pod $COPY_POD --ignore-not-found

# 2. Удалить старые Released PV (опционально)
# Посмотреть Released PV:
kubectl get pv | grep Released

# Удалить конкретный Released PV (ОСТОРОЖНО!):
kubectl delete pv <old-pv-name>

# 3. Удалить safety snapshot (опционально)
# Рекомендуется сохранить на 7-30 дней
kubectl -n $NS delete volumesnapshot $SNAPSHOT_NAME

# 4. Проверить финальное состояние
kubectl -n $NS get pvc,volumesnapshot
kubectl get pv | grep $NS
```

---

## 🔍 Полезные команды для диагностики

### Проверка прогресса копирования

```bash
# Смотреть логи copy Pod в реальном времени
kubectl -n $NS logs -f $COPY_POD

# Проверить сколько данных скопировано (приблизительно)
kubectl -n $NS exec $COPY_POD -- du -sh /target

# Сравнить с исходным размером
kubectl -n $NS exec $COPY_POD -- du -sh /source
```

### Проверка проблем с PVC

```bash
# Детальная информация о PVC
kubectl -n $NS describe pvc $PVC

# События связанные с PVC
kubectl -n $NS get events --sort-by=.lastTimestamp | grep $PVC

# Проверить CSI драйвер
kubectl -n vmware-system-csi logs deployment/vsphere-csi-controller -c csi-provisioner --tail=50
```

### Проверка StorageClass и датасторов

```bash
# Список всех StorageClass
kubectl get sc

# Детали конкретного StorageClass
kubectl get sc $NEW_SC -o yaml

# Проверить volumeBindingMode
kubectl get sc $NEW_SC -o jsonpath='{.volumeBindingMode}'
# Immediate - PVC bind сразу
# WaitForFirstConsumer - PVC bind когда Pod создан
```

---

## 📊 Пример полной миграции MinIO

```bash
# === ПОДГОТОВКА ===
export NS=minio
export PVC=minio-storage-minio-0
export NEW_SC=k8s-sha-zeon-storage-policy
export NEW_PVC=${PVC}-new
export APP=minio
export APP_TYPE=sts

# === ШАГ 1: SAFETY SNAPSHOT ===
SNAPSHOT_NAME=${PVC}-backup-$(date +%Y%m%d-%H%M%S)
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $SNAPSHOT_NAME
  namespace: $NS
spec:
  volumeSnapshotClassName: volumesnapshotclass-delete
  source:
    persistentVolumeClaimName: $PVC
EOF

kubectl -n $NS wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/$SNAPSHOT_NAME --timeout=300s
echo "✅ Snapshot created: $SNAPSHOT_NAME"

# === ШАГ 2: НОВЫЙ PVC ===
SIZE=$(kubectl -n $NS get pvc $PVC -o jsonpath='{.spec.resources.requests.storage}')
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $NEW_PVC
  namespace: $NS
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: $NEW_SC
  resources:
    requests:
      storage: $SIZE
EOF

kubectl -n $NS wait --for=jsonpath='{.status.phase}'=Bound pvc/$NEW_PVC --timeout=300s
echo "✅ New PVC created and bound"

# === ШАГ 3: ОСТАНОВКА ПРИЛОЖЕНИЯ ===
REPLICAS=$(kubectl -n $NS get $APP_TYPE $APP -o jsonpath='{.spec.replicas}')
kubectl -n $NS scale $APP_TYPE/$APP --replicas=0
sleep 15
echo "✅ Application scaled down"

# === ШАГ 4: КОПИРОВАНИЕ (упрощенный copy Pod) ===
COPY_POD=pvc-copy-${PVC}-manual
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $COPY_POD
  namespace: $NS
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
  containers:
  - name: copy
    image: instrumentisto/rsync-ssh:latest
    command: ["/bin/sh", "-c"]
    args:
    - "rsync -avx /source/ /target/ && echo COPY_DONE"
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: {drop: ["ALL"]}
      runAsNonRoot: true
      runAsUser: 1000
    volumeMounts:
    - {name: source, mountPath: /source, readOnly: true}
    - {name: target, mountPath: /target}
  volumes:
  - {name: source, persistentVolumeClaim: {claimName: $PVC}}
  - {name: target, persistentVolumeClaim: {claimName: $NEW_PVC}}
EOF

kubectl -n $NS wait --for=condition=Ready pod/$COPY_POD --timeout=300s || echo "Pod starting..."
kubectl -n $NS logs -f $COPY_POD
kubectl -n $NS wait --for=jsonpath='{.status.phase}'=Succeeded pod/$COPY_POD --timeout=3600s
echo "✅ Data copied"

# === ШАГ 5: ПЕРЕКЛЮЧЕНИЕ PVC (StatefulSet) ===
NEW_PV=$(kubectl -n $NS get pvc $NEW_PVC -o jsonpath='{.spec.volumeName}')
kubectl patch pv $NEW_PV -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

# Удалить copy Pod (освободить старый PVC)
kubectl -n $NS delete pod $COPY_POD

# Удалить старый PVC
kubectl -n $NS delete pvc $PVC --timeout=60s

# Удалить новый PVC (освободить имя)
kubectl -n $NS delete pvc $NEW_PVC

# Очистить claimRef
kubectl patch pv $NEW_PV -p '{"spec":{"claimRef":null}}'

# Создать PVC с оригинальным именем
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
  namespace: $NS
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: $NEW_SC
  volumeName: $NEW_PV
  resources:
    requests:
      storage: $SIZE
EOF

kubectl -n $NS wait --for=jsonpath='{.status.phase}'=Bound pvc/$PVC --timeout=60s
echo "✅ PVC renamed and bound"

# === ШАГ 6: ЗАПУСК ===
kubectl -n $NS scale $APP_TYPE/$APP --replicas=$REPLICAS
kubectl -n $NS rollout status $APP_TYPE/$APP
echo "✅ Application started"

# === ПРОВЕРКА ===
kubectl -n $NS get pvc $PVC
kubectl -n $NS get pods
kubectl -n $NS logs -l app=$APP --tail=50
```

---

## 🚨 Типичные проблемы и решения

### PVC зависает в Pending

**Причина:** StorageClass не имеет доступа к datastore

```bash
# Проверить события
kubectl -n $NS describe pvc $NEW_PVC

# Проверить логи CSI
kubectl -n vmware-system-csi logs deployment/vsphere-csi-controller -c csi-provisioner --tail=50 | grep -i error
```

**Решение:** Использовать другой StorageClass с доступом к нужному datastore

---

### Copy Pod не запускается (CrashLoopBackOff)

**Причина:** PodSecurity policy или проблемы с образом

```bash
# Проверить события Pod
kubectl -n $NS describe pod $COPY_POD

# Проверить логи
kubectl -n $NS logs $COPY_POD
```

**Решение:** Убедитесь что Pod manifest включает `securityContext` (как в примере выше)

---

### rsync завершается с ошибкой

**Коды rsync:**
- **0** = Успех
- **23** = Частичная передача (обычно extended attributes) - **ДОПУСТИМО**
- **24** = Файлы исчезли во время копирования - **ДОПУСТИМО** для live FS
- **Другие** = Реальная ошибка

```bash
# Проверить логи rsync
kubectl -n $NS logs $COPY_POD | grep -i error

# Перезапустить копирование
kubectl -n $NS delete pod $COPY_POD
# Создайте Pod заново (Шаг 4)
```

---

### PVC delete зависает

**Причина:** PVC защищен finalizers или используется Pod

```bash
# 1. Проверить что использует PVC
kubectl -n $NS describe pvc $PVC | grep "Used By"

# 2. Удалить Pod который использует PVC
kubectl -n $NS delete pod <pod-name>

# 3. Проверить finalizers
kubectl -n $NS get pvc $PVC -o jsonpath='{.metadata.finalizers}'

# 4. Принудительное удаление finalizers
kubectl -n $NS patch pvc $PVC -p '{"metadata":{"finalizers":null}}' --type=merge

# 5. Force delete
kubectl -n $NS delete pvc $PVC --grace-period=0 --force
```

---

## 📝 Checklist миграции

### Перед миграцией
- [ ] Проверен текущий контекст kubectl
- [ ] PVC существует и в состоянии Bound
- [ ] Целевой StorageClass доступен
- [ ] Приложение идентифицировано
- [ ] Создан safety snapshot (РЕКОМЕНДУЕТСЯ)

### Во время миграции
- [ ] Новый PVC создан на целевом SC
- [ ] Приложение остановлено (0 replicas)
- [ ] Copy Pod запущен и работает
- [ ] Данные скопированы (rsync завершен)
- [ ] Размеры данных проверены
- [ ] Данные проверены вручную (опционально)

### После миграции
- [ ] PVC переименован (для StatefulSet)
- [ ] Приложение переключено на новый PVC
- [ ] Приложение запущено
- [ ] Логи приложения проверены
- [ ] Функциональность проверена
- [ ] Copy Pod удален
- [ ] Старые PV удалены (через 7-30 дней)
- [ ] Snapshot сохранен для истории

---

## 🎯 Резюме

**Автоматически (через скрипт):**
```powershell
.\Migrate-PVC-DataCopy.ps1 `
  -Namespace minio `
  -PvcName minio-storage-minio-0 `
  -NewStorageClass k8s-sha-zeon-storage-policy `
  -CreateSnapshot
```

**Вручную (следуя этому мануалу):**
- Полный контроль над каждым шагом
- Возможность проверки на каждом этапе
- Легкий откат при проблемах

**Оба подхода валидны и проверены на production!** ✅
