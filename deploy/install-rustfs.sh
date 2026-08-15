#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${1:-web-grading}"

echo "=== Deploying RustFS ==="
kubectl apply -n "$NAMESPACE" -f "$SCRIPT_DIR/rustfs/pvc.yaml"
kubectl apply -n "$NAMESPACE" -f "$SCRIPT_DIR/rustfs/service.yaml"
kubectl apply -n "$NAMESPACE" -f "$SCRIPT_DIR/rustfs/deployment.yaml"
kubectl apply -n "$NAMESPACE" -f "$SCRIPT_DIR/rustfs/ingress.yaml"

echo "=== Waiting for RustFS ==="
kubectl wait -n "$NAMESPACE" --for=condition=ready pod -l app=rustfs --timeout=120s || true

echo "=== RustFS ready at rustfs:9000 ==="
