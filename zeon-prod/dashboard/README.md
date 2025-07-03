# Kubernetes Dashboard User Management

Автоматизированные скрипты для управления пользователями Kubernetes Dashboard в проекте ZEON.

## 📋 Описание

Данные скрипты позволяют автоматизировать:
- Установку Kubernetes Dashboard через Helm
- Создание и настройку пользователей
- Управление правами доступа
- Генерацию и сохранение токенов аутентификации

## 🗂️ Состав

- **`setup-dashboard-users.ps1`** - Основной скрипт для массовой настройки пользователей
- **`manage-users.ps1`** - Скрипт для управления отдельными пользователями
- **`dashboard-status.ps1`** - Проверка состояния Dashboard и быстрый доступ
- **`quick-start.ps1`** - Быстрый справочник команд
- **`tokens/`** - Папка с токенами пользователей
- **`manifests/`** - Папка с YAML манифестами
- **`ingress-dashboard.yaml`** - Ingress конфигурация для Dashboard

## 🚀 Быстрый старт

### 1. Полная настройка Dashboard и пользователей

```powershell
# Установка Dashboard и создание всех пользователей
.\setup-dashboard-users.ps1
```

### 2. Настройка без установки Dashboard

```powershell
# Только создание пользователей (Dashboard уже установлен)
.\setup-dashboard-users.ps1 -SkipHelmInstall
```

### 3. Пересоздание существующих пользователей

```powershell
# Пересоздать пользователей, если они уже существуют
.\setup-dashboard-users.ps1 -ForceRecreate
```

## 👥 Управление пользователями

### Добавление нового пользователя

```powershell
# Добавить пользователя с правами edit
.\manage-users.ps1 -Action add -UserName "new-user" -Role "edit"

# Добавить администратора
.\manage-users.ps1 -Action add -UserName "new-admin" -Role "cluster-admin"
```

### Удаление пользователя

```powershell
# Удалить пользователя с подтверждением
.\manage-users.ps1 -Action remove -UserName "old-user"

# Удалить без подтверждения
.\manage-users.ps1 -Action remove -UserName "old-user" -Force
```

### Просмотр списка пользователей

```powershell
# Показать всех пользователей
.\manage-users.ps1 -Action list
```

### Получение токена

```powershell
# Получить токен для пользователя
.\manage-users.ps1 -Action token -UserName "username"
```

## 🔐 Роли и права доступа

| Роль | Права | Описание |
|------|-------|----------|
| `view` | Только просмотр | Чтение ресурсов |
| `edit` | Чтение + редактирование | Управление ресурсами в namespace |
| `admin` | Полные права в namespace | Администрирование namespace |
| `cluster-admin` | Полные права в кластере | Суперпользователь |

## 🔧 Параметры скриптов

### setup-dashboard-users.ps1

```powershell
# Параметры
-Namespace <string>     # Namespace для Dashboard (по умолчанию: kubernetes-dashboard)
-SkipHelmInstall       # Пропустить установку Helm Chart
-ForceRecreate         # Пересоздать существующие ресурсы
```

### manage-users.ps1

```powershell
# Обязательные параметры
-Action <string>        # Действие: add, remove, list, token

# Дополнительные параметры
-UserName <string>      # Имя пользователя
-Role <string>          # Роль: view, edit, admin, cluster-admin
-Namespace <string>     # Namespace (по умолчанию: kubernetes-dashboard)
-Force                  # Выполнить без подтверждения
```

## 📁 Структура файлов

После выполнения скриптов создаются следующие файлы:

```
dashboard/
├── setup-dashboard-users.ps1      # Основной скрипт
├── manage-users.ps1               # Скрипт управления
├── dashboard-status.ps1           # Проверка состояния
├── quick-start.ps1               # Быстрый справочник
├── README.md                     # Данная инструкция
├── ingress-dashboard.yaml        # Ingress конфигурация
├── tokens/                       # Токены пользователей
│   ├── admin-token.txt           # Токен администратора
│   ├── air-erik-token.txt        # Токен пользователя air-erik
│   └── soothemysoul-token.txt    # Токен пользователя soothemysoul
└── manifests/                    # YAML манифесты
    ├── secret.admin.yaml         # Манифест токена для admin
    ├── secret.air-erik.yaml      # Манифест токена для air-erik
    └── secret.soothemysoul.yaml  # Манифест токена для soothemysoul
```

## 🌐 Доступ к Dashboard

### Метод 1: Port-forward

```bash
# Создать туннель к Dashboard
kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443

# Открыть в браузере
# https://localhost:8443
```

### Метод 2: Ingress (если настроен)

```bash
# Доступ через Ingress
# https://zeon-devdashboard.project.client.loc
```

### Аутентификация

1. На странице входа выберите "Token"
2. Скопируйте токен из соответствующего файла в папке `tokens/`
3. Вставьте токен в поле аутентификации

## 🛠️ Устранение неполадок

### Проблема: Токен не генерируется

```powershell
# Проверить статус Secret
kubectl -n kubernetes-dashboard get secret username-token

# Пересоздать Secret
kubectl -n kubernetes-dashboard delete secret username-token
kubectl apply -f manifests/secret.username.yaml
```

### Проблема: Ошибка доступа

```powershell
# Проверить ClusterRoleBinding
kubectl get clusterrolebinding username-binding

# Пересоздать привязку
kubectl delete clusterrolebinding username-binding
kubectl create clusterrolebinding username-binding --clusterrole=edit --serviceaccount=kubernetes-dashboard:username
```

### Проблема: Dashboard недоступен

```powershell
# Проверить статус подов
kubectl -n kubernetes-dashboard get pods

# Проверить сервисы
kubectl -n kubernetes-dashboard get svc
```

## 🔍 Мониторинг и логи

### Просмотр логов Dashboard

```bash
# Логи основного пода
kubectl -n kubernetes-dashboard logs -l k8s-app=kubernetes-dashboard

# Логи Kong proxy
kubectl -n kubernetes-dashboard logs -l app.kubernetes.io/name=kong
```

### Проверка состояния пользователей

```powershell
# Список всех пользователей
.\manage-users.ps1 -Action list

# Проверка конкретного пользователя
kubectl -n kubernetes-dashboard get serviceaccount username
kubectl get clusterrolebinding username-binding
```

## 🔄 Обновление и сопровождение

### Обновление Dashboard

```bash
# Обновить Helm репозиторий
helm repo update

# Обновить Dashboard
helm upgrade kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
  --namespace kubernetes-dashboard \
  --set metricsScraper.enabled=true \
  --set adminAccessLog.enabled=true
```

### Ротация токенов

```powershell
# Пересоздать токен для пользователя
.\manage-users.ps1 -Action remove -UserName "username" -Force
.\manage-users.ps1 -Action add -UserName "username" -Role "edit"
```

## 📚 Дополнительные ресурсы

- [Kubernetes Dashboard Documentation](https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/)
- [Helm Chart Documentation](https://github.com/kubernetes/dashboard/tree/master/charts/kubernetes-dashboard)
- [RBAC в Kubernetes](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

## 🤝 Поддержка

При возникновении проблем:
1. Проверьте логи выполнения скриптов
2. Убедитесь, что у вас есть права администратора кластера
3. Проверьте доступность Helm и kubectl
4. Обратитесь к документации выше

---

**Автор:** DevOps Team
**Версия:** 1.0
**Дата:** 2024
