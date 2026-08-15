#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${RED}============================================================${NC}"
echo -e "${RED}  Web Grading System - Clean${NC}"
echo -e "${RED}============================================================${NC}"
echo ""
echo -e "${YELLOW}⚠️  WARNING: This will delete:${NC}"
echo "  • ArgoCD namespace and all applications"
echo "  • Observability namespace (Grafana, Prometheus, etc.)"
echo "  • web-grading namespace and all services"
echo "  • All container images from k3s"
echo ""
echo -e "${RED}  Data will be lost! PVCs need manual deletion.${NC}"
echo ""

read -p "Are you sure? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo -e "${YELLOW}➜ Cleaning ArgoCD...${NC}"
kubectl delete namespace argocd --wait --ignore-not-found
echo -e "${GREEN}✓ ArgoCD cleaned${NC}"

echo ""
echo -e "${YELLOW}➜ Cleaning observability...${NC}"
kubectl delete namespace observability --wait --ignore-not-found
echo -e "${GREEN}✓ Observability cleaned${NC}"
echo -e "${YELLOW}  Note: PVCs are preserved. To delete manually:${NC}"
echo "    kubectl get pvc -A"
echo "    kubectl delete pvc <name> -n <namespace>"

echo ""
echo -e "${YELLOW}➜ Cleaning web-grading namespace...${NC}"
kubectl delete namespace web-grading --wait --ignore-not-found
echo -e "${GREEN}✓ web-grading cleaned${NC}"

echo ""
echo -e "${YELLOW}➜ Cleaning k3s container images...${NC}"
sudo k3s crictl rmi --all 2>/dev/null || true
echo -e "${GREEN}✓ Images cleaned${NC}"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  Cleanup Complete${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "${YELLOW}💡 To setup again:${NC}"
echo "  bash setup.sh"
echo ""
echo -e "${YELLOW}📝 Manual cleanup (if needed):${NC}"
echo "  # Delete PVCs"
echo "  kubectl get pvc -A"
echo "  kubectl delete pvc <name> -n <namespace>"
echo ""
echo "  # Delete PVs"
echo "  kubectl get pv"
echo "  kubectl delete pv <name>"
echo ""
