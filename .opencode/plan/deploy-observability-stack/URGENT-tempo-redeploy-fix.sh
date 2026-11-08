#!/bin/bash
# =============================================================================
# URGENT: Tempo Port 3200 Fix - Re-deploy Script
# =============================================================================
# Vấn đề: Tempo đang listen port 3100, Grafana expect port 3200 → timeout
# Evidence: kubectl exec tempo-0 -- cat /conf/tempo.yaml | grep http_listen_port
#           → http_listen_port: 3100 (SAI)
# Fix: Re-deploy Tempo với config đúng (port 3200)
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo " Tempo Port 3200 Fix - Re-deploy"
echo "========================================="

# Navigate to observability directory
cd "$(dirname "$0")/../.." || cd /home/duongvct/Documents/workspace/PTIT/web-grading-system-deploy/deploy/observability

# 1. Verify current state
echo ""
echo "[1/6] Verifying current Tempo config..."
CURRENT_PORT=$(kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml 2>/dev/null | grep -A1 "^server:" | grep http_listen_port | awk '{print $2}')
echo "Current HTTP port: ${CURRENT_PORT:-UNKNOWN}"

if [ "$CURRENT_PORT" = "3200" ]; then
  echo -e "${GREEN}[OK] Tempo already on port 3200!${NC}"
  echo "If Grafana still timeout, check connectivity:"
  echo "  kubectl exec -n observability deployment/monitoring-grafana -- wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready"
  exit 0
fi

if [ "$CURRENT_PORT" != "3100" ]; then
  echo -e "${RED}[WARN] Unexpected port: $CURRENT_PORT${NC}"
fi

# 2. Backup current values file
echo ""
echo "[2/6] Backing up tempo-values.yaml..."
if [ -f charts/tempo-values.yaml ]; then
  cp charts/tempo-values.yaml "charts/tempo-values.yaml.backup-$(date +%Y%m%d-%H%M%S)"
  echo -e "${GREEN}Backup created${NC}"
else
  echo -e "${RED}[ERROR] charts/tempo-values.yaml not found!${NC}"
  exit 1
fi

# 3. Verify fix is in values file
echo ""
echo "[3/6] Verifying fix in tempo-values.yaml..."
if grep -q "http_listen_port: 3200" charts/tempo-values.yaml; then
  echo -e "${GREEN}Fix present in values file${NC}"
else
  echo -e "${YELLOW}Fix NOT in values file, adding now...${NC}"
  
  # Check if server: section already exists
  if grep -q "^server:" charts/tempo-values.yaml; then
    echo -e "${RED}[ERROR] server: section exists but port is wrong. Manual edit required.${NC}"
    echo "Edit charts/tempo-values.yaml and change:"
    echo "  server:"
    echo "    http_listen_port: 3200  # <- change from 3100 to 3200"
    exit 1
  fi
  
  # Add fix if server section doesn't exist
  cat >> charts/tempo-values.yaml <<'EOF'

# Fix: HTTP server must listen port 3200 (not chart default 3100)
# Grafana datasource expects http://tempo.observability.svc.cluster.local:3200
# Review: 2026-11-08, port mismatch causing timeout.
server:
  http_listen_port: 3200
  grpc_listen_port: 9095
EOF
  echo -e "${GREEN}Fix added to values file${NC}"
fi

# 4. Check Helm availability
echo ""
echo "[4/6] Checking Helm..."
if ! command -v helm &> /dev/null; then
  echo -e "${RED}[ERROR] Helm not found in PATH${NC}"
  echo "Install Helm first: https://helm.sh/docs/intro/install/"
  echo ""
  echo "Quick install (Linux):"
  echo "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  exit 1
fi

HELM_VERSION=$(helm version --short 2>/dev/null || echo "unknown")
echo "Helm version: $HELM_VERSION"

# 5. Re-deploy Tempo
echo ""
echo "[5/6] Re-deploying Tempo with Helm..."
echo -e "${YELLOW}This will restart the Tempo pod (traces ingestion paused ~30s)${NC}"
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# Pull chart from OCI registry (with retry)
echo "Pulling Tempo chart from GHCR..."
CHARTS_TMP=$(mktemp -d)
trap 'rm -rf "$CHARTS_TMP"' EXIT

