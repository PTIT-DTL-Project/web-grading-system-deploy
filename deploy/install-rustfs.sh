#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${1:-web-grading}"

# The Deployment reads its root credentials from `rustfs-secret` (created by
# setup-namespace.sh). Without that Secret the pod stops at
# CreateContainerConfigError, so fail here with an actionable message instead of
# letting `kubectl apply` look successful.
if ! kubectl -n "$NAMESPACE" get secret rustfs-secret >/dev/null 2>&1; then
  echo "ERROR: secret rustfs-secret not found in namespace $NAMESPACE." >&2
  echo "       Run deploy/setup-namespace.sh $NAMESPACE first (it creates the RustFS credentials)." >&2
  exit 1
fi

echo "=== Deploying RustFS ==="
kubectl apply -n "$NAMESPACE" -f "$SCRIPT_DIR/rustfs/pvc.yaml"
kubectl apply -n "$NAMESPACE" -f "$SCRIPT_DIR/rustfs/service.yaml"
kubectl apply -n "$NAMESPACE" -f "$SCRIPT_DIR/rustfs/deployment.yaml"
kubectl apply -n "$NAMESPACE" -f "$SCRIPT_DIR/rustfs/ingress.yaml"

echo "=== Waiting for RustFS ==="
kubectl wait -n "$NAMESPACE" --for=condition=ready pod -l app=rustfs --timeout=120s || true

echo "=== RustFS ready at rustfs:9000 ==="
