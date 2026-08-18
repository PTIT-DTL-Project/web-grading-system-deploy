#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARGOCD_APPS_DIR="$SCRIPT_DIR/argocd-apps"

echo "=== Installing ArgoCD ==="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "=== Waiting for ArgoCD server ==="
kubectl wait --namespace argocd --for=condition=Ready pod --all --timeout=300s || true

# Allow HTTP behind reverse proxy
kubectl patch deployment argocd-server -n argocd --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'

# ArgoCD Ingress
kubectl apply -f "$SCRIPT_DIR/argocd-ingress.yaml"
kubectl patch svc -n argocd argocd-server --patch '{"spec": {"type": "ClusterIP"}}'

echo ""
echo "=== Generating ArgoCD Applications ==="
cd "$ARGOCD_APPS_DIR"
bash generate-argocd-apps.sh

echo ""
echo "=== Deploying ArgoCD Applications ==="
kubectl apply -f "$ARGOCD_APPS_DIR/generated/"

ARGO_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "not found")
echo ""
echo "=== ArgoCD ready ==="
echo "  URL:  https://web-dev2-argocd.vucongtuanduong.dpdns.org"
echo "  User: admin"
echo "  Pass: ${ARGO_PASSWORD}"
echo ""
echo "=== ArgoCD Applications deployed ==="
kubectl get applications -n argocd
