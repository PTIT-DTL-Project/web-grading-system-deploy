#!/usr/bin/env bash
# =============================================================================
# Observability Stack — Install Script (clean rebuild)
# Stack: kube-prometheus-stack (Prometheus + Grafana + Node Exporter +
#        kube-state-metrics) + Loki (logs, via promtail) + Tempo (traces) +
#        Alloy (OTLP collector) + Pyroscope (profiling).
# All in the `observability` namespace.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
CHARTS_DIR="$BASE_DIR/charts"
MANIFESTS_DIR="$BASE_DIR/manifests"
DASHBOARDS_DIR="$BASE_DIR/dashboards"
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
echo " Observability Stack Installer"
echo " Namespace: observability"
echo "========================================"

# ---- Step 1: Add Helm repositories ----
echo ""
echo "[1/8] Adding Helm repositories..."
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add pyrox https://grafana.github.io/helm-charts
helm repo update

# ---- Step 2: Create namespace ----
echo ""
echo "[2/8] Creating namespace..."
kubectl create namespace observability 2>/dev/null || true

# ---- Step 3: Install Loki (log aggregation + promtail) ----
echo ""
echo "[3/8] Installing Loki (+ promtail log shipping)..."
helm upgrade --install loki grafana/loki \
  --version 7.0.0 \
  --namespace observability \
  -f "$CHARTS_DIR/loki-values.yaml" \
  --wait --timeout 5m

# ---- Step 4: Install Tempo (trace storage) ----
echo ""
echo "[4/8] Installing Tempo..."
helm upgrade --install tempo grafana/tempo \
  --version 1.21.1 \
  --namespace observability \
  -f "$CHARTS_DIR/tempo-values.yaml" \
  --wait --timeout 5m

# ---- Step 4b: Install Pyroscope (continuous profiling) ----
echo ""
echo "[4b/8] Installing Pyroscope..."
helm upgrade --install pyroscope grafana/pyroscope \
  --version 2.2.1 \
  --namespace observability \
  -f "$CHARTS_DIR/pyroscope-values.yaml" \
  --wait --timeout 5m

# ---- Step 5: Install Alloy (OTLP trace collector: backend services -> Tempo) ----
echo ""
echo "[5/8] Installing Alloy (OTLP collector)..."
helm upgrade --install alloy grafana/alloy \
  --version 1.0.3 \
  --namespace observability \
  -f "$CHARTS_DIR/alloy-values.yaml" \
  --wait --timeout 5m

# ---- Step 6: Install kube-prometheus-stack (Prometheus + Grafana + Node Exporter) ----
echo ""
echo "[6/8] Installing Prometheus + Grafana + Node Exporter (kube-prometheus-stack)..."
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version 72.6.2 \
  --namespace observability \
  -f "$CHARTS_DIR/kube-prometheus-stack-values.yaml" \
  --set grafana.adminPassword="$GRAFANA_ADMIN_PASSWORD" \
  --wait --timeout 8m

# ---- Step 7: Import dashboard + ingress ----
echo ""
echo "[7/8] Importing dashboard and ingress..."
# Label the dashboard ConfigMap so Grafana's sidecar imports it.
kubectl create configmap grafana-dashboards \
  --from-file=k8s-general.json="$DASHBOARDS_DIR/k8s-general.json" \
  -n observability --dry-run=client -o yaml | \
  kubectl apply -f -

kubectl apply -f "$MANIFESTS_DIR/ingress/grafana.yaml"
kubectl apply -f "$MANIFESTS_DIR/ingress/otlp.yaml"
kubectl apply -f "$MANIFESTS_DIR/ingress/pyroscope.yaml"

echo "[8/8] Finalizing setup..."
echo ""
echo "========================================"
echo " Observability Stack deployed!"
echo ""
echo " Grafana:  https://web-dev2-grafana.vucongtuanduong.dpdns.org (admin/$GRAFANA_ADMIN_PASSWORD)"
echo " Prometheus: prometheus-operated.observability.svc.cluster.local:9090"
echo " Loki:     loki.observability.svc.cluster.local:3100  (logs, via promtail)"
echo " Tempo:    tempo.observability.svc.cluster.local:3200  (traces)"
echo " Alloy:    alloy.observability.svc.cluster.local:4317  (OTLP collector)"
echo " Pyroscope: pyroscope.observability.svc.cluster.local:4100  (continuous profiling)"
echo " Nodes:    node-exporter DaemonSet (host metrics) + kube-state-metrics"
echo ""
echo " Pods:"
kubectl get pods -n observability
echo "========================================"
