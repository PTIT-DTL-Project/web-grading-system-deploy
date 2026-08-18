#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  Web Grading System - Start${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

echo -e "${YELLOW}➜ Starting k3s...${NC}"
sudo systemctl start k3s
kubectl wait --for=condition=Ready nodes --all --timeout=120s
echo -e "${GREEN}✓ k3s is running${NC}"

echo ""
echo -e "${YELLOW}➜ Starting Cloudflare Tunnel...${NC}"
docker compose -f "$SCRIPT_DIR/deploy/cloudflared/docker-compose.yml" up -d --no-build
echo -e "${GREEN}✓ Cloudflare Tunnel is running${NC}"

echo ""
echo -e "${YELLOW}➜ Checking cluster status...${NC}"
echo "  Namespaces:"
kubectl get namespaces | grep -E "web-grading|argocd|observability" || echo "  (no namespaces found)"

echo ""
echo "  ArgoCD Applications:"
kubectl get applications -n argocd 2>/dev/null | head -7 || echo "  (ArgoCD not ready yet)"

echo ""
echo "  Pods in web-grading:"
kubectl get pods -n web-grading 2>/dev/null || echo "  (namespace not found - run setup.sh first)"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  System Started!${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "${YELLOW}📊 Management Interfaces:${NC}"
echo "  ArgoCD:     https://web-dev2-argocd.vucongtuanduong.dpdns.org"
echo "  Grafana:    https://web-dev2-grafana.vucongtuanduong.dpdns.org"
echo "  RustFS:     https://web-dev2-rustfs.vucongtuanduong.dpdns.org"
echo "  RustFS API: https://web-dev2-rustfs-api.vucongtuanduong.dpdns.org"
echo ""
echo -e "${YELLOW}🚀 Microservices:${NC}"
echo "  API Gateway:      https://web-dev2-api.vucongtuanduong.dpdns.org"
echo "  Submission:       https://web-dev2-submission.vucongtuanduong.dpdns.org"
echo "  Executor:         https://web-dev2-executor.vucongtuanduong.dpdns.org"
echo ""
echo -e "${YELLOW}💡 Useful commands:${NC}"
echo "  Watch pods:       kubectl get pods -n web-grading -w"
echo "  Check ArgoCD:     kubectl get applications -n argocd"
echo "  View logs:        kubectl logs -f <pod-name> -n web-grading"
echo "  Stop system:      bash stop.sh"
echo ""
