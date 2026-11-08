#!/usr/bin/env bash
# =============================================================================
# Observability Stack (Lite) — Uninstall Script
# Removes: kube-prometheus-stack (Prometheus + Grafana), Tempo.
# =============================================================================
set -euo pipefail

echo "========================================"
echo " Observability Stack (Lite) Uninstaller"
echo "========================================"
echo ""
echo "This will remove: kube-prometheus-stack (Prometheus + Grafana), Tempo."
echo "PVCs will NOT be deleted (data preserved)."
echo ""

read -p "Are you sure? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "[1/2] Removing kube-prometheus-stack..."
helm uninstall monitoring -n observability 2>/dev/null || true

echo ""
echo "[2/2] Removing Tempo..."
helm uninstall tempo -n observability 2>/dev/null || true

echo ""
echo "[3/3] Removing ingress..."
kubectl delete ingress grafana -n observability 2>/dev/null || true

echo ""
echo "========================================"
echo " Observability Stack removed!"
echo " PVCs still exist:"
echo "   kubectl get pvc -n observability"
echo " Delete manually if needed:"
echo "   kubectl get pvc -n observability -o name | xargs -r kubectl delete -n observability"
echo "========================================"