for attempt in 1 2 3; do
  if helm pull oci://ghcr.io/grafana/helm-charts/tempo --version 1.21.1 -d "$CHARTS_TMP" 2>&1; then
    echo -e "${GREEN}Chart pulled successfully${NC}"
    break
  else
    echo -e "${YELLOW}[WARN] helm pull failed (attempt $attempt/3)${NC}"
    if [ "$attempt" -lt 3 ]; then
      sleep $((attempt * 5))
    else
      echo -e "${RED}[ERROR] Failed to pull chart after 3 attempts${NC}"
      exit 1
    fi
  fi
done

# Upgrade Tempo release
echo "Upgrading Tempo release..."
helm upgrade --install tempo "$CHARTS_TMP/tempo-1.21.1.tgz" \
  --namespace observability \
  --values charts/tempo-values.yaml \
  --wait \
  --timeout 5m

echo -e "${GREEN}Tempo upgraded${NC}"

# 6. Verify fix applied
echo ""
echo "[6/6] Verifying fix applied..."
echo "Waiting for pod to be ready (max 120s)..."
if kubectl wait --for=condition=ready pod/tempo-0 -n observability --timeout=120s 2>&1; then
  echo -e "${GREEN}Pod ready${NC}"
else
  echo -e "${RED}[WARN] Pod not ready after 120s, checking anyway...${NC}"
fi

sleep 5  # Give Tempo a few seconds to fully start

echo ""
echo "Checking Tempo config in pod..."
NEW_PORT=$(kubectl exec -n observability tempo-0 -- cat /conf/tempo.yaml 2>/dev/null | grep -A1 "^server:" | grep http_listen_port | awk '{print $2}')
echo "New HTTP port: ${NEW_PORT:-UNKNOWN}"

if [ "$NEW_PORT" = "3200" ]; then
  echo -e "${GREEN}✓ Fix applied successfully!${NC}"
else
  echo -e "${RED}✗ Fix NOT applied. Port is still: $NEW_PORT${NC}"
  echo "Check pod logs:"
  echo "  kubectl logs -n observability tempo-0 --tail=50"
  exit 1
fi

echo ""
echo "Checking listening ports..."
# Use netstat as fallback (ss may not be in image)
if kubectl exec -n observability tempo-0 -- netstat -tlnp 2>/dev/null | grep -q ":3200"; then
  echo -e "${GREEN}✓ Port 3200 is listening${NC}"
elif kubectl exec -n observability tempo-0 -- netstat -tln 2>/dev/null | grep -q ":3200"; then
  echo -e "${GREEN}✓ Port 3200 is listening (process info unavailable)${NC}"
else
  echo -e "${RED}✗ Port 3200 NOT found in netstat${NC}"
  echo "Trying to check via logs..."
  kubectl logs -n observability tempo-0 --tail=30 | grep "listening on addresses"
fi

echo ""
echo "Testing connectivity from Grafana..."
if kubectl exec -n observability deployment/monitoring-grafana -- \
  wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready &>/dev/null; then
  echo -e "${GREEN}✓ Grafana can reach Tempo on port 3200!${NC}"
else
  EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 1 ]; then
    echo -e "${YELLOW}⚠ Connection reached but got non-200 response (may be 503 if not fully ready)${NC}"
  else
    echo -e "${RED}✗ Connection still timeout/failed${NC}"
    echo "Wait 30s for Tempo to fully initialize, then try:"
    echo "  kubectl exec -n observability deployment/monitoring-grafana -- wget -O- --timeout=5 http://tempo.observability.svc.cluster.local:3200/ready"
  fi
fi

echo ""
echo "========================================="
echo " Re-deploy Complete"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Open Grafana: https://web-dev1-grafana.vucongtuanduong.dpdns.org"
echo "2. Go to Explore → Tempo"
echo "3. Try a query - should NOT timeout anymore"
echo ""
echo "If still timeout after 1 minute:"
echo "  - Check Tempo logs: kubectl logs -n observability tempo-0 --tail=100"
echo "  - Check Service endpoints: kubectl get endpoints -n observability tempo"
echo "  - Manual connectivity test:"
echo "      kubectl exec -n observability deployment/monitoring-grafana -- wget -O- http://tempo:3200/ready"
