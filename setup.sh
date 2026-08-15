#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load .env nếu có (cho GATEWAY_PORT, etc.)
if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -o allexport
  source "${SCRIPT_DIR}/.env"
  set +o allexport
fi

GATEWAY_PORT="${1:-${GATEWAY_PORT:-31242}}"

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  Web Grading System - Full Setup (Mono-Repo)${NC}"
echo -e "${BLUE}============================================================${NC}"
echo -e "  GATEWAY_PORT=${GATEWAY_PORT}"
echo ""

# Function to print step
print_step() {
    echo -e "\n${GREEN}=== $1 ===${NC}"
}

# Function to print success
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Function to print error
print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_step "1. Check / start k3s"
if kubectl get nodes &>/dev/null; then
  print_success "k3s is running"
else
  echo "  Starting k3s..."
  sudo systemctl start k3s 2>/dev/null || true
  sleep 5
  kubectl wait --for=condition=Ready nodes --all --timeout=60s
  print_success "k3s started"
fi

print_step "2. Create namespace + DB secret"
bash "$SCRIPT_DIR/deploy/setup-namespace.sh"
print_success "Namespace and secrets ready"

print_step "3. Deploy RustFS (Object Storage)"
bash "$SCRIPT_DIR/deploy/install-rustfs.sh"
print_success "RustFS deployed"

print_step "4. Create Ingress resources"
bash "$SCRIPT_DIR/deploy/install-ingress.sh"
print_success "Ingress configured"

print_step "5. Install ArgoCD + deploy applications"
bash "$SCRIPT_DIR/deploy/install-argocd.sh"
print_success "ArgoCD installed and applications deployed"

print_step "6. Install Observability Stack"
echo "  (Grafana + Loki + Mimir + Tempo + Alloy)"
bash "$SCRIPT_DIR/deploy/observability/install.sh"
print_success "Observability stack installed"

print_step "7. Setup Cloudflare Tunnel"
bash "$SCRIPT_DIR/deploy/cloudflared/setup-tunnel.sh" \
  "vucongtuanduong.dpdns.org" \
  "web-dev1-web-grading" \
  "${GATEWAY_PORT}" \
  || echo "  Tunnel may already exist, skipping"
docker compose -f "$SCRIPT_DIR/deploy/cloudflared/docker-compose.yml" up -d
print_success "Cloudflare Tunnel running"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  SETUP COMPLETE!${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "${YELLOW}📊 Management Interfaces:${NC}"
echo "  ArgoCD:     https://web-dev1-argocd.vucongtuanduong.dpdns.org"
echo "  Grafana:    https://web-dev1-grafana.vucongtuanduong.dpdns.org"
echo "  RustFS:     https://web-dev1-rustfs.vucongtuanduong.dpdns.org"
echo ""
echo -e "${YELLOW}🚀 Microservices:${NC}"
echo "  API Gateway:      https://web-dev1-api.vucongtuanduong.dpdns.org"
echo "  Submission:       https://web-dev1-submission.vucongtuanduong.dpdns.org"
echo "  Executor:         https://web-dev1-executor.vucongtuanduong.dpdns.org"
echo "  Assignment:       https://web-dev1-assignment.vucongtuanduong.dpdns.org"
echo "  Result:           https://web-dev1-result.vucongtuanduong.dpdns.org"
echo "  Grading:          https://web-dev1-grading.vucongtuanduong.dpdns.org"
echo "  Notification:     https://web-dev1-notification.vucongtuanduong.dpdns.org"
echo "  Keycloak:         https://web-dev1-keycloak.vucongtuanduong.dpdns.org"
echo ""
echo -e "${YELLOW}💡 Quick Commands:${NC}"
echo "  Check status:     kubectl get pods -n web-grading"
echo "  Check ArgoCD:     kubectl get applications -n argocd"
echo "  View logs:        kubectl logs -f <pod-name> -n web-grading"
echo "  Restart service:  kubectl rollout restart deployment/<service> -n web-grading"
echo ""
echo -e "${YELLOW}🔄 Lifecycle:${NC}"
echo "  Start:   bash start.sh   (after reboot)"
echo "  Stop:    bash stop.sh    (stop services)"
echo "  Clean:   bash clean.sh   (delete everything)"
echo ""
print_success "System is ready!"
