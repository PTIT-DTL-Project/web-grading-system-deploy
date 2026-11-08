---
name: observability-stack
description: Lite observability stack for this project - kube-prometheus-stack (Prometheus + Grafana) and Tempo traces on k3s, sized for an 8 GB RAM box. Use when installing/updating deploy/observability/, wiring Spring Boot services to OTLP/Prometheus, debugging missing metrics or traces, Tempo OOMKills, Grafana redirects, Prometheus 401 scrape errors, or reviewing observability resource usage.
---

# Observability stack (k3s, 8 GB RAM)

All components live in the `observability` namespace. Deploy docs:
`deploy/observability/README.md`; architecture (Vietnamese):
`docs/observability/README.md`.

## 1. Components (Lite)

| Component | Helm chart | Purpose |
|---|---|---|
| Prometheus | prometheus-community/kube-prometheus-stack | Pulls `/actuator/prometheus` every 30 s, 3-day retention |
| Grafana | prometheus-community/kube-prometheus-stack | UI; Prometheus + Tempo datasources |
| Tempo | grafana/tempo 1.21.1 | Trace storage, OTLP 4317/4318, 24 h retention |

NOT deployed: Loki, Mimir, Alloy, Pyroscope, node-exporter,
kube-state-metrics, Alertmanager. Do not add them back on this box.

Data paths:
- Metrics: Prometheus -> pod SD in `web-grading` -> app label + port filter.
- Traces: service -> OTLP/HTTP -> `tempo.observability.svc.cluster.local:4318`.
- Logs: stdout only; no aggregation.

## 2. Install / uninstall

```bash
cd deploy/observability
cp .env.observability.example .env.observability   # set GRAFANA_ADMIN_PASSWORD
./install.sh     # preflight leftovers + Tempo + kube-prometheus-stack + ingress
./uninstall.sh   # helm uninstall monitoring/tempo; PVCs kept
```

- Env file is REQUIRED.
- Charts are pulled as OCI artifacts: `oci://ghcr.io/grafana/helm-charts/tempo`
  and `oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack`. No
  `helm repo add` is needed, and each release is retried 3x.
  NEVER switch back to `grafana/tempo` / `prometheus-community/...` repo refs:
  those resolve to `github.com/*/helm-charts/releases/download/...`, which
  intermittently returns **504 Gateway Timeout** (seen 2026-11-08, edge
  `southeastasia`) and aborts the install. If installing by hand, use the same
  `oci://` reference + `--version`.
- Values live in `charts/tempo-values.yaml` and
  `charts/kube-prometheus-stack-values.yaml`.
- Grafana datasources are declared explicitly in `grafana.additionalDataSources`
  (Prometheus: uid `prometheus`, `isDefault: true`; Tempo: uid `tempo`) with
  `grafana.sidecar.datasources.defaultDatasourceEnabled: false`. The chart's own
  provisioning also emits an **Alertmanager** datasource even when
  `alertmanager.enabled: false`, i.e. a dead datasource in the UI. Never rely on
  it; keep exactly these two entries.
- `install.sh` warns about leftover releases (loki/mimir/alloy/pyroscope) in
  the namespace; those keep using RAM and must be uninstalled manually.

## 3. Chart-schema gotchas

`grafana.ini` (kube-prometheus-stack) is rendered as INI sections of flat
key/value pairs. Nested maps are printed as Go values: `auth: { anonymous: {
  enabled: false } }` becomes `anonymous = map[enabled:false]`, an unknown option
Grafana ignores. Write `auth.anonymous: { enabled: false }` instead. After any
values change, `helm template ... | grep 'map\['` must return nothing.

Tempo:

- Image and resources MUST be under `tempo.*`
  (`tempo.repository`, `tempo.tag`, `tempo.resources`). Top-level `image:` or
  `resources:` are silently ignored by grafana/tempo.
- `tempo.memBallastSizeMbs: 0` is mandatory. Tempo 2.x defaults to 1024 MB,
  which is larger than the 512Mi container limit -> OOMKill loop.
- `GOMEMLIMIT=400MiB` via `tempo.extraEnv` keeps the Go heap in bounds.
- Service ports are auto-derived from the container; do not hand-maintain a
  `service.ports` block.

## 4. Prometheus scrape rules

The `backend-services` job discovers pods in `web-grading` and keeps only:
- `__meta_kubernetes_pod_label_app` in the six service names;
- phase Running and `__meta_kubernetes_pod_ready=true`;
- container ports `8080|8081|8082|8083|8084|8086`.

