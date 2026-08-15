#!/usr/bin/env bash
# =============================================================================
# Observability Stack — Uninstall Script (clean rebuild)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo " Observability Stack Uninstaller"
echo "========================================"
echo ""
echo "This will remove: kube-prometheus-stack (Prometheus/Grafana/Node Exporter), Alloy, Tempo, Loki, grafana-dashboards"
echo "PVCs will NOT be deleted (data preserved)."
echo ""

read -p "Are you sure? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "[1/8] Removing kube-prometheus-stack (Prometheus + Grafana + Node Exporter)..."
helm uninstall monitoring -n observability 2>/dev/null || true

echo ""
echo "[2/8] Removing Alloy (OTLP collector)..."
helm uninstall alloy -n observability 2>/dev/null || true

echo ""
echo "[3/8] Removing Tempo..."
helm uninstall tempo -n observability 2>/dev/null || true

echo ""
echo "[4/8] Removing Loki..."
helm uninstall loki -n observability 2>/dev/null || true

echo ""
echo "[5/8] Removing Grafana dashboard configmap..."
kubectl delete configmap grafana-dashboards -n observability 2>/dev/null || true

echo ""
echo "[6/8] Removing ingress..."
kubectl delete ingress grafana -n observability 2>/dev/null || true

echo ""
echo "[7/8] Removing namespace..."
kubectl delete namespace observability 2>/dev/null || true

echo ""
echo "========================================"
echo " Observability Stack removed!"
echo " PVCs still exist:"
echo "   kubectl get pvc -n observability"
echo " Delete manually if needed:"
echo "   kubectl get pvc -n observability -o name | xargs -r kubectl delete -n observability"
echo "========================================"
