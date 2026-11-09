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

: "${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD must be set in .env.observability}"
GRAFANA_DOMAIN="${GRAFANA_DOMAIN:-web-dev1-grafana.vucongtuanduong.dpdns.org}"

# Helm --set treats commas and backslashes as syntax; escape them once.
ADMIN_PASSWORD_ESCAPED="${GRAFANA_ADMIN_PASSWORD//\\/\\\\}"
ADMIN_PASSWORD_ESCAPED="${ADMIN_PASSWORD_ESCAPED//,/\\,}"

echo "========================================"
echo " Observability Stack Installer (Lite)"
echo " Namespace: observability"
echo " Components: Prometheus + Grafana + Tempo"
echo "========================================"

# ---- Step 0: preflight leftovers ----
echo ""
echo "[0/5] Checking for leftover observability releases..."
if kubectl get namespace observability >/dev/null 2>&1; then
  leftovers="$(helm list -n observability -q 2>/dev/null | grep -vxE 'monitoring|tempo' || true)"
  if [[ -n "$leftovers" ]]; then
    echo "[WARN] Other Helm releases still exist in observability and keep using RAM:"
    echo "$leftovers" | sed 's/^/  - /'
    echo "       Remove them before installing: helm uninstall <release> -n observability"
  fi
fi

# ---- Step 1: Verify Helm ----
echo ""
echo "[1/5] Checking Helm CLI..."
if ! command -v helm >/dev/null 2>&1; then
  echo "[ERROR] helm not found in PATH. Install Helm 3.16+ first."
  exit 1
fi
helm version --short

# Charts are pulled straight from GHCR as OCI artifacts instead of via
# `helm repo add`. The classic path resolves to
# github.com/<org>/helm-charts/releases/download/... whose CDN intermittently
# answers 504 Gateway Timeout (seen 2026-11-08) and aborts the whole install.
# GHCR is a separate backend and also removes the repo add/update round-trip.
#
# Retry the download, not the install: a failed fetch never creates a Helm
# release, whereas retrying a half-finished release fails with
# "another operation in progress" and leaves it pending. 3 attempts, 10s/20s.
CHARTS_TMP="$(mktemp -d)"
trap 'rm -rf "$CHARTS_TMP"' EXIT

helm_pull() {
  local url="$1" version="$2" attempt
  for attempt in 1 2 3; do
    if helm pull "$url" --version "$version" -d "$CHARTS_TMP"; then
      return 0
    fi
    echo "[WARN] helm pull ${url}:${version} failed (attempt ${attempt}/3)"
    [[ "$attempt" -lt 3 ]] && sleep $(( attempt * 10 ))
  done
  return 1
}

# ---- Step 2: Create namespace ----
echo ""
echo "[2/5] Creating namespace..."
kubectl create namespace observability 2>/dev/null || true

# ---- Step 3: Install Tempo (trace storage) ----
echo ""
echo "[3/5] Installing Tempo (distributed tracing storage)..."
if ! helm_pull oci://ghcr.io/grafana-community/helm-charts/tempo 2.4.0; then
  echo "[ERROR] Could not download the Tempo chart from GHCR after 3 attempts."
  exit 1
fi
helm upgrade --install tempo "$CHARTS_TMP/tempo-2.4.0.tgz" \
  --namespace observability \
  -f "$CHARTS_DIR/tempo-values.yaml" \
  --wait --timeout 10m

# ---- Step 4: Install kube-prometheus-stack (Prometheus + Grafana) ----
echo ""
echo "[4/5] Installing Prometheus + Grafana (kube-prometheus-stack)..."
if ! helm_pull oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack 92.11.0; then
  echo "[ERROR] Could not download the kube-prometheus-stack chart from GHCR after 3 attempts."
  exit 1
fi
helm upgrade --install monitoring "$CHARTS_TMP/kube-prometheus-stack-92.11.0.tgz" \
  --namespace observability \
  -f "$CHARTS_DIR/kube-prometheus-stack-values.yaml" \
  --set-string "grafana.adminPassword=${ADMIN_PASSWORD_ESCAPED}" \
  --wait --timeout 10m

# ---- Step 5: Apply ingress ----
echo ""
echo "[5/5] Applying ingress..."
kubectl apply -f "$MANIFESTS_DIR/ingress/grafana.yaml"

# ---- Tempo HTTP port verify (TEMPORARILY DISABLED) ----
# kubectl exec cat /conf/tempo.yaml fails because the Tempo container image
# does not include the `cat` binary, causing false "UNKNOWN" errors even when
# Tempo is correctly listening on port 3200. Verify manually instead:
#   kubectl logs -n observability tempo-0 --tail=50 | grep "listening on addresses"
#   → expect: http=[::]:3200
echo ""
echo "[verify] Tempo HTTP port... (SKIPPED - verify manually via kubectl logs)"

# The Lite stack must contain zero DaemonSets and no kube-state-metrics pod.
# Chart 72.x gates those subcharts with camelCase keys (nodeExporter.enabled /
# kubeStateMetrics.enabled); with the old kebab-case keys the values file looks
# right while both workloads still deploy, which is exactly how this box ended
# up OOM-restarting pods on an 8 GB node. Warn only: during an upgrade the old
# pods are still terminating, so a hard failure here would be a false alarm.
echo ""
echo "[verify] Lite stack composition..."
STRAY="$(kubectl -n observability get pods -o name 2>/dev/null \
  | grep -E 'node-exporter|kube-state-metrics' || true)"
if [[ -n "$STRAY" ]]; then
  echo "[WARN] node-exporter / kube-state-metrics pods should not be part of the Lite stack:"
  echo "$STRAY" | sed 's/^/  - /'
  echo "       If they persist, the release values are stale: check the gating keys"
  echo "       nodeExporter.enabled / kubeStateMetrics.enabled in charts/."
fi

echo ""
echo "========================================"
echo " Observability Stack (Lite) deployed!"
echo ""
echo " Grafana:    https://${GRAFANA_DOMAIN} (user: admin; password from .env.observability)"
echo " Prometheus: monitoring-kube-prometheus-prometheus.observability.svc.cluster.local:9090"
echo " Tempo:      tempo.observability.svc.cluster.local:3200 (query), :4318 (OTLP HTTP)"
echo "========================================"
echo " Pods:"
kubectl get pods -n observability
echo "========================================"
