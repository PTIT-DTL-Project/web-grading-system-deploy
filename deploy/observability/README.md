# Observability Stack (Lite)

Prometheus + Grafana UI + Tempo (distributed tracing), for a single-node k3s
cluster. Sized for an 8 GB RAM box.

## Architecture

```
                 ┌─────────────────────────────────────────────┐
                 │                  Grafana                    │  ← UI (metrics + traces)
                 └───┬─────────────────────────────────────┬───┘
                     │ Prometheus datasource               │ Tempo datasource
                     ▼                                     ▼
              ┌─────────────┐                        ┌─────────────┐
              │ Prometheus  │                        │   Tempo     │
              │  (scrape)   │                        │  (traces)   │
              └──────▲──────┘                        └──────▲──────┘
                     │ pull /actuator/prometheus            │ OTLP/HTTP :4318
                     │                                      │
              ┌──────┴──────────────────────────────────────┴──────┐
              │             Backend pods (web-grading)            │
              └───────────────────────────────────────────────────┘
```

- **Prometheus** pulls `/actuator/prometheus` from the six Spring Boot services
  every 30 s using Kubernetes pod service discovery.
- **Tempo** receives OTLP/HTTP traces directly from each service
  (`tempo.observability.svc.cluster.local:4318/v1/traces`); there is no
  collector in between.
- **Grafana** is the single pane. Both datasources (Prometheus and Tempo) are
  declared explicitly under `grafana.additionalDataSources` in
  `charts/kube-prometheus-stack-values.yaml`. The generated ConfigMap is mounted
  **directly** into the Grafana pod at
  `/etc/grafana/provisioning/datasources/datasource.yaml`
  (`grafana.extraConfigmapMounts`), with the datasource sidecar off and
  `forceDeployDatasources: true`. The chart's own provisioning is disabled
  (`defaultDatasourceEnabled: false`) because it also injects an Alertmanager
  datasource even though Alertmanager is not deployed.

  Why not the sidecar: it writes the provisioning file after Grafana has read
  the directory, so a fresh install can show an empty datasource list; it also
  needs an extra image from quay.io and RBAC to watch ConfigMaps. Because the
  mount uses `subPath`, changing `additionalDataSources` requires
  `kubectl -n observability rollout restart deploy/monitoring-grafana`.
  `install.sh` verifies the file from inside the pod at the end of the run.

There is **no Loki, Mimir, Alloy, Pyroscope, node-exporter, kube-state-metrics,
or Alertmanager** in this deployment. Do not re-add them on the 8 GB box.

## Components

| Component | Mode | Memory | Purpose |
|-----------|------|--------|---------|
| **Grafana** | Helm (kube-prometheus-stack) | 256Mi–512Mi | UI for Prometheus + Tempo |
| **Prometheus** | Helm (kube-prometheus-stack) | 256Mi–768Mi | Metrics store, scrapes `/actuator/prometheus` |
| **Tempo** | Helm | 256Mi–512Mi | Trace storage (OTLP 4317/4318) |

## Quick Start

```bash
# 1. Create env file
cp .env.observability.example .env.observability
vim .env.observability  # set GRAFANA_ADMIN_PASSWORD

# 2. Install (needs: kubectl + helm, cluster running)
./install.sh

# 3. Check
kubectl get pods -n observability
```

`install.sh` prints a warning if other Helm releases still exist in the
`observability` namespace (for example `loki`, `mimir`, `alloy`, `pyroscope`
from the old full stack). Those keep consuming RAM even after the Lite stack is
installed; remove them with `helm uninstall <release> -n observability`.

## Spring Boot Service Integration

### Dependencies (pom.xml)

Spring Boot 4.x needs `actuator` (Prometheus + health) and `opentelemetry`
(OTLP tracing):

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-opentelemetry</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
```

### application.yaml (merge under `management`)

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  tracing:
    sampling:
      probability: ${OTEL_TRACES_SAMPLING_PROBABILITY:1.0}
    export:
      enabled: true   # Boot 4.1 default; declared so all six match
  # Spring Boot 4.x names. management.otlp.tracing.* and
  # management.tracing.enabled are deprecated at error level.
  # Verified against spring-boot-micrometer-tracing-opentelemetry-4.1.0.
  opentelemetry:
    tracing:
      export:
        otlp:
          endpoint: ${OTLP_TRACES_ENDPOINT:http://tempo.observability.svc.cluster.local:4318/v1/traces}
  otlp:
    metrics:
      # Prometheus pulls the metrics; do not also push them to Tempo.
      export:
        enabled: false
logging:
  pattern:
    level: "%5p [${spring.application.name:},%X{traceId:-},%X{spanId:-}]"
```

Micrometer's MDC keys are `traceId` and `spanId` (`Slf4JEventListener` in
`micrometer-tracing-bridge-otel`). `trace_id`/`span_id` are wrong and produce
empty log fields. Logs are plain stdout — no aggregator parses them, so nothing
else needs configuring.

OTLP **metrics** keep the `management.otlp.metrics.export.*` namespace in Boot
4.1 (`enabled` defaults to `true`). There is no
`management.opentelemetry.metrics.*` equivalent; writing one is silently ignored
and metrics export turns back on.

