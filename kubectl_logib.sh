#!/usr/bin/env bash
set -euo pipefail

# 1) Запрашиваем учётные данные vSphere
read -p "vSphere username: " administrator@zeon.loc
read -s -p "vSphere password: " Tf34gfasz!
echo

# 2) Список кластеров: server|namespace|cluster-name
# Добавьте свои сервера и имена сюда:
clusters=(
  "172.16.50.194|zeon-prod|zeon-prod-cluster"
  "172.16.50.194|zeon-dev|zeon-dev-cluster"
  "172.16.50.194|dev-infrastructure|dev-infrastructure-cluster"
)

# 3) Проходимся по списку и логинимся в каждый
for entry in "${clusters[@]}"; do
  IFS="|" read -r SERVER NAMESPACE CLUSTER <<< "$entry"
  echo -e "\n▶️  Logging into cluster '$CLUSTER' on server $SERVER (namespace: $NAMESPACE)..."
  kubectl vsphere login \
    --server="${SERVER}" \
    --insecure-skip-tls-verify \
    --tanzu-kubernetes-cluster-namespace "${NAMESPACE}" \
    --tanzu-kubernetes-cluster-name "${CLUSTER}" \
    --vsphere-username "${VSPHERE_USER}" \
    --vsphere-password "${VSPHERE_PASSWORD}"
done

echo -e "\n✅  All logins completed."
