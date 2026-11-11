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

# --- RAM tuning for the 8 GB node -------------------------------------------
# The upstream install.yaml ships no requests/limits, so every ArgoCD pod is
# unbounded: on a tight node the kernel OOM killer picks whichever has the
# largest RSS (usually repo-server) and the whole sync stops until it restarts.
# These ceilings also give kubelet a basis for eviction ordering.
# Both workload kinds are tried because ArgoCD moved the application
# controller from a StatefulSet to a Deployment across 2.x -> 3.x; `|| true`
# keeps the script working on either version.
echo ""
echo "=== Applying ArgoCD resource limits (8 GB node) ==="
kubectl -n argocd set resources statefulset/argocd-application-controller \
  --requests=cpu=100m,memory=192Mi --limits=cpu=500m,memory=512Mi 2>/dev/null || true
kubectl -n argocd set resources deployment/argocd-application-controller \
  --requests=cpu=100m,memory=192Mi --limits=cpu=500m,memory=512Mi 2>/dev/null || true
kubectl -n argocd set resources deployment/argocd-repo-server \
  --requests=cpu=100m,memory=128Mi --limits=cpu=500m,memory=384Mi 2>/dev/null || true
kubectl -n argocd set resources deployment/argocd-server \
  --requests=cpu=100m,memory=128Mi --limits=cpu=500m,memory=384Mi 2>/dev/null || true
kubectl -n argocd set resources deployment/argocd-redis \
  --requests=cpu=50m,memory=64Mi --limits=cpu=200m,memory=192Mi 2>/dev/null || true
kubectl -n argocd set resources deployment/argocd-dex-server \
  --requests=cpu=50m,memory=64Mi --limits=cpu=200m,memory=192Mi 2>/dev/null || true

# Notifications and ApplicationSet controllers are dead weight here: applications
# are static manifests rendered by generate-argocd-apps.sh (no ApplicationSet
# generator) and no notification templates/subscriptions exist. Each idles at
# ~60-80 MiB. Scaling to zero (not deleting) is what survives an ArgoCD
# re-install, which recreates both from install.yaml anyway.
kubectl -n argocd scale deployment/argocd-notifications-controller --replicas=0 2>/dev/null || true
kubectl -n argocd scale deployment/argocd-applicationset-controller --replicas=0 2>/dev/null || true

ARGO_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "not found")
echo ""
echo "=== ArgoCD ready ==="
echo "  URL:  https://web-dev1-argocd.vucongtuanduong.dpdns.org"
echo "  User: admin"
echo "  Pass: ${ARGO_PASSWORD}"
echo ""
echo "=== ArgoCD Applications deployed ==="
kubectl get applications -n argocd
