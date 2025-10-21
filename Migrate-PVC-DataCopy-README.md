# Миграция PVC через копирование данных

## Описание

`Migrate-PVC-DataCopy.ps1` — скрипт для миграции PVC на другой StorageClass путем **копирования данных через Pod** (без использования VolumeSnapshot). Решает проблему cross-datastore миграции в vSphere.

### 🎯 **Решаемая проблема**

- VolumeSnapshot не работает между разными датасторами (ZFS → sha-zeon)
- Нужно мигрировать данные с одного StorageClass на другой
- Snapshot остается на исходном датасторе

### ✅ **Преимущества подхода**

- ✅ Работает между **любыми** StorageClass
- ✅ Поддерживает **cross-datastore** миграцию
- ✅ Не зависит от vSphere CNS ограничений
- ✅ Полная **верификация** копирования
- ✅ Подробное **отслеживание прогресса**

## Принцип работы

1. **Создает новый PVC** на целевом StorageClass
2. **Scale down приложение** (для безопасности данных)
3. **Запускает utility Pod** с двумя volume mounts
4. **Копирует данные** через `rsync` внутри Pod
5. **Обновляет приложение** на новый PVC
6. **Scale up приложение**

## Быстрый старт

### Базовое использование
```powershell
# Миграция minio на новый датастор
.\Migrate-PVC-DataCopy.ps1 `
  -Namespace minio `
  -PvcName minio-storage-minio-0 `
  -NewStorageClass k8s-sha-zeon-storage-policy
```

### С проверкой (dry-run)
```powershell
# Проверить что будет сделано без выполнения
.\Migrate-PVC-DataCopy.ps1 `
  -Namespace webapp `
  -PvcName app-data `
  -NewStorageClass premium-ssd `
  -DryRun
```

### С новым именем PVC
```powershell
# Для Deployment с переименованием PVC
.\Migrate-PVC-DataCopy.ps1 `
  -Namespace webapp `
  -PvcName old-data `
  -NewStorageClass fast-ssd `
  -NewPvcName new-data
```

## Параметры

| Параметр | Обязательный | Описание |
|----------|--------------|----------|
| `-Namespace` | ✅ | Namespace с PVC и приложением |
| `-PvcName` | ✅ | Имя исходного PVC |
| `-NewStorageClass` | ✅ | Целевой StorageClass |
| `-NewPvcName` | ⚪ | Новое имя PVC (по умолчанию: `<PvcName>-new`) |
| `-ApplicationName` | ⚪ | Имя приложения (автоопределение) |
| `-ApplicationType` | ⚪ | StatefulSet/Deployment (автоопределение) |
| `-CopyImage` | ⚪ | Docker образ для copy Pod (по умолчанию: `instrumentisto/rsync-ssh:latest`) |
| `-CopyAsUser` | ⚪ | **UID для copy Pod (по умолчанию: 1000). PostgreSQL/MongoDB/MySQL: 999** |
| `-TimeoutSeconds` | ⚪ | Таймаут копирования (по умолчанию: 3600 сек) |
| `-CreateSnapshot` | ⚪ | **Создать snapshot перед миграцией (РЕКОМЕНДУЕТСЯ)** |
| `-SnapshotClass` | ⚪ | VolumeSnapshotClass (по умолчанию: volumesnapshotclass-delete) |
| `-StopAfterCopy` | ⚪ | **Остановиться после копирования для проверки данных** |
| `-DryRun` | ⚪ | Режим проверки без выполнения |
| `-KeepCopyPod` | ⚪ | Не удалять copy Pod (для отладки) |

## Процесс миграции

1. 🔍 **Валидация** — проверка окружения и ресурсов
2. 🔎 **Обнаружение** — автоопределение приложения
3. 📸 **Snapshot** — опциональный safety snapshot (с `-CreateSnapshot`)
4. 📦 **Создание PVC** — новый PVC на целевом StorageClass
5. ⬇️ **Scale Down** — остановка приложения
6. 🚀 **Copy Pod** — создание utility Pod с rsync
7. 📁 **Копирование** — перенос данных через rsync с верификацией
8. 🛑 **Опциональная пауза** — остановка для проверки (с `-StopAfterCopy`)
9. 🔄 **Обновление** — привязка приложения к новому PVC
10. ⬆️ **Scale Up** — запуск приложения

## ⚠️ Важно: UID для разных приложений

Разные приложения используют разные UID для своих данных. **Обязательно укажите правильный UID** через параметр `-CopyAsUser`:

| Приложение | UID | Параметр |
|------------|-----|----------|
| MinIO | 1000 | По умолчанию ✅ |
| **PostgreSQL** | **999** | `-CopyAsUser 999` ⚠️ |
| **MongoDB** | **999** | `-CopyAsUser 999` ⚠️ |
| **MySQL** | **999** | `-CopyAsUser 999` ⚠️ |
| **Redis** | **999** | `-CopyAsUser 999` ⚠️ |
| Веб-приложения | 1000 | По умолчанию ✅ |

**Как узнать UID вашего приложения:**
```bash
kubectl -n <namespace> exec <pod-name> -- id
# Или проверьте владельца файлов:
kubectl -n <namespace> exec <pod-name> -- ls -ln /var/lib/postgresql/data
```

## Примеры использования

### PostgreSQL (UID 999)
```powershell
# PostgreSQL ТРЕБУЕТ CopyAsUser 999!
.\Migrate-PVC-DataCopy.ps1 `
  -Namespace postgres `
  -PvcName postgres-storage-postgres-0 `
  -NewStorageClass k8s-sha-zeon-storage-policy `
  -CreateSnapshot `
  -CopyAsUser 999
```