NEVER add `bearer_token_file` or `tls_config` to this job. They authenticate
the scrape request to the target pod. `api-gateway` is an OAuth2 resource
server, so an invalid Bearer token produces 401 before `permitAll()` on
`/actuator/prometheus` applies. The ServiceAccount token is only for the
Kubernetes API used by service discovery.

k3s control-plane scrapers (`kubeControllerManager`, `kubeScheduler`,
`kubeProxy`, `kubeEtcd`) are disabled: k3s runs those components inside the
server process. cAdvisor is scraped every 30 s, not the chart default 10 s.

## 5. Spring Boot integration (Boot 4.x)

Dependencies: `spring-boot-starter-opentelemetry` and
`spring-boot-starter-actuator`.

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  tracing:
    sampling:
      probability: ${OTEL_TRACES_SAMPLING_PROBABILITY:1.0}
  opentelemetry:
    tracing:
      export:
        otlp:
          endpoint: ${OTLP_TRACES_ENDPOINT:http://tempo.observability.svc.cluster.local:4318/v1/traces}
  otlp:
    metrics:
      export:
        enabled: false   # Prometheus pulls; do not also push to Tempo
logging:
  pattern:
    level: "%5p [${spring.application.name:},%X{traceId:-},%X{spanId:-}]"
```

- Verified against Spring Boot 4.1.0 configuration metadata (inspect
  `META-INF/spring-configuration-metadata.json` in
  `spring-boot-micrometer-tracing*` / `spring-boot-opentelemetry`):
  - traces endpoint: `management.opentelemetry.tracing.export.otlp.endpoint`,
    value is the FULL url including `/v1/traces`.
  - export toggles: `management.tracing.export.enabled` (default true) and
    `management.tracing.export.otlp.enabled` (default true).
  - metrics OTLP stays at `management.otlp.metrics.export.*` and `enabled`
    defaults to **true**. There is no `management.opentelemetry.metrics.*`
    equivalent: writing that name is silently ignored and the push returns.
  - deprecated at ERROR: `management.tracing.enabled` ->
    `management.tracing.export.enabled`, and `management.otlp.tracing.*` ->
    `management.opentelemetry.tracing.export.otlp.*`.
  - `management.tracing.sampling.probability` defaults to **0.1**, hence the
    explicit `${OTEL_TRACES_SAMPLING_PROBABILITY:1.0}`.
- Unknown `management.*` keys are dropped silently, so a typo stops trace
  export without any startup error. All six services must declare the SAME
  management block; diff them before shipping (`grep -A30 '^management:'`).
- Micrometer MDC keys are `traceId`/`spanId` (camelCase, written by
  `Slf4JEventListener` in `micrometer-tracing-bridge-otel`); `trace_id`/`span_id`
  render as empty fields. Logs are plain stdout, nothing parses the MDC.
- Do not add `io.pyroscope:agent`; Pyroscope is not deployed.

## 6. Verify and debug

```bash
kubectl get pods -n observability
kubectl -n observability describe pod tempo-0        # Last State = OOMKilled?
kubectl -n web-grading port-forward deploy/api-gateway 8080:8080
curl -s http://localhost:8080/actuator/prometheus | head
kubectl -n observability port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
# http://localhost:9090/targets -> job backend-services
kubectl -n observability port-forward svc/tempo 3200:3200
curl -s "http://localhost:3200/api/search?limit=5"
```

Symptom map:
- Tempo restarting -> ballast not 0, or resources at wrong YAML level.
- `up{service="api-gateway"} == 0` with 401 -> bearer token in scrape config.
- Grafana redirect/login loop -> `server.domain`/`root_url` mismatch or
  `serve_from_sub_path: true` while ingress routes `/`.
- Service metrics missing -> wrong `app` label, not Ready, or port outside the
  scrape regex.
- Datasource missing in Grafana -> the datasource ConfigMap must carry
  `grafana_datasource: "1"` and the `grafana-sc-datasources` sidecar must be
  Ready.
- No traces -> OTLP endpoint wrong/typo'd (unknown key is dropped silently),
  Tempo down, or sampling 0.
- Node lag after install -> check leftover Helm releases and
  `kubectl get events -A --sort-by=.lastTimestamp`.

## 7. 8 GB budget

Observability requests ~0.8Gi, limits ~1.8Gi. Remaining RAM is shared with
k3s (~1.5Gi), ArgoCD (~1Gi), Keycloak, RustFS, six services, and executor
(2 replicas + dind if enabled). Prefer cutting non-observability usage
(executor replicas, Keycloak/RustFS limits, ArgoCD extras) over raising these
limits.