### What you get

- **Traces**: every HTTP/DB/outbound call is auto-traced and pushed to Tempo.
- **Metrics**: Prometheus scrapes `http_server_requests_*` and the other
  Actuator metrics from each backend pod.
- **Grafana**: query both datasources from one UI. No dashboards are
  provisioned by default; use Explore, or add ConfigMaps labelled
  `grafana_dashboard=1` (the dashboards sidecar is disabled in this Lite
  deployment, so re-enable it first if you add any).

## File Structure

```
deploy/observability/
├── .env.observability.example  # Template (copy to .env.observability)
├── install.sh                  # Preflight + Prometheus + Grafana + Tempo + ingress
├── uninstall.sh                # Remove releases, keep PVCs
├── README.md
├── charts/
│   ├── kube-prometheus-stack-values.yaml  # Prometheus + Grafana (all extras off)
│   └── tempo-values.yaml                  # Tempo (traces)
├── manifests/
│   └── ingress/
│       └── grafana.yaml                   # web-dev1-grafana → monitoring-grafana:80
└── templates/
    └── application-observability.yaml     # merge-block for Spring Boot services
```

## Resource Usage

Estimated total: **~0.8 GiB requests, ~1.8 GiB limits**.

| Component | CPU Req | Mem Req | CPU Limit | Mem Limit |
|-----------|---------|---------|-----------|-----------|
| Prometheus | 100m | 256Mi | 500m | 768Mi |
| Grafana | 100m | 256Mi | 500m | 512Mi |
| Tempo | 100m | 256Mi | 500m | 512Mi |
| **Total** | **310m** | **800Mi** | **1550m** | **1.81Gi** |

## 8 GB tuning notes

- **Tempo ballast is disabled** (`tempo.memBallastSizeMbs: 0`). Tempo 2.x
  defaults to a 1 GiB ballast, which is twice the container limit and causes
  constant OOMKills/node pressure. `GOMEMLIMIT=400MiB` keeps the Go heap below
  the 512Mi limit.
- Image and resources live under `tempo.*` in the chart schema. A top-level
  `image:`/`resources:` block is silently ignored by this chart.
- Prometheus retains 3 days and stops at 1500 MB so the 2 GiB PVC cannot fill.
- cAdvisor is scraped every 30 s instead of the default 10 s.
- k3s control-plane components (`kubeControllerManager`, `kubeScheduler`,
  `kubeProxy`, `kubeEtcd`) are disabled: k3s runs them inside one process, so
  they only produced permanently-down targets.
- Prometheus does **not** send the ServiceAccount token to backend pods. That
  token made `api-gateway` return 401 before `permitAll()` on
  `/actuator/prometheus` could apply.
- Only pods labelled with one of the six service names and only ports
  `8080-8084,8086` are scraped. The executor's `dind` sidecar (2375),
  Keycloak, RustFS and Kafka UI are excluded.

## Access

- Grafana: `https://web-dev1-grafana.vucongtuanduong.dpdns.org` (admin / password from `.env.observability`)
- Prometheus (in-cluster): `monitoring-kube-prometheus-prometheus.observability.svc.cluster.local:9090`
- Tempo query (in-cluster): `tempo.observability.svc.cluster.local:3200`
- Tempo OTLP (in-cluster): `tempo.observability.svc.cluster.local:4318`

## Troubleshooting

**`helm` fails with `504 Gateway Timeout` while installing Tempo**
The classic `grafana/tempo` repo path resolves to
`github.com/grafana/helm-charts/releases/download/...`, whose CDN intermittently
answers 504. `install.sh` therefore pulls both charts from GHCR as OCI
artifacts (`oci://ghcr.io/grafana/helm-charts/tempo`,
`oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack`) and retries
each release 3 times. No `helm repo add` is needed; if you install by hand, use
the `oci://` reference instead of `grafana/tempo`.

**Grafana redirects to the wrong host / login loop**
Check `grafana.ini.server.domain`, `root_url` and `serve_from_sub_path` in
`charts/kube-prometheus-stack-values.yaml`. They must match the ingress host and
the ingress must route `/` (not a sub-path).

**`grafana.ini` has `anonymous = map[enabled:false]`**
Sections in `grafana.ini` must be flat key/value maps. A nested block
(`auth: { anonymous: { enabled: false } }`) is rendered by the chart as an
unknown option. Use `auth.anonymous: { enabled: false }`.

**Tempo keeps restarting (OOMKilled)**
`kubectl describe pod -n observability tempo-0` → look at `Last State`.
Confirm `tempo.memBallastSizeMbs: 0` and that resources are under `tempo:`.

**Prometheus target for api-gateway returns 401**
Remove `bearer_token_file`/`tls_config` from `additionalScrapeConfigs`. Those
settings authenticate the scrape to the target pod, not to the Kubernetes API.

**Metrics missing for one service**
Grafana → Explore → Prometheus → check `up{service="<name>"}`. If 0, verify the
pod label `app` is one of the six names and that the pod is Ready.

**No traces**
Check `kubectl logs -n web-grading deploy/<service> | grep -i otlp`. Then query
Tempo from Grafana (Explore → Tempo → Search).
