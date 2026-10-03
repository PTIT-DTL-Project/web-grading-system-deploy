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

# Keycloak Admin client (service account of client wgs-user-service) — the ONLY
# credential with which api-gateway calls the Keycloak Admin API (user lookup +
# reset-password for POST /api/v1/account/change-password). The frontend used to
# ship this secret to every browser bundle (VITE_KEYCLOAK_ADMIN_CLIENT_SECRET) —
# that is exactly why it now lives only in this K8s Secret. An empty value would
# silently disable password change at runtime, and the value comes from Keycloak
# (not from us, so no auto-generation): fail loudly instead of pushing an empty secret.
#
# Same secret also carries the Phase 3 (D11) password-verification client: since
# Direct Access Grants go OFF on the browser client web-grading-fe, the gateway
# verifies currentPassword with its own confidential client wgs-password-verify.
# A half-set pair is always a misconfiguration (the grant answers invalid_client → 502),
# so it fails loudly like the admin keys; BOTH EMPTY stays legal — the gateway then
# falls back to web-grading-fe with no secret, exactly the pre-Phase-3 behaviour a
# fresh Phase 1 setup (runbook §4) runs with before runbook §10.2 creates the client.
if [ -z "${KEYCLOAK_ADMIN_CLIENT_ID:-}" ] || [ -z "${KEYCLOAK_ADMIN_CLIENT_SECRET:-}" ]; then
  echo "ERROR: KEYCLOAK_ADMIN_CLIENT_ID and KEYCLOAK_ADMIN_CLIENT_SECRET must both be set" >&2
  echo "in .env (values come from Keycloak client wgs-user-service credentials)." >&2
  echo "Refusing to create an empty keycloak-admin-client secret." >&2
  exit 1
fi
if [ -n "${KEYCLOAK_PASSWORD_CLIENT_ID:-}" ] && [ -z "${KEYCLOAK_PASSWORD_CLIENT_SECRET:-}" ]; then
  echo "ERROR: KEYCLOAK_PASSWORD_CLIENT_SECRET is empty while KEYCLOAK_PASSWORD_CLIENT_ID is set." >&2
  echo "Set it in .env from Keycloak client wgs-password-verify credentials (runbook §10.2)." >&2
  echo "Refusing to push a partial password-verify credential." >&2
  exit 1
fi
if [ -z "${KEYCLOAK_PASSWORD_CLIENT_ID:-}" ] && [ -n "${KEYCLOAK_PASSWORD_CLIENT_SECRET:-}" ]; then
  echo "ERROR: KEYCLOAK_PASSWORD_CLIENT_ID is empty while KEYCLOAK_PASSWORD_CLIENT_SECRET is set." >&2
  echo "Set KEYCLOAK_PASSWORD_CLIENT_ID=wgs-password-verify in .env (runbook §10.2)." >&2
  echo "Refusing to push a partial password-verify credential." >&2
  exit 1
fi
# The ID default mirrors password-client-id in the gateway's application.yaml — the key
# must NEVER be pushed empty, because an empty env var overrides that yaml default and
# the gateway would send client_id= (invalid_client → 502) instead of falling back.
kubectl create secret generic keycloak-admin-client \
  --namespace "${NAMESPACE}" \
  --from-literal=KEYCLOAK_ADMIN_CLIENT_ID="${KEYCLOAK_ADMIN_CLIENT_ID}" \
  --from-literal=KEYCLOAK_ADMIN_CLIENT_SECRET="${KEYCLOAK_ADMIN_CLIENT_SECRET}" \
  --from-literal=KEYCLOAK_PASSWORD_CLIENT_ID="${KEYCLOAK_PASSWORD_CLIENT_ID:-web-grading-fe}" \
  --from-literal=KEYCLOAK_PASSWORD_CLIENT_SECRET="${KEYCLOAK_PASSWORD_CLIENT_SECRET:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Namespace and secrets created"
