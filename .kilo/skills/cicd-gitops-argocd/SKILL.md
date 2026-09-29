---
name: cicd-gitops-argocd
description: GitOps CI/CD deploy flow for this project - GitHub Actions builds images and bumps tags in the config repo, ArgoCD auto-syncs Helm charts to k3s. Use when touching src-services/.github/workflows, deploy/argocd-apps/, service image versions, values-stg.yaml, ArgoCD Applications, or debugging "deploy didn't update" / sync issues.
---

# CI/CD GitOps flow (GitHub Actions → config repo → ArgoCD)

Two-repo GitOps model. This repo (`web-grading-system-deploy`) holds infra and
ArgoCD app definitions. A separate **config repo** holds one Helm chart per
service. Nothing deploys by hand — a git commit to the config repo is the deploy.

## 1. The flow

```
1. Code push → source repo (src-services/)
2. build-services.yml → build + test changed services, push Docker image
3. publish.yml → clone CONFIG_REPO, bump image tag in <service>/values-stg.yaml, commit
4. ArgoCD detects config repo change → auto-sync (prune + selfHeal)
5. Pods roll to new tag in namespace web-grading
```

- Source repo: `src-services/` (Java microservices, JDK 21, Maven).
- Config repo: `PTIT-DTL-Project/web-grading-system-services-config` (mono-repo,
  `<service>/Chart.yaml` + `<service>/values-stg.yaml`).
- Workflows: `src-services/.github/workflows/build-services.yml`,
  `src-services/.github/workflows/publish.yml`.

## 2. publish.yml contract (do not break)

- Triggers via `workflow_run` after "Build and Test Services" completes on main.
- Reads `changed-services.json` artifact from the build run; empty matrix = no-op.
- Clones CONFIG_REPO with token `${{ secrets.CONFIG_REPO_TOKEN }}`
  (`x-access-token:$GH_TOKEN@github.com/<repo>.git`), rewrites the tag line in
  `values-stg.yaml`, commits and pushes.
- Required secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_PASSWORD`, `CONFIG_REPO_TOKEN`.

PAST FIX — wrong CONFIG_REPO: it once pointed at the deploy repo instead of the
config repo, so manifests never updated. Rule: CONFIG_REPO is ALWAYS the repo
containing Helm charts (`*-services-config`), verified by checking it contains
`<service>/values-stg.yaml` paths.

PAST FIX — service rename broke CI silently: renaming a service directory
(e.g. assignment-service -> course-service) MUST also update
`src-services/.github/workflows/build-services.yml` in BOTH places:
the `on.push.paths` list AND the `dorny/paths-filter` filters block.
A stale path never matches -> empty matrix -> build job skipped -> image never built/pushed.
publish.yml needs no change (it consumes the dynamic changed-services.json artifact).
When auditing a rename, grep `.github` under BOTH the repo root AND `src-services/`.

PAST FIX — hardcoded versions broke releases: services must read version from
package metadata (`getClass().getPackage().getImplementationVersion()`, fallback
`"dev"`), never hardcode it in code or `application.yaml`. Tag deletion + re-push
of an existing version also requires deleting the GitHub Release manually.

## 3. ArgoCD Application management

Generated, never hand-written:

```bash
cd deploy/argocd-apps
# add/edit service names in services.env (one per line)
./generate-argocd-apps.sh          # renders template into generated/
kubectl apply -f generated/
```

Template facts (`argocd-app-template.yaml`, single var `${SERVICE_NAME}`):

- App name: `grading-${SERVICE_NAME}`, namespace `argocd`.
- Source: config repo, `targetRevision: main`, path `<service>`, helm valueFile
  `values-stg.yaml`.
- Destination: `https://kubernetes.default.svc`, namespace `web-grading`.
- SyncPolicy: `automated: {prune: true, selfHeal: true}`.

Add-a-service checklist:
1. Append name to `deploy/argocd-apps/services.env`.
2. Chart must exist in config repo: `<service>/Chart.yaml` + `values-stg.yaml`.
3. Regenerate + apply. ArgoCD creates the app; chart owns the rest.

PAST FIX — wrong manifest config repo: repoURL/targetRevision in the template
must match the real config repo branch ArgoCD can reach. If apps show
Unknown/OutOfSync forever with no diff, suspect repoURL or credentials first.

## 4. Verify & debug

```bash
kubectl get applications -n argocd                 # all apps + sync status
kubectl get application grading-submission-service -n argocd -o yaml
kubectl describe application <app> -n argocd       # conditions show sync errors
argocd app get grading-submission-service          # diff detail

# initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

Symptom map:
- Image tag updated in config repo but pods old → check app Sync status; if
  OutOfSync with expected diff, wait for reconcile or hard-refresh; if Synced,
  check rollout (`kubectl rollout status deployment/<svc> -n web-grading`).
- publish.yml red at clone step → `CONFIG_REPO_TOKEN` missing/expired or repo renamed.
- App Missing → chart path doesn't exist on that branch in the config repo.
