#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${1:-web-grading}"

echo "=== Creating ${NAMESPACE} namespace ==="
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "=== Creating secrets from .env ==="
if [ -f "${SCRIPT_DIR}/../.env" ]; then
  set -o allexport
  source "${SCRIPT_DIR}/../.env"
  set +o allexport
fi

# Database secrets
kubectl create secret generic db-secret \
  --namespace "${NAMESPACE}" \
  --from-literal=DB_HOST="${DB_HOST:-postgres-service}" \
  --from-literal=DB_PORT="${DB_PORT:-5432}" \
  --from-literal=DB_USERNAME="${DB_USERNAME:-postgres}" \
  --from-literal=DB_PASSWORD="${DB_PASSWORD:-postgres}" \
  --dry-run=client -o yaml | kubectl apply -f -

# RustFS secrets
kubectl create secret generic rustfs-secret \
  --namespace "${NAMESPACE}" \
  --from-literal=RUSTFS_ENDPOINT="${RUSTFS_ENDPOINT:-http://rustfs:9000}" \
  --from-literal=RUSTFS_PUBLIC_ENDPOINT="${RUSTFS_PUBLIC_ENDPOINT:-https://web-dev1-rustfs-api.vucongtuanduong.dpdns.org}" \
  --from-literal=RUSTFS_ACCESS_KEY="${RUSTFS_ACCESS_KEY:-minioadmin}" \
  --from-literal=RUSTFS_SECRET_KEY="${RUSTFS_SECRET_KEY:-minioadmin}" \
  --dry-run=client -o yaml | kubectl apply -f -

# App config (log level for all services)
kubectl create secret generic app-config \
  --namespace "${NAMESPACE}" \
  --from-literal=APP_LOG_LEVEL="${APP_LOG_LEVEL:-INFO}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Gateway ↔ services trust secret (stamped as X-Gateway-Secret by api-gateway, checked by
# course/result/submission). A blank value is fail-closed in the services (401 on every
# authenticated request), so fall back to the existing value, then to a fresh random one,
# rather than silently pushing an empty secret on every re-run.
if [ -z "${GATEWAY_TRUSTED_SECRET}" ]; then
  GATEWAY_TRUSTED_SECRET="$(openssl rand -hex 32)"
fi
kubectl create secret generic gateway-trust \
  --namespace "${NAMESPACE}" \
  --from-literal=GATEWAY_TRUSTED_SECRET="${GATEWAY_TRUSTED_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Kafka (Aiven SASL_SSL/SCRAM) credentials
kubectl create secret generic kafka-aiven-credentials \
  --namespace "${NAMESPACE}" \
  --from-literal=username="${KAFKA_USERNAME:-}" \
  --from-literal=password="${KAFKA_PASSWORD:-}" \
  --from-literal=bootstrap-servers="${KAFKA_BOOTSTRAP_SERVERS:-localhost:9092}" \
  --from-file=ca.pem="${KAFKA_CA_PATH:-src-services/executor-service/docker/kafka-ca.pem}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Keycloak DB + admin bootstrap
kubectl create secret generic keycloak-db \
  --namespace "${NAMESPACE}" \
  --from-literal=KEYCLOAK_DB_URL="${KEYCLOAK_DB_URL:-}" \
  --from-literal=KEYCLOAK_DB_USERNAME="${KEYCLOAK_DB_USERNAME:-}" \
  --from-literal=KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-}" \
  --from-literal=KEYCLOAK_ADMIN_USERNAME="${KEYCLOAK_ADMIN_USERNAME:-admin}" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Namespace and secrets created"
