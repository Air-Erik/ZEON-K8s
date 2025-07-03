# 🔧 Решение проблем авторизации в Tanzu Kubernetes кластерах

> **Проблема**: После удаления и пересоздания Tanzu Kubernetes кластера с тем же именем, kubectl выдает ошибку `You must be logged in to the server (Unauthorized)` даже после успешной авторизации через `kubectl vsphere login`.

## 📋 Симптомы проблемы

```bash
$ kubectl vsphere login --server <IP> --tanzu-kubernetes-cluster-name <cluster-name> -u <user>
# Авторизация проходит успешно

$ kubectl get ns
error: You must be logged in to the server (Unauthorized)
```

## 🔍 Причина проблемы

При пересоздании кластера с тем же именем:
- **Kubernetes API Server получает новые TLS сертификаты**
- **kubectl кеширует старые токены** от предыдущего кластера
- **kubectl vsphere login не всегда корректно обновляет** кешированные credentials
- **Контекст остается с невалидными токенами**

## ✅ Пошаговое решение

### Шаг 1: Проверка статуса кластера
```bash
# Переключаемся на supervisor cluster namespace
kubectl config use-context <supervisor-namespace>

# Проверяем что кластер действительно готов
kubectl get tanzukubernetescluster <cluster-name> -n <namespace> -o wide
```

**Что ищем:**
- `READY: True`
- `CONTROL PLANE: X` (нужное количество)
- `WORKER: Y` (нужное количество)

### Шаг 2: Получение актуального API Endpoint
```bash
kubectl get tanzukubernetescluster <cluster-name> -n <namespace> \
  -o jsonpath='{.status.apiEndpoints[0].host}:{.status.apiEndpoints[0].port}'
```

**Зачем:** Убеждаемся что IP адрес кластера не изменился.

### Шаг 3: Удаление проблемного контекста
```bash
# Удаляем старый контекст с невалидными токенами
kubectl config delete-context <cluster-name>
```

**Почему важно:** Старый контекст содержит кешированные токены от удаленного кластера.

### Шаг 4: Получение актуального kubeconfig
```bash
# Получаем fresh kubeconfig напрямую из Kubernetes секрета
kubectl get secret <cluster-name>-kubeconfig -n <namespace> \
  -o jsonpath='{.data.value}' | base64 -d > temp-kubeconfig.yaml
```

**Почему это работает:** Секрет содержит актуальные TLS сертификаты и токены нового кластера.

### Шаг 5: Переименование контекста
```bash
# Переименовываем контекст в понятное имя
kubectl --kubeconfig=temp-kubeconfig.yaml config rename-context \
  $(kubectl --kubeconfig=temp-kubeconfig.yaml config current-context) \
  <cluster-name>
```

### Шаг 6: Проверка работоспособности
```bash
# Тестируем что новый kubeconfig работает
kubectl --kubeconfig=temp-kubeconfig.yaml get ns
kubectl --kubeconfig=temp-kubeconfig.yaml get nodes
```

**Должны увидеть:** Список namespaces и узлов без ошибок авторизации.

### Шаг 7: Интеграция в основной kubeconfig
```bash
# Создаем backup текущего kubeconfig
cp ~/.kube/config ~/.kube/config.backup

# Объединяем старый kubeconfig с новым рабочим контекстом
KUBECONFIG=~/.kube/config.backup:temp-kubeconfig.yaml \
  kubectl config view --flatten > merged-config.yaml

# Заменяем основной kubeconfig
cp merged-config.yaml ~/.kube/config
```

### Шаг 8: Финальная проверка
```bash
# Переключаемся на кластер
kubectl config use-context <cluster-name>

# Проверяем что всё работает
kubectl get ns
kubectl get nodes
```

### Шаг 9: Очистка временных файлов
```bash
rm temp-kubeconfig.yaml merged-config.yaml ~/.kube/config.backup
```

## 🚀 Альтернативный быстрый способ

Если нужно только временно поработать с кластером:

```bash
# Получаем kubeconfig и работаем через флаг
kubectl get secret <cluster-name>-kubeconfig -n <namespace> \
  -o jsonpath='{.data.value}' | base64 -d > cluster-kubeconfig.yaml

# Используем напрямую
kubectl --kubeconfig=cluster-kubeconfig.yaml get ns
kubectl --kubeconfig=cluster-kubeconfig.yaml get pods
```

## 📝 Профилактика проблемы

### 1. Обновите скрипт автологина
Добавьте ваш кластер в `Login-AllClusters.ps1`:

```powershell
$clusters = @(
    # ... existing clusters ...
    @{ Server = "<supervisor-ip>"; Namespace = "<namespace>"; Name = "<cluster-name>" }
)
```

### 2. Всегда проверяйте статус после пересоздания
```bash
# После пересоздания кластера всегда проверяйте:
kubectl get tanzukubernetescluster <cluster-name> -n <namespace>
kubectl describe tanzukubernetescluster <cluster-name> -n <namespace>
```

### 3. При проблемах с авторизацией
Сначала попробуйте получить kubeconfig из секрета - это самый надежный способ.

## ⚠️ Важные замечания

1. **Не используйте kubectl vsphere login** сразу после пересоздания кластера - лучше получить kubeconfig из секрета
2. **Всегда делайте backup** ~/.kube/config перед внесением изменений
3. **IP адрес кластера может измениться** при пересоздании - всегда проверяйте актуальный endpoint
4. **Дождитесь полной готовности** кластера (READY: True) перед попытками подключения

## 🎯 Итоговый результат

После выполнения инструкции вы получите:
- ✅ Рабочий контекст кластера в основном kubeconfig
- ✅ Возможность переключаться между кластерами через `kubectl config use-context`
- ✅ Полнофункциональный доступ к кластеру без ошибок авторизации
- ✅ Сохранение всех остальных контекстов

---

**Время выполнения:** ~5-10 минут
**Сложность:** Средняя
**Требования:** Доступ к supervisor cluster и права на чтение секретов