### MongoDB (UID 999)
```powershell
# MongoDB ТРЕБУЕТ CopyAsUser 999!
.\Migrate-PVC-DataCopy.ps1 `
  -Namespace mongodb `
  -PvcName mongo-persistent-storage-mongodb-0 `
  -NewStorageClass k8s-sha-zeon-storage-policy `
  -CreateSnapshot `
  -CopyAsUser 999
```

### OpenSearch StatefulSet
```powershell
# Миграция OpenSearch с ZFS на sha-zeon
.\Migrate-PVC-DataCopy.ps1 `
  -Namespace opensearch-logger `
  -PvcName data-opensearch-0 `
  -NewStorageClass k8s-sha-zeon-storage-policy
```

```powershell
# Миграция OpenSearch с ZFS на sha-zeon
.\Migrate-PVC-DataCopy.ps1 `
  -Namespace n8n `
  -PvcName n8n-data `
  -NewStorageClass k8s-sha-zeon-storage-policy
```

### MinIO с safety snapshot
```powershell
# РЕКОМЕНДУЕТСЯ: Миграция с созданием snapshot
.\Migrate-PVC-DataCopy.ps1 `
  -Namespace minio `
  -PvcName minio-storage-minio-0 `
  -NewStorageClass k8s-sha-zeon-storage-policy
```

### Двухэтапная миграция (проверка данных)
```powershell
# Этап 1: Копирование с остановкой для проверки
.\Migrate-PVC-DataCopy.ps1 `
  -Namespace postgres `
  -PvcName postgres-storage-postgres-0 `
  -NewStorageClass k8s-sha-zeon-storage-policy `
  -CopyAsUser 999 `
  -CreateSnapshot `

# Проверьте данные вручную...

# Этап 2: Завершение миграции
.\Migrate-PVC-DataCopy.ps1 `
  -Namespace postgres `
  -PvcName postgres-storage-postgres-0 `
  -NewStorageClass k8s-sha-zeon-storage-policy
```

### Web приложение (Deployment)
```powershell
# Миграция веб-приложения
.\Migrate-PVC-DataCopy.ps1 `
  -Namespace webapp `
  -PvcName webapp-data `
  -NewStorageClass premium-ssd `
  -ApplicationName webapp `
  -ApplicationType Deployment
```

## После миграции

### Проверка результата
```powershell
# Статус нового PVC
kubectl -n <namespace> describe pvc <new-pvc-name>

# Статус приложения
kubectl -n <namespace> get sts/<name>   # для StatefulSet
kubectl -n <namespace> get deploy/<name> # для Deployment

# Логи приложения
kubectl -n <namespace> logs -l app=<app-name>
```

### Cleanup старых ресурсов
```powershell
# ПОСЛЕ проверки работоспособности
kubectl -n <namespace> delete pvc <old-pvc-name>
```

## Troubleshooting

**Copy Pod не запускается**: Проверьте доступность образа `ubuntu:22.04`
**Копирование зависает**: Увеличьте `-TimeoutSeconds` для больших объемов
**Приложение не запускается**: Проверьте права доступа к новому PVC
**StatefulSet не обновился**: Для StatefulSet может потребоваться ручное обновление VolumeClaimTemplate

## Отличия от snapshot подхода

| Аспект | VolumeSnapshot | Data Copy |
|--------|---------------|-----------|
| **Cross-datastore** | ❌ Не работает | ✅ Работает |
| **Скорость** | ⚡ Быстро | 🐌 Зависит от объема |
| **Downtime** | ⏱️ Минимальный | ⏱️ На время копирования |
| **Надежность** | 🎲 Зависит от vSphere | ✅ Гарантированная |
| **Верификация** | ⚪ Ограниченная | ✅ Полная проверка |

Скрипт идеально подходит для миграции между разными типами хранилищ в vSphere with Tanzu!
