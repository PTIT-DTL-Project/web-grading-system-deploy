#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${1:-web-grading}"

echo "=== Creating Ingress resources ==="
for f in "$SCRIPT_DIR/ingress"/*.yaml; do
  echo "  Applying: $(basename "$f")"
  kubectl apply -n "$NAMESPACE" -f "$f"
done

echo "=== All ingresses created ==="
