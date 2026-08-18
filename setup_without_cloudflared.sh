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
echo -e "${BLUE}  No Cloudflare Tunnel${NC}"
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

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  SETUP COMPLETE!${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "${YELLOW}🌐 Local Access (no Cloudflare tunnel):${NC}"
LB_IP=$(kubectl get svc traefik -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ -n "${LB_IP}" ]; then
  echo "  Traefik LB IP: ${LB_IP}"
  echo "  Example:       curl -k -H 'Host: web-dev1-rustfs.vucongtuanduong.dpdns.org' https://${LB_IP}"
  echo "  Tip:           add '${LB_IP}  web-dev1-api.vucongtuanduong.dpdns.org web-dev1-rustfs.vucongtuanduong.dpdns.org ...' to /etc/hosts"
else
  echo "  Traefik LB IP not found; check: kubectl get svc traefik -n kube-system"
fi
echo ""
echo -e "${YELLOW}🚀 Services (via kubectl port-forward):${NC}"
echo "  API Gateway:  kubectl port-forward -n web-grading svc/gateway ${GATEWAY_PORT}:8080"
echo "  RustFS API:   kubectl port-forward -n web-grading svc/rustfs 9000:9000"
echo "  RustFS Web:   kubectl port-forward -n web-grading svc/rustfs 9001:9001"
echo "  ArgoCD:       kubectl port-forward -n argocd svc/argocd-server 8080:80"
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