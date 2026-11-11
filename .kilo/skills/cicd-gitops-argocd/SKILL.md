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

Add-a-service checklist (full onboarding surface, distilled 2026-10-15 from
the ai-assistant-service onboarding):
1. CI: add the dir to `build-services.yml` in BOTH places — `on.push.paths`
   AND the `dorny/paths-filter` block (same defect class as the rename fix).
   `publish.yml` needs no change (generic loop over changed-services.json).
2. Add the service's Dockerfile if missing (context = service dir, so it MUST
   be at the service root) + mvnw/.mvn wrapper (sibling Dockerfile copies them).
3. Append name to `deploy/argocd-apps/services.env`.
4. Chart must exist in config repo: `<service>/Chart.yaml` + `values-stg.yaml`
   with exactly one `tag:` line (sed rewrites the first); seed `tag: "v1.0.0"`
   — publish.yml only warns and skips when the chart dir is absent, it never
   creates one.
5. New secrets → `deploy/setup-namespace.sh` + chart env; chart env names must
   match the service's own placeholders (no auto-mapping).
6. Ingress debug host → `deploy/ingress/<service>.yaml` (install-ingress.sh
   globs the folder, nothing else to register).
7. DB must ALREADY exist on the target server — no script provisions databases.
8. Cloudflare public hostname → manual, dashboard-only (see cloudflare-tunnel
   skill).
9. Regenerate + apply: `./generate-argocd-apps.sh && kubectl apply -f generated/`.
   ArgoCD creates the app; chart owns the rest.
Note: `set-log-level.sh` and `dev-scale.sh` read `services.env` dynamically —
no edit needed there. Fresh-install scripts need no per-service edit either
(install-ingress globs, install-argocd regenerates, setup-namespace owns secrets).

PAST FIX — wrong manifest config repo: repoURL/targetRevision in the template
must match the real config repo branch ArgoCD can reach. If apps show
Unknown/OutOfSync forever with no diff, suspect repoURL or credentials first.

### 3.1 ArgoCD RAM footprint (8 GB node)

The upstream `argo-cd/stable/install.yaml` ships NO requests/limits, so every
ArgoCD pod is unbounded and the kernel OOM-kills whichever has the largest RSS
(usually repo-server) mid-sync. `deploy/install-argocd.sh` therefore applies,
right after `kubectl apply -f generated/`:

```bash
# controller: try StatefulSet (ArgoCD 2.x) and Deployment (3.x), `|| true` on
# both so either version works
kubectl -n argocd set resources statefulset/argocd-application-controller \
  --requests=cpu=100m,memory=192Mi --limits=cpu=500m,memory=512Mi
kubectl -n argocd set resources deployment/argocd-application-controller ...same...
kubectl -n argocd set resources deployment/argocd-repo-server  --limits=cpu=500m,memory=384Mi
kubectl -n argocd set resources deployment/argocd-server       --limits=cpu=500m,memory=384Mi
kubectl -n argocd set resources deployment/argocd-redis        --limits=cpu=200m,memory=192Mi
kubectl -n argocd set resources deployment/argocd-dex-server   --limits=cpu=200m,memory=192Mi
```

Two controllers are scaled to 0 because this project never uses them:
`argocd-notifications-controller` (no notification templates/subscriptions) and
`argocd-applicationset-controller` (apps are static manifests rendered by
`generate-argocd-apps.sh`, no generators). Each idles at ~60-80Mi. Scale, do not
delete: a re-install re-applies install.yaml and recreates them.

Keep dex and redis. Local `admin` login works without dex, but scaling dex to 0
is a separate decision (SSO would break) — only limits are applied here.

### 3.2 Images in `deploy/` are pinned, never `:latest`

`rustfs/rustfs:1.0.5` and `ghcr.io/kafbat/kafka-ui:v1.5.0` (pinned
2026-11-11; both were `:latest` before). Why it matters here: with tag `latest`
Kubernetes defaults to `imagePullPolicy: Always`, so every pod restart can land
a different build — and the RustFS 512Mi limit in that same file is tuned against
one build's memory behaviour. (Kafka UI had the opposite bug: `latest` +
`IfNotPresent` pins each node to whatever it pulled first, i.e. an undefined
version.) `quay.io/keycloak/keycloak:26.0` and `docker:27-dind` are floating
minor tags, not `latest`; bump them deliberately.

Resolve `latest` to a version by digest, not by reading release notes:

