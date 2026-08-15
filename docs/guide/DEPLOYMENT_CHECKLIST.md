# Deployment Checklist

Checklist để đảm bảo setup mono-repo thành công.

## 📋 Pre-Deployment

### Prerequisites
- [ ] Git installed
- [ ] kubectl installed and configured
- [ ] ArgoCD installed on cluster
- [ ] GitHub account with organization access
- [ ] DockerHub account
- [ ] kubectl can access your cluster

### Verify Files
- [ ] README.md exists
- [ ] MIGRATION_GUIDE.md exists
- [ ] QUICK_REFERENCE.md exists
- [ ] SETUP_SUMMARY.md exists
- [ ] setup-mono-repo.sh is executable
- [ ] src-services/ directory with all services
- [ ] config-services/ directory with all charts
- [ ] deploy/argocd-apps/ directory with templates

## 🚀 Setup Phase

### Step 1: Run Setup Script
- [ ] Run `./setup-mono-repo.sh`
- [ ] Source repo created locally
- [ ] Config repo created locally
- [ ] Initial commits made
- [ ] No errors in output

### Step 2: Create GitHub Repositories
- [ ] Created `web-grading-system-services` on GitHub
- [ ] Created `web-grading-system-config` on GitHub
- [ ] Both repos are empty (no README yet)
- [ ] Correct organization/user

### Step 3: Push Repositories
- [ ] Pushed source repo to GitHub
- [ ] Pushed config repo to GitHub
- [ ] Both repos show files on GitHub
- [ ] main branch is default

### Step 4: Configure GitHub Secrets

**Source Repo Secrets:**
- [ ] DOCKERHUB_USERNAME set
- [ ] DOCKERHUB_TOKEN set (not password!)
- [ ] CONFIG_REPO_TOKEN set (GitHub PAT)

**Verify Token Permissions:**
- [ ] CONFIG_REPO_TOKEN has `repo` scope
- [ ] CONFIG_REPO_TOKEN can write to config repo
- [ ] DOCKERHUB_TOKEN is access token (not password)

### Step 5: Generate & Deploy ArgoCD Apps
- [ ] Run `./deploy/argocd-apps/generate-argocd-apps.sh`
- [ ] 6 YAML files created in generated/
- [ ] Run `kubectl apply -f deploy/argocd-apps/generated/`
- [ ] No errors from kubectl

## ✅ Verification Phase

### Verify ArgoCD Applications
```bash
kubectl get applications -n argocd
```
- [ ] grading-submission-service exists
- [ ] grading-executor-service exists
- [ ] grading-api-gateway exists
- [ ] grading-result-service exists
- [ ] grading-assignment-service exists
- [ ] All apps show "Healthy" status
- [ ] All apps show "Synced" status

### Verify GitHub Actions
```bash
gh run list --repo PTIT-DTL-Project/web-grading-system-services
```
- [ ] Workflow file detected
- [ ] No syntax errors
- [ ] Workflow ready to run

### Test CI/CD Pipeline

**Make a test change:**
```bash
cd web-grading-system-services
echo "# Test" >> submission-service/README.md
git add .
git commit -m "test: trigger CI/CD"
git push origin main
```

**Verify:**
- [ ] GitHub Actions workflow triggered
- [ ] Only submission-service detected
- [ ] Build started
- [ ] Docker image built
- [ ] Image pushed to DockerHub
- [ ] Config repo updated
- [ ] ArgoCD synced
- [ ] Pod restarted in cluster

### Verify Services Running

```bash
kubectl get pods -n web-grading
```
- [ ] All services have running pods
- [ ] No CrashLoopBackOff
- [ ] No ImagePullBackOff
- [ ] Health checks passing

### Verify Networking

```bash
kubectl get svc -n web-grading
kubectl get ingress -n web-grading
```
- [ ] All services have ClusterIP
- [ ] Services are accessible within cluster
- [ ] Ingress configured (if applicable)

## 🔍 Post-Deployment

### Documentation Review
- [ ] Team has access to README.md
- [ ] Team reviewed MIGRATION_GUIDE.md
- [ ] Team has QUICK_REFERENCE.md bookmarked
- [ ] Development workflow documented

### Monitoring Setup
- [ ] Prometheus collecting metrics
- [ ] Grafana dashboards configured
- [ ] Alerts configured
- [ ] Log aggregation working

### Backup & Recovery
- [ ] Backup strategy documented
- [ ] Rollback procedure tested
- [ ] Disaster recovery plan in place

### Security Review
- [ ] Secrets properly stored in Kubernetes
- [ ] No secrets in git repositories
- [ ] GitHub tokens have minimal required permissions
- [ ] Image pull secrets configured (if private)

## 📝 Ongoing Operations

### Daily Checks
- [ ] Monitor GitHub Actions runs
- [ ] Check ArgoCD sync status
- [ ] Review pod health
- [ ] Check resource usage

### Weekly Checks
- [ ] Review image versions
- [ ] Clean up old images
- [ ] Check for security updates
- [ ] Review logs for errors

### Monthly Checks
- [ ] Review and update documentation
- [ ] Audit access permissions
- [ ] Review resource limits
- [ ] Plan for scaling

## 🆘 Troubleshooting Checklist

### If Workflow Fails
- [ ] Check GitHub Actions logs
- [ ] Verify secrets are set correctly
- [ ] Check Docker build logs
- [ ] Verify Maven build succeeds

### If ArgoCD Won't Sync
- [ ] Verify repo URL is correct
- [ ] Check ArgoCD has repo access
- [ ] Validate Helm chart: `helm lint <chart>/`
- [ ] Check ArgoCD application logs

### If Pods Won't Start
- [ ] Check image exists on DockerHub
- [ ] Verify image tag is correct
- [ ] Check pod events: `kubectl describe pod`
- [ ] Check pod logs: `kubectl logs`
- [ ] Verify secrets exist

### If Service Not Accessible
- [ ] Check service exists
- [ ] Verify endpoints: `kubectl get endpoints`
- [ ] Check ingress configuration
- [ ] Test from within cluster first

## 🎯 Success Criteria

All items below should be true:

- [ ] ✅ 2 GitHub repos created and pushed
- [ ] ✅ GitHub secrets configured
- [ ] ✅ GitHub Actions workflow runs successfully
- [ ] ✅ Docker images built and pushed
- [ ] ✅ 6 ArgoCD Applications deployed
- [ ] ✅ All applications show Healthy & Synced
- [ ] ✅ All pods running without errors
- [ ] ✅ Services accessible
- [ ] ✅ Test change triggers complete CI/CD flow
- [ ] ✅ Team trained on new workflow
- [ ] ✅ Documentation complete and accessible

## 📞 Support Contacts

- **GitHub Issues:** [web-grading-system-deploy/issues](https://github.com/PTIT-DTL-Project/web-grading-system-deploy/issues)
- **Documentation:** See MIGRATION_GUIDE.md
- **Quick Commands:** See QUICK_REFERENCE.md

---

**Date Completed:** _______________

**Verified By:** _______________

**Notes:**
_______________________________________
_______________________________________
_______________________________________
