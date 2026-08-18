#!/usr/bin/env bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  Web Grading System - Status${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# Check k3s
echo -e "${YELLOW}🔧 k3s Status:${NC}"
if sudo systemctl is-active --quiet k3s; then
    echo -e "  ${GREEN}✓ Running${NC}"
    kubectl get nodes
else
    echo -e "  ${RED}✗ Not running${NC}"
    echo "  Run: bash start.sh"
    exit 1
fi

echo ""
echo -e "${YELLOW}📦 Namespaces:${NC}"
kubectl get namespaces | grep -E "NAME|web-grading|argocd|observability" || echo "  No custom namespaces found"

echo ""
echo -e "${YELLOW}🚀 ArgoCD Applications:${NC}"
if kubectl get namespace argocd &>/dev/null; then
    kubectl get applications -n argocd 2>/dev/null || echo "  No applications found"
else
    echo -e "  ${RED}ArgoCD not installed${NC}"
fi

echo ""
echo -e "${YELLOW}🎯 Services in web-grading:${NC}"
if kubectl get namespace web-grading &>/dev/null; then
    echo ""
    echo "  Deployments:"
    kubectl get deployments -n web-grading 2>/dev/null || echo "    None"
    
    echo ""
    echo "  Pods:"
    kubectl get pods -n web-grading 2>/dev/null || echo "    None"
    
    echo ""
    echo "  Services:"
    kubectl get svc -n web-grading 2>/dev/null || echo "    None"
else
    echo -e "  ${RED}Namespace web-grading not found${NC}"
fi

echo ""
echo -e "${YELLOW}📊 Observability:${NC}"
if kubectl get namespace observability &>/dev/null; then
    kubectl get pods -n observability 2>/dev/null | head -10 || echo "  No pods"
else
    echo -e "  ${RED}Observability not installed${NC}"
fi

echo ""
echo -e "${YELLOW}🌐 Cloudflare Tunnel:${NC}"
if docker ps | grep -q cloudflared; then
    echo -e "  ${GREEN}✓ Running${NC}"
    docker ps | grep cloudflared
else
    echo -e "  ${RED}✗ Not running${NC}"
fi

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  Quick Links${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "${YELLOW}📊 Management:${NC}"
echo "  ArgoCD:     https://web-dev1-argocd.vucongtuanduong.dpdns.org"
echo "  Grafana:    https://web-dev1-grafana.vucongtuanduong.dpdns.org"
echo "  RustFS:     https://web-dev1-rustfs.vucongtuanduong.dpdns.org"
echo "  RustFS API: https://web-dev1-rustfs-api.vucongtuanduong.dpdns.org"
echo ""
echo -e "${YELLOW}🚀 Services:${NC}"
echo "  API Gateway:   https://web-dev1-api.vucongtuanduong.dpdns.org"
echo "  Submission:    https://web-dev1-submission.vucongtuanduong.dpdns.org"
echo ""
echo -e "${YELLOW}💡 Commands:${NC}"
echo "  Watch pods:        kubectl get pods -n web-grading -w"
echo "  Check logs:        kubectl logs -f <pod> -n web-grading"
echo "  Restart service:   kubectl rollout restart deployment/<service> -n web-grading"
echo "  Sync ArgoCD:       argocd app sync <app-name>"
echo ""