```bash
# Docker Hub (single-arch digest from the tag endpoint)
curl -s "https://hub.docker.com/v2/repositories/rustfs/rustfs/tags/latest" | jq -r .digest
curl -s "https://hub.docker.com/v2/repositories/rustfs/rustfs/tags/1.0.5"  | jq -r .digest  # must match

# GHCR - compare the MANIFEST INDEX digest, never a platform digest
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:kafbat/kafka-ui:pull&service=ghcr.io" | jq -r .token)
curl -sI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://ghcr.io/v2/kafbat/kafka-ui/manifests/v1.5.0" | grep -i docker-content-digest
```

Equal index digests prove the tag and `latest` are the same artifact. Write the
resolved tag plus the digest and date as a comment above `image:` so the next
bump has a reference point.

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

Render a chart locally before pushing (charts in `config-services/` ship **no** default
`values.yaml`, only `values-stg.yaml`, so plain `helm template` dies on
`nil pointer evaluating interface {}.type`):

```bash
helm template <name> config-services/<name> -f config-services/<name>/values-stg.yaml
```

## 5. setup-namespace.sh secret rules

`deploy/setup-namespace.sh` runs on every `setup*.sh` (setup.sh step 2), so each
secret write MUST be idempotent: a changed Secret does NOT restart pods (all
services read `gateway-trust` via `secretKeyRef`), so a rotated value leaves the
running pods stale and forces `clean.sh` + a full redeploy to realign.

- Config secrets (db-secret, rustfs-secret, ai-credentials, app-config, …):
  `--from-literal=VALUE="${VAR:-default}"` — stable across re-runs; the same
  blank `.env` var always falls back to the same default.
- `gateway-trust`: NEVER auto-rotate on re-run. Read the value already in the
  cluster and generate (`openssl rand -hex 32`) only when it is absent.
  Precedence: explicit non-empty `.env` value (deliberate rotation) → existing
  cluster value → fresh random. The `kubectl get … -o jsonpath=… | base64 -d`
  probe is `|| true`-guarded (the secret is absent on a fresh cluster; `set -e`
  + `pipefail` would otherwise abort the script).
- Fail-loud secrets (`keycloak-admin-client`): values come from Keycloak, not
  from us, so a missing pair exits 1 instead of pushing blank credentials.
- `rustfs-secret` carries the RustFS ROOT credentials (`RUSTFS_ACCESS_KEY` /
  `RUSTFS_SECRET_KEY`), and `deploy/rustfs/deployment.yaml` reads those same keys
  as `RUSTFS_ROOT_USER` / `RUSTFS_ROOT_PASSWORD` (no `optional: true`, so a
  missing Secret stops the pod at `CreateContainerConfigError`). Because
  submission-service/executor-service read the same Secret to sign requests,
  server and clients cannot drift — and a rotated password only takes effect
  after `kubectl rollout restart deploy/rustfs deploy/submission-service
  deploy/executor-service` (env is read at container start). `install-rustfs.sh`
  preflights the Secret so a raw `kubectl apply` cannot half-deploy it.

## 6. Probes target health groups, never `/actuator/health`

Every chart ships the same generated probe block. Point readiness at
`/actuator/health/readiness`, liveness at `/actuator/health/liveness`, and give
each JVM pod a `startupProbe` on the liveness path.

WHY: the root `/actuator/health` endpoint also runs the `db` indicator. These
services use a Neon serverless Postgres that suspends when idle, so the first
health check after suspension blocks ~14s waking the compute. k8s
`timeoutSeconds` defaults to 1s, so the probe times out, fails
`failureThreshold` (default 3) times in a row, and kubelet restarts the pod:
graceful SIGTERM, NOT OOMKill. Observed 2026-10-17 on ai-assistant-service:
liveness fired at +60s (JVM needs ~80s), +90s and +120s (db indicator hung),
kill at +130s. ai-assistant flapped first only because it is the idle service;
the others hold a hot DB connection. Pod memory is NOT the cause: don't raise
`resources.limits.memory` for this symptom.

The `livenessState`/`readinessState` groups are enabled automatically in k8s
(`GET /actuator/health` returns `{"groups":["liveness","readiness"]}`) and
answer in ms without touching the DB, so no `application.yaml` change is
needed (adding `management.endpoint.health.probes.enabled: true` only makes it
explicit). The `startupProbe` (periodSeconds 10, `failureThreshold: 30` ≈ 5 min)
gives the cold JVM its own budget, so the old guessed `initialDelaySeconds:
30/60` are unnecessary.
