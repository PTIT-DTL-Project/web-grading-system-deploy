#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NAMESPACE="web-grading"
SECRET_NAME="app-config"
SECRET_KEY="APP_LOG_LEVEL"
ENV_NAME="LOGGING_LEVEL_VN_EDU_PTIT_WEB_GRADING_SYSTEM"
# Deployment list derived from the ArgoCD service registry so a newly onboarded
# service is never forgotten here again (Review: 2026-10-15, ai-assistant-service
# onboarding; mirrors the dynamic read in dev-scale.sh).
mapfile -t SERVICES < <(grep -vE '^[[:space:]]*(#|$)' "$SCRIPT_DIR/deploy/argocd-apps/services.env" | sed 's|^|grading-|')

# Level: $1 wins, else LOG_LEVEL from .env, else INFO
LEVEL="${1:-}"
if [[ -z "$LEVEL" && -f .env ]]; then
    LEVEL=$(grep -E '^APP_LOG_LEVEL=' .env | cut -d= -f2 | tr -d '[:space:]')
fi
LEVEL="${LEVEL:-INFO}"

case "$LEVEL" in
    DEBUG|INFO|WARN|ERROR) ;;
    *)
        echo -e "${RED}Invalid log level: '$LEVEL' (use DEBUG, INFO, WARN or ERROR)${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}Setting all services to log level: ${YELLOW}$LEVEL${NC}"
kubectl create secret generic "$SECRET_NAME" \
    --namespace "$NAMESPACE" \
    --from-literal="$SECRET_KEY=$LEVEL" \
    --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Secret $SECRET_NAME updated${NC}"

for svc in "${SERVICES[@]}"; do
    if kubectl get deployment "$svc" -n "$NAMESPACE" &>/dev/null; then
        kubectl rollout restart deployment/"$svc" -n "$NAMESPACE"
    else
        echo -e "${YELLOW}⚠ deployment/$svc not found, skipping${NC}"
    fi
done

echo ""
echo -e "${YELLOW}Rolling out...${NC}"
FAILED=0
for svc in "${SERVICES[@]}"; do
    if kubectl get deployment "$svc" -n "$NAMESPACE" &>/dev/null; then
        if kubectl rollout status deployment/"$svc" -n "$NAMESPACE" --timeout=180s; then
            echo -e "${GREEN}✓ $svc rolled out at $LEVEL${NC}"
        else
            echo -e "${RED}✗ $svc rollout failed — check: kubectl logs deploy/$svc -n $NAMESPACE${NC}"
            FAILED=1
        fi
    fi
done

if [[ $FAILED -eq 0 ]]; then
    echo -e "\n${GREEN}All services running with log level: $LEVEL${NC}"
else
    exit 1
fi