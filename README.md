# Web Grading System - Deploy & Orchestration

Central repository for deploying and orchestrating the Web Grading System using GitOps with ArgoCD.

## 🏗️ Architecture Overview

This system uses a **mono-repo architecture** for better management:

```
┌─────────────────────────────────────────────────────────┐
│  web-grading-system-services (Source Mono-Repo)        │
│  - All microservices source code                        │
│  - Smart CI/CD with change detection                    │
│  - Builds only affected services                        │
└─────────────────────────────────────────────────────────┘
                          ↓
                    Docker Images
                          ↓
┌─────────────────────────────────────────────────────────┐
│  web-grading-system-config (Config Mono-Repo)          │
│  - Helm charts for all services                         │
│  - Auto-updated by CI/CD pipeline                       │
└─────────────────────────────────────────────────────────┘
                          ↓
                    ArgoCD Sync
                          ↓
┌─────────────────────────────────────────────────────────┐
│  web-grading-system-deploy (This Repo)                 │
│  - ArgoCD Applications orchestration                    │
│  - Infrastructure setup scripts                         │
│  - Documentation & migration guides                     │
└─────────────────────────────────────────────────────────┘
                          ↓
                  Kubernetes Cluster
```

## 📦 Repository Structure

```
web-grading-system-deploy/
├── src-services/              # Template for source mono-repo
│   ├── .github/workflows/     # CI/CD workflows
│   ├── submission-service/
│   ├── executor-service/
│   ├── api-gateway/
│   ├── result-service/
│   ├── assignment-service/
│
├── config-services/           # Template for config mono-repo
│   ├── submission-service/    # Helm chart
│   ├── executor-service/
│   ├── api-gateway/
│   ├── result-service/
│   └── assignment-service/
│
├── deploy/                    # Deployment configurations
│   ├── argocd-apps/          # ArgoCD Application templates
│   ├── observability/        # Monitoring stack
│   ├── keycloak/             # Authentication
│   └── ingress/              # Ingress rules
│
├── docs/                      # Documentation
├── setup-mono-repo.sh        # Setup script
└── MIGRATION_GUIDE.md        # Migration guide
```

## 🚀 Quick Start

### Initial Setup

1. **Run setup script:**
```bash
./setup-mono-repo.sh
```

This will:
- Create local directories for source and config repos
- Initialize git repositories
- Copy necessary files
- Provide next steps instructions

2. **Create GitHub repositories:**
- `web-grading-system-services` - Source code
- `web-grading-system-config` - Helm charts

3. **Configure GitHub Secrets:**

For `web-grading-system-services`:
```
DOCKERHUB_USERNAME
DOCKERHUB_TOKEN
CONFIG_REPO_TOKEN
```

4. **Deploy ArgoCD Applications:**
```bash
cd deploy/argocd-apps
./generate-argocd-apps.sh
kubectl apply -f generated/
```

## 📚 Documentation

- **[SCRIPTS_GUIDE.md](./SCRIPTS_GUIDE.md)** - Hướng dẫn sử dụng các scripts quản lý
- **[MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md)** - Complete migration guide from multi-repo to mono-repo
- **[QUICK_REFERENCE.md](./QUICK_REFERENCE.md)** - Commands reference
- **[DEPLOYMENT_CHECKLIST.md](./DEPLOYMENT_CHECKLIST.md)** - Deployment checklist
- **[src-services/README.md](./src-services/README.md)** - Source code repository documentation
- **[config-services/README.md](./config-services/README.md)** - Config repository documentation
- **[deploy/argocd-apps/README.md](./deploy/argocd-apps/README.md)** - ArgoCD setup guide

## 🎮 Lifecycle Management Scripts

Hệ thống cung cấp các scripts để quản lý lifecycle:

| Script | Mục đích | Khi dùng |
|--------|----------|----------|
| `setup.sh` | Setup hệ thống lần đầu | Lần đầu hoặc sau clean |
| `start.sh` | Khởi động hệ thống | Sau reboot |
| `stop.sh` | Dừng hệ thống | Trước khi tắt máy |
| `clean.sh` | Xóa toàn bộ | Reset hệ thống |
| `status.sh` | Kiểm tra trạng thái | Bất cứ lúc nào |

### Quick Start với Scripts

```bash
# Lần đầu setup
./setup.sh

# Mỗi lần bật máy
./start.sh

# Kiểm tra status
./status.sh

# Trước khi tắt máy
./stop.sh
```

Chi tiết xem [SCRIPTS_GUIDE.md](./SCRIPTS_GUIDE.md)

## 🎯 Key Features

### Smart CI/CD Pipeline
- ✅ Automatic detection of changed services
- ✅ Builds only affected services
- ✅ Parallel builds for multiple services
- ✅ Automatic version management
- ✅ Docker image build and push
- ✅ Auto-update config repository

### GitOps with ArgoCD
- ✅ Declarative deployment
- ✅ Automatic synchronization
- ✅ Self-healing
- ✅ Easy rollback
- ✅ Audit trail

### Mono-Repo Benefits
- ✅ Reduced repository count (12+ → 3)
- ✅ Centralized CI/CD management
- ✅ Easier dependency management
- ✅ Simplified versioning
- ✅ Better code sharing

## 🔧 Services

| Service | Port | Description |
|---------|------|-------------|
| api-gateway | 8080 | Main API Gateway |
| submission-service | 8082 | Handle code submissions |
| executor-service | 8083 | Execute code in sandbox |
| result-service | 8084 | Manage grading results |
| assignment-service | 8085 | Manage assignments |

## 🛠️ Development Workflow

### Making Changes

1. Clone source repo:
```bash
git clone https://github.com/PTIT-DTL-Project/web-grading-system-services.git
cd web-grading-system-services
```

2. Create feature branch:
```bash
git checkout -b feat/my-feature
```

3. Make changes to a service:
```bash
vim submission-service/src/...
```

4. Push and create PR:
```bash
git add .
git commit -m "feat(submission-service): add new feature"
git push origin feat/my-feature
```

5. CI/CD automatically:
   - Detects changed service
   - Builds Docker image
   - Updates config repo
   - ArgoCD syncs to cluster

### Adding New Service

See [MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md#adding-a-new-service)

## 🔍 Monitoring & Observability

The system includes a complete observability stack:

```bash
cd deploy/observability
./install.sh
```

Includes:
- Prometheus - Metrics collection
- Grafana - Visualization
- Loki - Log aggregation
- Tempo - Distributed tracing

## 🔐 Security

- Secrets managed via Kubernetes Secrets
- GitHub PAT for cross-repo updates
- DockerHub tokens for image registry
- Keycloak for authentication

## 📖 Additional Resources

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Helm Charts Best Practices](https://helm.sh/docs/chart_best_practices/)
- [GitHub Actions Matrix Strategy](https://docs.github.com/en/actions/using-jobs/using-a-matrix-for-your-jobs)

## 🆘 Troubleshooting

See [MIGRATION_GUIDE.md - Troubleshooting](./MIGRATION_GUIDE.md#-troubleshooting)

## 📝 License

[Your License Here]

## 👥 Contributors

[Your Contributors Here]