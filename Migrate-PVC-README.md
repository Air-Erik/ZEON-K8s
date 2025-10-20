# Универсальный скрипт миграции PVC

## Описание

`Migrate-PVC.ps1` — универсальный PowerShell скрипт для миграции PersistentVolumeClaim на другой StorageClass/датастор с использованием VolumeSnapshot технологии vSphere CSI.

### Ключевые возможности

✅ **Универсальность**: Поддерживает StatefulSet и Deployment
✅ **Автоопределение**: Автоматически находит приложение, использующее PVC
✅ **Безопасность**: Сохраняет snapshot и старый PV для отката
✅ **Валидация**: Опциональный временный клон для проверки данных
✅ **Наблюдаемость**: Детальный прогресс выполнения с индикаторами
✅ **Гибкость**: Поддержка переименования PVC для Deployment

## Предварительные требования

- Kubernetes cluster с vSphere CSI драйвером
- VolumeSnapshot CRD и VolumeSnapshotClass
- Целевой StorageClass должен быть доступен в namespace
- PowerShell и kubectl в PATH
- Права на управление PVC, Snapshot, StatefulSet/Deployment

## Быстрый старт

### StatefulSet (автоопределение)
```powershell
.\Migrate-PVC.ps1 `
  -Namespace minio `
  -PvcName minio-storage-minio-0 `
  -NewStorageClass k8s-sha-zeon-storage-policy
```

### Deployment с новым именем PVC
```powershell
.\Migrate-PVC.ps1 `
  -Namespace myapp `
  -PvcName app-data `
  -NewStorageClass fast-ssd-storage `
  -ApplicationName myapp `
  -ApplicationType Deployment `
  -NewPvcName app-data-v2
```

### С проверкой данных
```powershell
.\Migrate-PVC.ps1 `
  -Namespace postgres `
  -PvcName data-postgres-0 `
  -NewStorageClass premium-storage `
  -CreateTempClone `
  -ScaleDownBeforeSnapshot
```

## Основные параметры

| Параметр | Обязательный | Описание |
|----------|--------------|----------|
| `-Namespace` | ✅ | Namespace с PVC и приложением |
| `-PvcName` | ✅ | Имя PVC для миграции |
| `-NewStorageClass` | ✅ | Целевой StorageClass |
| `-ApplicationName` | ⚪ | Имя приложения (автоопределение) |
| `-ApplicationType` | ⚪ | StatefulSet/Deployment (автоопределение) |
| `-NewPvcName` | ⚪ | Новое имя PVC (только для Deployment) |
| `-CreateTempClone` | ⚪ | Создать временный клон для проверки |
| `-ScaleDownBeforeSnapshot` | ⚪ | Scale down перед созданием snapshot |
| `-AutoContinue` | ⚪ | Не спрашивать подтверждения |

## Процесс миграции

1. 🔍 **Валидация** — проверка окружения и параметров
2. 🔎 **Обнаружение** — автоопределение типа приложения
3. 🛡️ **Безопасность** — установка Retain политики для PV
4. ⬇️ **Масштабирование** — опциональный scale down
5. 📸 **Snapshot** — создание VolumeSnapshot
6. 🧪 **Проверка** — опциональный временный клон
7. ⚡ **Cutover** — основная миграция
8. ⬆️ **Восстановление** — запуск приложения
9. 🧹 **Завершение** — cleanup и отчет

## Примеры использования

### OpenSearch StatefulSet
```powershell
# Автоматическое определение StatefulSet
.\Migrate-PVC.ps1 `
  -Namespace opensearch `
  -PvcName data-opensearch-cluster-0 `
  -NewStorageClass k8s-sha-zeon-storage-policy `
  -CreateTempClone
```

### PostgreSQL с предварительным scale down
```powershell
# Для баз данных рекомендуется ScaleDownBeforeSnapshot
.\Migrate-PVC.ps1 `
  -Namespace postgres `
  -PvcName data-postgres-db-0 `
  -NewStorageClass premium-storage `
  -ScaleDownBeforeSnapshot `
  -AutoContinue
```

### Web приложение (Deployment)
```powershell
# Deployment с новым именем PVC
.\Migrate-PVC.ps1 `
  -Namespace webapp `
  -PvcName webapp-storage `
  -NewStorageClass fast-ssd `
  -ApplicationName webapp `
  -ApplicationType Deployment `
  -NewPvcName webapp-storage-v2
```

## После миграции

### Проверка результата
```powershell
# Статус нового PVC
kubectl -n <namespace> get pvc <pvc-name>

# Статус приложения
kubectl -n <namespace> get sts/<name>   # для StatefulSet
kubectl -n <namespace> get deploy/<name> # для Deployment

# Логи приложения
kubectl -n <namespace> logs -l app=<app-name>
```

### Cleanup (по желанию)
```powershell
# Удалить snapshot
kubectl -n <namespace> delete volumesnapshot <pvc-name>-snap

# Удалить старый PV (когда уверены, что миграция прошла успешно)
kubectl delete pv <old-pv-name>
```

## Безопасность и откат

- ✅ Старый PV сохраняется с политикой `Retain`
- ✅ VolumeSnapshot остается для экстренного восстановления
- ✅ Временный клон позволяет проверить данные до cutover
- ✅ При ошибке приложение можно быстро восстановить

### Экстренный откат
```powershell
# Если что-то пошло не так, восстановите приложение:
kubectl -n <namespace> scale sts/<name> --replicas=1
# или
kubectl -n <namespace> scale deployment/<name> --replicas=1
```

## Troubleshooting

**Snapshot не создается**: Проверьте VolumeSnapshotClass и CSI драйвер
**PVC не Bound**: Проверьте доступность StorageClass в namespace
**Приложение не запускается**: Проверьте события pod и совместимость с новым StorageClass
**Таймаут операции**: Увеличьте `-TimeoutSeconds` (по умолчанию 1800 сек)

## Поддержка

Скрипт основан на проверенных практиках миграции в vSphere with Tanzu (TKGS) и протестирован с vSphere CSI драйвером.

Для вопросов и улучшений создайте issue в репозитории проекта.
