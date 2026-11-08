#!/usr/bin/env bash
# =============================================================================
# Observability Stack — Install Script (clean rebuild)
# Stack: kube-prometheus-stack (Prometheus + Grafana UI) + Tempo (traces).
# All in the `observability` namespace.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
CHARTS_DIR="$BASE_DIR/charts"
MANIFESTS_DIR="$BASE_DIR/manifests"
ENV_FILE="$BASE_DIR/.env.observability"

# ---- Load env ----
if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] $ENV_FILE not found."
  echo "  cp .env.observability.example .env.observability"
  exit 1
fi
set -a
source "$ENV_FILE"
set +a

# GRAFANA_ADMIN_PASSWORD is set via .env.observability (do not override here).

echo "========================================"
echo " Observability Stack Installer (Lite)"
echo " Namespace: observability"
echo " Components: Prometheus + Grafana + Tempo"
echo "========================================"

# ---- Step 1: Add Helm repositories ----
echo ""
echo "[1/4] Adding Helm repositories..."
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# ---- Step 2: Create namespace ----
echo ""
echo "[2/4] Creating namespace..."
kubectl create namespace observability 2>/dev/null || true

# ---- Step 3: Install Tempo (trace storage) ----
echo ""
echo "[3/4] Installing Tempo (distributed tracing storage)..."
helm upgrade --install tempo grafana/tempo \
  --version 1.21.1 \
  --namespace observability \
  -f "$CHARTS_DIR/tempo-values.yaml" \
  --wait --timeout 5m

# ---- Step 4: Install kube-prometheus-stack (Prometheus + Grafana) ----
echo ""
echo "[4/4] Installing Prometheus + Grafana (kube-prometheus-stack)..."
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version 72.6.2 \
  --namespace observability \
  -f "$CHARTS_DIR/kube-prometheus-stack-values.yaml" \
  --set grafana.adminPassword="$GRAFANA_ADMIN_PASSWORD" \
  --wait --timeout 8m

# ---- Step 5: Apply ingress ----
echo ""
echo "[5/5] Applying ingress..."
kubectl apply -f "$MANIFESTS_DIR/ingress/grafana.yaml"

echo ""
echo "========================================"
echo " Observability Stack (Lite) deployed!"
echo ""
echo " Grafana:   https://web-dev1-grafana.vucongtuanduong.dpdns.org (admin/$GRAFANA_ADMIN_PASSWORD)"
echo " Prometheus: monitoring-kube-prometheus-prometheus.observability.svc.cluster.local:9090"
echo " Tempo:     tempo.observability.svc.cluster.local:3200 (query), :4318 (OTLP HTTP)"
echo "========================================"
echo " Pods:"
kubectl get pods -n observability
echo "========================================"
