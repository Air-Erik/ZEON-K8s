# Очистка Orphaned PVC в Supervisor Namespace (vSphere with Tanzu)

## 📋 Содержание

- [Введение](#введение)
- [Что такое Shadow PVC](#что-такое-shadow-pvc)
- [Шаг 1: Сбор информации](#шаг-1-сбор-информации)
- [Шаг 2: Анализ данных](#шаг-2-анализ-данных)
- [Шаг 3: Идентификация orphaned PVC](#шаг-3-идентификация-orphaned-pvc)
- [Шаг 4: Безопасное удаление](#шаг-4-безопасное-удаление)
- [Шаг 5: Профилактика](#шаг-5-профилактика)
- [Troubleshooting](#troubleshooting)

---

## Введение

Эта инструкция поможет идентифицировать и безопасно удалить **orphaned (осиротевшие) PVC** в supervisor namespace VMware vSphere with Tanzu.

### Когда использовать

- Накопилось много PVC в supervisor namespace
- Гостевые кластеры были удалены, но PVC остались
- Приложения удалены, но их storage остался
- Нужно освободить место на vSphere datastore

### Предварительные требования

- Доступ к supervisor cluster (kubectl context)
- Доступ к гостевому TKG кластеру (kubectl context)
- Права на удаление PVC в supervisor namespace
- Базовое понимание Kubernetes и vSphere with Tanzu

---

## Что такое Shadow PVC

**Shadow PVC (теневые копии)** - это автоматически создаваемые PVC в supervisor namespace, которые представляют собой мост между:
- PVC в гостевом TKG кластере
- Физическими VMDK файлами на vSphere datastore

### Формат имени Shadow PVC

```
{CLUSTER_ID}-{GUEST_PVC_UID}
```

Пример:
```
e63affb9-560b-49b9-9651-242450536942-301936d9-3085-40bc-92d0-980c777e4987
├─────────────────────┬────────────────┴──────────────────────┬────────────────┘
│                     │                                       │
│                     └─ Разделитель                          │
│                                                              │
└─ ID кластера (или namespace UID)                           └─ UID PVC в гостевом кластере
```

### Когда PVC становятся orphaned

1. **Удален гостевой кластер** - shadow PVC остались в supervisor
2. **Удалены приложения** - PVC в гостевом кластере удален, но shadow PVC осталась
3. **Удалена StorageClass** - PVC потеряли связь с политикой хранения
4. **Некорректное удаление** - кластер удален через vCenter вместо kubectl

---

## Шаг 1: Сбор информации

### 1.1 Проверка текущего контекста

```bash
# Проверить текущий контекст (должен быть supervisor)
kubectl config current-context

# Вывод должен быть что-то вроде: zeon-dev, zeon-prod (supervisor namespace)
```

### 1.2 Список всех namespace в supervisor

```bash
# Получить список всех namespace
kubectl get ns

# Найти свой supervisor namespace (обычно это пользовательские namespace, не vmware-system-*)
```

### 1.3 Подсчет PVC в supervisor namespace

```bash
# Заменить NAMESPACE_NAME на ваш namespace
export SUPERVISOR_NS="zeon-dev"

# Получить список всех PVC
kubectl get pvc -n $SUPERVISOR_NS

# Подсчитать количество
kubectl get pvc -n $SUPERVISOR_NS --no-headers | wc -l
```

### 1.4 Получить список TKG кластеров

```bash
# Проверить какие TKG кластера существуют в namespace
kubectl get tanzukubernetescluster -n $SUPERVISOR_NS

# Или через Cluster API
kubectl get cluster -n $SUPERVISOR_NS
```

### 1.5 Получить UID текущего кластера

```bash
# Получить UID текущего TKG кластера
kubectl get tanzukubernetescluster -n $SUPERVISOR_NS -o yaml | grep -E "uid:|name:"

# Запомнить UID - он будет использоваться в именах PVC
```

### 1.6 Собрать информацию об активных PVC в гостевом кластере

```bash
# Переключиться в контекст гостевого кластера
kubectl config use-context YOUR-GUEST-CLUSTER-NAME

# Получить список всех PVC со всех namespace
kubectl get pvc -A

# Получить список UUID активных PVC
kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' > /tmp/active-pvc-uids.txt

# Вернуться в supervisor context
kubectl config use-context $SUPERVISOR_NS
```

---

## Шаг 2: Анализ данных

### 2.1 Группировка PVC по префиксам

```bash
# Получить уникальные префиксы (cluster IDs)
kubectl get pvc -n $SUPERVISOR_NS --no-headers | \
  awk '{print $1}' | \
  cut -d'-' -f1-5 | \
  sort | uniq -c

# Вывод покажет сколько PVC у каждого кластера/префикса
# Например:
#   6 77cd20b3-005c-4320-bcd1-502db9e7dafc
#  17 e63affb9-560b-49b9-9651-242450536942
```

**Интерпретация:**
- Если префикс не совпадает с UID текущего кластера → это старый удаленный кластер
- Если префикс совпадает → нужна дополнительная проверка

### 2.2 Проверка использования PVC

```bash
# Проверить все ли PVC используются
kubectl get pvc -n $SUPERVISOR_NS -o custom-columns=NAME:.metadata.name,USED_BY:.status.phase,CAPACITY:.spec.resources.requests.storage,AGE:.metadata.creationTimestamp --no-headers

# Для каждого PVC проверить "Used By"
for pvc in $(kubectl get pvc -n $SUPERVISOR_NS --no-headers | awk '{print $1}'); do
  echo "=== $pvc ==="
  kubectl describe pvc -n $SUPERVISOR_NS $pvc | grep "Used By:"
  echo ""
done
```

### 2.3 Сравнение с активными PVC

Создайте скрипт для автоматической проверки:

```bash
#!/bin/bash

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 ПРОВЕРКА ORPHANED PVC В SUPERVISOR NAMESPACE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Получение активных PVC UUID из гостевого кластера
echo "📦 Получение активных PVC из гостевого кластера..."
kubectl config use-context YOUR-GUEST-CLUSTER > /dev/null 2>&1
ACTIVE_UUIDS=$(kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' 2>/dev/null)

# Возврат в supervisor
kubectl config use-context $SUPERVISOR_NS > /dev/null 2>&1

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 АНАЛИЗ PVC В SUPERVISOR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

kubectl get pvc -n $SUPERVISOR_NS --no-headers | while read line; do
    NAME=$(echo $line | awk '{print $1}')
    STATUS=$(echo $line | awk '{print $2}')
    CAPACITY=$(echo $line | awk '{print $4}')
    STORAGECLASS=$(echo $line | awk '{print $6}')
    AGE=$(echo $line | awk '{print $7}')

    # Извлечь UUID из имени (последняя часть после последнего префикса)
    UUID=$(echo $NAME | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')

    # Проверить используется ли
    USED_BY=$(kubectl describe pvc -n $SUPERVISOR_NS $NAME 2>/dev/null | grep "Used By:" | awk '{print $3}')

    # Проверить есть ли в активных
    if echo "$ACTIVE_UUIDS" | grep -q "$UUID"; then
        echo "✅ $NAME"
        echo "   Статус: ИСПОЛЬЗУЕТСЯ | Размер: $CAPACITY | Возраст: $AGE"
    elif [ "$USED_BY" == "<none>" ]; then
        echo "⚠️  $NAME"
        echo "   Статус: ORPHANED | Размер: $CAPACITY | Возраст: $AGE | Storage: $STORAGECLASS"
    else
        echo "🔄 $NAME"
        echo "   Статус: ПРОВЕРИТЬ | Размер: $CAPACITY | Возраст: $AGE"
    fi
    echo ""
done
```

Сохраните как `check-orphaned-pvc.sh` и запустите:

```bash
chmod +x check-orphaned-pvc.sh
./check-orphaned-pvc.sh
```

---

## Шаг 3: Идентификация orphaned PVC

### 3.1 Критерии orphaned PVC

PVC считается orphaned если выполняется **ЛЮБОЕ** из условий:

1. ✅ **Префикс не совпадает** с UID текущего кластера
   - Это PVC от старого удаленного кластера

2. ✅ **Used By: <none>** + UUID не найден в гостевом кластере
   - PVC существует в supervisor, но не в гостевом кластере

3. ✅ **Status: Bound** + возраст > 100 дней + не используется
   - Старые неиспользуемые PVC

4. ✅ **Status: Pending** + возраст > 7 дней
   - Зависшие операции создания/восстановления

### 3.2 Получить список orphaned PVC для удаления

#### Вариант 1: PVC от старых кластеров (безопасно)

```bash
# Найти все PVC с префиксом старого кластера
OLD_CLUSTER_PREFIX="77cd20b3-005c-4320-bcd1-502db9e7dafc"  # Замените на свой

kubectl get pvc -n $SUPERVISOR_NS --no-headers | grep "$OLD_CLUSTER_PREFIX"
```

#### Вариант 2: Неиспользуемые PVC (требует проверки)

```bash
# Получить список PVC с Used By: <none>
for pvc in $(kubectl get pvc -n $SUPERVISOR_NS --no-headers | awk '{print $1}'); do
  USED=$(kubectl describe pvc -n $SUPERVISOR_NS $pvc | grep "Used By:" | grep "<none>")
  if [ ! -z "$USED" ]; then
    echo $pvc
  fi
done
```

#### Вариант 3: Pending PVC (осторожно)

```bash
# Найти все Pending PVC старше 7 дней
kubectl get pvc -n $SUPERVISOR_NS --no-headers | grep "Pending" | awk '{print $1, $7}'
```

---

## Шаг 4: Безопасное удаление

### 4.1 Предварительные проверки (ОБЯЗАТЕЛЬНО!)

**Перед удалением КАЖДОГО PVC выполните:**

```bash
# 1. Проверить что PVC не используется
kubectl describe pvc -n $SUPERVISOR_NS <PVC_NAME> | grep "Used By:"
# Должно быть: Used By: <none>

# 2. Проверить возраст
kubectl get pvc -n $SUPERVISOR_NS <PVC_NAME>

# 3. Проверить что нет в гостевом кластере
# UUID из имени PVC (последняя часть)
PVC_UUID="301936d9-3085-40bc-92d0-980c777e4987"  # Замените на свой
kubectl config use-context YOUR-GUEST-CLUSTER
kubectl get pvc -A -o yaml | grep "uid: $PVC_UUID"
# Должно быть пусто

# 4. Вернуться в supervisor
kubectl config use-context $SUPERVISOR_NS
```

### 4.2 Удаление PVC от старого кластера (безопасно)

```bash
# Удалить все PVC с префиксом старого кластера
kubectl delete pvc -n $SUPERVISOR_NS \
  77cd20b3-005c-4320-bcd1-502db9e7dafc-0eb4df8e-4d91-401e-a02b-f8a99724bbd8 \
  77cd20b3-005c-4320-bcd1-502db9e7dafc-1bf051cf-50a7-4b2f-b77e-c32473a6cdec \
  77cd20b3-005c-4320-bcd1-502db9e7dafc-3b3ad28c-926f-4939-8c45-8f1d2417cd10
  # ... добавьте остальные

# Или массово (ОСТОРОЖНО!):
kubectl get pvc -n $SUPERVISOR_NS --no-headers | \
  grep "77cd20b3-005c-4320-bcd1-502db9e7dafc" | \
  awk '{print $1}' | \
  xargs kubectl delete pvc -n $SUPERVISOR_NS
```

### 4.3 Удаление отдельных orphaned PVC

```bash
# Удалить один конкретный PVC
kubectl delete pvc -n $SUPERVISOR_NS <PVC_NAME>

# Проверить что PV тоже удалился (reclaimPolicy: Delete)
kubectl get pv | grep <VOLUME_NAME>
# Должно быть пусто
```

### 4.4 Удаление нескольких PVC за раз

```bash
# Удалить несколько PVC одной командой
kubectl delete pvc -n $SUPERVISOR_NS \
  e63affb9-560b-49b9-9651-242450536942-394b5d02-d72d-476d-9484-415ac3fd0dde \
  e63affb9-560b-49b9-9651-242450536942-61e2f0ad-be62-4596-a078-82df707e91de \
  e63affb9-560b-49b9-9651-242450536942-e094eee6-4511-4ae0-8dce-7d2c74e52eb0
```

### 4.5 Проверка после удаления

```bash
# Проверить что PVC удалены
kubectl get pvc -n $SUPERVISOR_NS | grep <PREFIX>

# Проверить что PV удалены
kubectl get pv | grep <PREFIX>

# Подсчитать текущее количество PVC
echo "Осталось PVC: $(kubectl get pvc -n $SUPERVISOR_NS --no-headers | wc -l)"
```

---

## Шаг 5: Профилактика

### 5.1 Проверка StorageClass политики

```bash
# Получить список StorageClass
kubectl get storageclass

# Проверить reclaimPolicy (должно быть Delete для автоудаления)
kubectl get storageclass <STORAGE_CLASS_NAME> -o yaml | grep reclaimPolicy

# Если Retain - изменить на Delete:
kubectl patch storageclass <STORAGE_CLASS_NAME> \
  -p '{"reclaimPolicy":"Delete"}'
```

### 5.2 Регулярная проверка

Создайте cron job или запускайте периодически:

```bash
# Еженедельная проверка orphaned PVC
0 9 * * 1 /path/to/check-orphaned-pvc.sh > /var/log/pvc-check.log 2>&1
```

### 5.3 Правильное удаление приложений

**При удалении StatefulSet/приложений:**

```bash
# 1. Удалить приложение
kubectl delete statefulset <name> -n <namespace>

# 2. Удалить PVC (если они больше не нужны)
kubectl delete pvc <pvc-name> -n <namespace>

# 3. Проверить в supervisor что shadow PVC удалился
kubectl config use-context $SUPERVISOR_NS
kubectl get pvc -n $SUPERVISOR_NS | grep <PVC_UUID>
```

### 5.4 Правильное удаление TKG кластера

**Перед удалением кластера:**

```bash
# 1. Переключиться в контекст кластера
kubectl config use-context <cluster-name>

# 2. Удалить все PVC из всех namespace
kubectl get pvc -A
kubectl delete pvc --all -n <namespace>

# 3. Проверить что все удалено
kubectl get pvc -A

# 4. Переключиться в supervisor
kubectl config use-context $SUPERVISOR_NS

# 5. Проверить что shadow PVC удалились
kubectl get pvc -n $SUPERVISOR_NS

# 6. Теперь можно удалить кластер
kubectl delete tanzukubernetescluster <cluster-name> -n $SUPERVISOR_NS
```

---

## Troubleshooting

### Проблема 1: PVC не удаляется

**Симптом:**
```
Error from server (Deleting volume with snapshots is not allowed)
```

**Причина:** У PVC есть активные snapshots

**Решение:**

```bash
# 1. Проверить наличие snapshots (нужны права на volumesnapshots)
kubectl get volumesnapshots -n $SUPERVISOR_NS

# 2. Найти snapshots связанные с PVC
kubectl get volumesnapshots -n $SUPERVISOR_NS -o yaml | grep <PVC_NAME>

# 3. Удалить snapshots
kubectl delete volumesnapshot -n $SUPERVISOR_NS <SNAPSHOT_NAME>

# 4. Теперь удалить PVC
kubectl delete pvc -n $SUPERVISOR_NS <PVC_NAME>
```

**Альтернативное решение:** Удалить через vCenter
1. Зайти в vCenter
2. Найти Datastore
3. Найти VMDK с volumeHandle из PV
4. Удалить snapshots вручную

---

### Проблема 2: Нет прав на volumesnapshots

**Симптом:**
```
Error from server (Forbidden): volumesnapshots.snapshot.storage.k8s.io is forbidden
```

**Решение:**

1. Попросить администратора vSphere предоставить права
2. Или попросить администратора удалить snapshots
3. Или удалить через vCenter GUI

---

### Проблема 3: PVC зависает в Terminating

**Симптом:** PVC показывает статус "Terminating" долгое время

**Решение:**

```bash
# 1. Проверить finalizers
kubectl get pvc -n $SUPERVISOR_NS <PVC_NAME> -o yaml | grep finalizers -A5

# 2. Убрать finalizers (ОСТОРОЖНО! Может оставить orphaned VMDK)
kubectl patch pvc -n $SUPERVISOR_NS <PVC_NAME> \
  -p '{"metadata":{"finalizers":null}}' --type=merge

# 3. Принудительное удаление
kubectl delete pvc -n $SUPERVISOR_NS <PVC_NAME> --force --grace-period=0
```

⚠️ **Внимание:** Это может оставить orphaned VMDK файлы в vSphere!

---

### Проблема 4: Pending PVC не завершается

**Симптом:** PVC в статусе Pending более 24 часов

**Диагностика:**

```bash
# Проверить события
kubectl describe pvc -n $SUPERVISOR_NS <PVC_NAME>

# Проверить events
kubectl get events -n $SUPERVISOR_NS --sort-by='.lastTimestamp' | grep <PVC_NAME>
```

**Решение:**

```bash
# Если PVC зависший - удалить
kubectl delete pvc -n $SUPERVISOR_NS <PVC_NAME>

# Если не удаляется
kubectl delete pvc -n $SUPERVISOR_NS <PVC_NAME> --force --grace-period=0
```

---

### Проблема 5: Большое количество orphaned PVC

**Симптом:** Сотни orphaned PVC в namespace

**Массовое удаление:**

```bash
# ОСТОРОЖНО! Проверьте префикс несколько раз!
OLD_PREFIX="77cd20b3-005c-4320-bcd1-502db9e7dafc"

# Сначала проверить что будет удалено
kubectl get pvc -n $SUPERVISOR_NS --no-headers | grep "$OLD_PREFIX" | awk '{print $1}'

# Подсчитать
echo "Будет удалено: $(kubectl get pvc -n $SUPERVISOR_NS --no-headers | grep "$OLD_PREFIX" | wc -l) PVC"

# Удалить (после подтверждения)
kubectl get pvc -n $SUPERVISOR_NS --no-headers | \
  grep "$OLD_PREFIX" | \
  awk '{print $1}' | \
  xargs kubectl delete pvc -n $SUPERVISOR_NS
```

---

## Полезные команды

### Быстрая диагностика

```bash
# Подсчет PVC по статусам
kubectl get pvc -n $SUPERVISOR_NS --no-headers | awk '{print $2}' | sort | uniq -c

# Подсчет по StorageClass
kubectl get pvc -n $SUPERVISOR_NS --no-headers | awk '{print $6}' | sort | uniq -c

# Топ 10 самых больших PVC
kubectl get pvc -n $SUPERVISOR_NS --no-headers | \
  awk '{print $4, $1}' | \
  sort -hr | head -10

# Топ 10 самых старых PVC
kubectl get pvc -n $SUPERVISOR_NS --sort-by=.metadata.creationTimestamp | head -10
```

### Экспорт данных

```bash
# Экспорт списка всех PVC в CSV
kubectl get pvc -n $SUPERVISOR_NS -o custom-columns=\
NAME:.metadata.name,\
STATUS:.status.phase,\
CAPACITY:.spec.resources.requests.storage,\
STORAGECLASS:.spec.storageClassName,\
AGE:.metadata.creationTimestamp \
--no-headers | \
sed 's/\s\+/,/g' > pvc-report.csv
```

---

## Контрольный чеклист

Перед удалением PVC убедитесь:

- [ ] Проверен контекст kubectl (supervisor namespace)
- [ ] PVC показывает "Used By: <none>"
- [ ] UUID PVC не найден в гостевом кластере
- [ ] PVC не является частью активного приложения
- [ ] Возраст PVC > 7 дней (для Pending) или > 30 дней (для Bound)
- [ ] Есть backup важных данных (если нужны)
- [ ] StorageClass имеет reclaimPolicy: Delete
- [ ] Нет активных snapshots (или они тоже будут удалены)

После удаления проверьте:

- [ ] PVC удален из supervisor namespace
- [ ] PV удален автоматически
- [ ] Освобождено место на datastore (проверить в vCenter)
- [ ] Активные приложения работают нормально
- [ ] Нет orphaned VMDK файлов в vSphere

---

## Полезные ссылки

- [VMware vSphere with Tanzu Documentation](https://docs.vmware.com/en/VMware-vSphere/8.0/vsphere-with-tanzu-concepts-planning/GUID-152BE7D2-E227-4DAA-B527-557B564D9718.html)
- [Kubernetes Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [vSphere CSI Driver](https://docs.vmware.com/en/VMware-vSphere-Container-Storage-Plug-in/index.html)

---

## История изменений

| Дата | Версия | Изменения |
|------|--------|-----------|
| 2025-10-21 | 1.0 | Первая версия инструкции |

---

**Автор:** Созд��но на основе практического опыта очистки PVC
**Последнее обновление:** 2025-10-21
