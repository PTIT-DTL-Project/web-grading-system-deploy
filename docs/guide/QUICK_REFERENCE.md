# Quick Reference Guide

Các commands thường dùng cho Web Grading System Mono-Repo.

## 🚀 Setup

### Initial Setup
```bash
# Run setup script
./setup-mono-repo.sh

# Generate ArgoCD applications
cd deploy/argocd-apps
./generate-argocd-apps.sh

# Apply to cluster
kubectl apply -f generated/
```

## 📝 Source Repo Commands

### Build & Test Locally
```bash
cd web-grading-system-services

# Build core library
cd core && mvn clean install && cd ..

# Build specific service
cd submission-service
mvn clean package
docker build -t submission-service:dev .
```

### Check What Changed
```bash
# See changed files
git diff main --name-only

# See which services affected
git diff main --name-only | grep -E '^[^/]+/' | cut -d/ -f1 | sort -u
```

### Create Feature Branch
```bash
git checkout -b feat/my-feature
# Make changes...
git add .
git commit -m "feat(service-name): description"
git push origin feat/my-feature
```

## 🎛️ Config Repo Commands

### Generate New Chart
```bash
cd web-grading-system-config
./generate-charts.sh
```

### Test Helm Chart
```bash
# Lint chart
helm lint submission-service/

# Dry-run render
helm template test submission-service/ -f submission-service/values-stg.yaml

# Install locally
helm install submission-service submission-service/ -f submission-service/values-stg.yaml -n web-grading
```

### Update Service Version
```bash
cd submission-service
# Edit values-stg.yaml
vim values-stg.yaml
# Change: tag: "v1.2.0" → tag: "v1.3.0"

git add .
git commit -m "Update submission-service to v1.3.0"
git push
```

## 🔄 ArgoCD Commands

### Check Applications
```bash
# List all applications
kubectl get applications -n argocd

# Check specific application
kubectl get application grading-submission-service -n argocd -o yaml

# Using argocd CLI
argocd app list
argocd app get grading-submission-service
```

### Sync Manually
```bash
# Sync specific app
argocd app sync grading-submission-service

# Sync all apps
argocd app sync -l app.kubernetes.io/instance=grading
```

### Rollback
```bash
# View history
argocd app history grading-submission-service

# Rollback to specific revision
argocd app rollback grading-submission-service <revision-id>
```

## 🐳 Docker Commands

### Check Images
```bash
# List images on DockerHub
docker search vucongtuanduong/web-grading-system

# Pull specific version
docker pull vucongtuanduong/web-grading-system-submission-service:v1.2.0
```

### Build Locally
```bash
cd web-grading-system-services/submission-service
docker build -t submission-service:test .
docker run -p 8082:8082 submission-service:test
```

## ☸️ Kubernetes Commands

### Check Pods
```bash
# List all pods
kubectl get pods -n web-grading

# Check specific service
kubectl get pods -n web-grading -l app=submission-service

# Watch pods
kubectl get pods -n web-grading -w
```

### Check Logs
```bash
# Tail logs
kubectl logs -f <pod-name> -n web-grading

# Logs from all pods of a service
kubectl logs -n web-grading -l app=submission-service --tail=100

# Previous logs (after crash)
kubectl logs <pod-name> -n web-grading --previous
```

### Debug Pod
```bash
# Describe pod
kubectl describe pod <pod-name> -n web-grading

# Get pod events
kubectl get events -n web-grading --sort-by='.lastTimestamp'

# Exec into pod
kubectl exec -it <pod-name> -n web-grading -- /bin/sh
```

### Check Services
```bash
# List services
kubectl get svc -n web-grading

# Check endpoints
kubectl get endpoints -n web-grading

# Port forward for testing
kubectl port-forward svc/submission-service 8082:8082 -n web-grading
```

## 🔍 Monitoring Commands

### Prometheus
```bash
# Port forward Prometheus
kubectl port-forward -n monitoring svc/prometheus-server 9090:80

# Access: http://localhost:9090
```

### Grafana
```bash
# Port forward Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80

# Get admin password
kubectl get secret -n monitoring grafana -o jsonpath="{.data.admin-password}" | base64 -d
```

## 🔧 Troubleshooting Commands

### Check Workflow Status
```bash
# View GitHub Actions runs
gh run list --repo PTIT-DTL-Project/web-grading-system-services

# View specific run
gh run view <run-id> --log

# Re-run failed workflow
gh run rerun <run-id>
```

### Check ArgoCD Sync Issues
```bash
# Get application status
argocd app get grading-submission-service --show-operation

# Check sync errors
kubectl get application grading-submission-service -n argocd -o jsonpath='{.status.conditions}'

# Force refresh
argocd app get grading-submission-service --refresh
```

### Check Resource Usage
```bash
# Pod resource usage
kubectl top pods -n web-grading

# Node resource usage
kubectl top nodes

# Describe node
kubectl describe node <node-name>
```

### Check Image Pull Issues
```bash
# Check image pull secrets
kubectl get secrets -n web-grading

# Describe pod to see image pull errors
kubectl describe pod <pod-name> -n web-grading | grep -A 5 "Events:"
```

## 📊 Useful Queries

### Check Service Versions
```bash
# Get all deployed versions
kubectl get pods -n web-grading -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

### Check Health
```bash
# Health check all services
for service in submission-service executor-service api-gateway result-service assignment-service; do
  echo "=== $service ==="
  kubectl exec -n web-grading $(kubectl get pod -n web-grading -l app=$service -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:8080/actuator/health || echo "Failed"
done
```

## 🔑 GitHub Commands

### Manage Secrets
```bash
# List secrets
gh secret list --repo PTIT-DTL-Project/web-grading-system-services

# Set secret
gh secret set DOCKERHUB_TOKEN --repo PTIT-DTL-Project/web-grading-system-services

# Delete secret
gh secret delete SECRET_NAME --repo PTIT-DTL-Project/web-grading-system-services
```

## 📦 Cleanup Commands

### Remove Old Pods
```bash
# Delete failed pods
kubectl delete pods -n web-grading --field-selector status.phase=Failed

# Restart deployment
kubectl rollout restart deployment/submission-service -n web-grading
```

### Clean Docker Images
```bash
# Remove unused images
docker image prune -a

# Remove specific image
docker rmi vucongtuanduong/web-grading-system-submission-service:v1.0.0
```

## 🔄 Update Flow

### Complete Update Flow
```bash
# 1. Make code changes
cd web-grading-system-services
git checkout -b feat/new-feature
vim submission-service/src/...

# 2. Commit and push
git add .
git commit -m "feat(submission-service): add feature"
git push origin feat/new-feature

# 3. Create PR and merge

# 4. Verify build
gh run watch

# 5. Check config repo updated
cd ../web-grading-system-config
git pull
cat submission-service/values-stg.yaml | grep tag

# 6. Verify ArgoCD synced
argocd app get grading-submission-service

# 7. Check pods updated
kubectl get pods -n web-grading -l app=submission-service
```
