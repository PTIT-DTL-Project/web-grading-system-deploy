# Observability Stack

Grafana + Prometheus + Node Exporter + kube-state-metrics + Loki (promtail) +
Tempo + Alloy (OTLP collector) + Pyroscope (continuous profiling) + k6 trace generator, for a k3s cluster.
Optimized for an 8 GB RAM box.

## Architecture

```
                ┌──────────────────────────────────────────────┐
                │                    Grafana                     │  ← UI for traces, logs, metrics
                └─┬────────────────────────────────────────────┘
                  │ datasources: Prometheus, Loki, Tempo
         ┌────────┼───────────┬──────────┐
         ▼        │           │          │
   ┌───────┐  ┌───────┐  ┌───────┐  ┌─────────┐
   │Prom+NE│  │ Loki  │  │Tempo  │  │ Alloy   │ ← OTLP collector (deploy)
   │(scrape)│  │+promt.│  │(traces│  │(4317/   │
   └───┬───┘  └───▲───┘  └───▲───┘  └──┬──────┘
       │          │          │  ▲    ▲│
  node │          │          │  │    │└ OTLP from backend pods + trace gen
  -exporter      │          │  │    │
  +kube-st-m     │          │  │    │
       │   ▲     │          │  │    │
       │   │     │          │  │    │
   ┌────▼──┴─────▼──┐   ┌───▼──▼────▼──────┐
   │ Backend pods   │   │ k6-trace-gen     │  ← synthetic traces (dev)
   │ (web-grading)  │   └──────────────────┘
   └────────────────┘         (alloy:4317)
          /actuator ───────────► OTel ──► Tempo
          /prometheus ────────► Prom
          JSON logs ──────────► promtail ──► Loki
```

- **Prometheus** scrapes backend `/actuator/prometheus` + `node_exporter` + `kube-state-metrics`.
- **Alloy** is an OTLP collector: backend services + the k6 trace generator send traces `→ Alloy → Tempo`.
- **promtail** tails pod logs into **Loki** (logs carry `trace_id`/`span_id` for correlation).
- **Grafana** (bundled by kube-prometheus-stack) is the single pane.

## Components

| Component | Mode | Memory | Purpose |
|-----------|------|--------|---------|
| **Grafana** | Helm (kube-prometheus-stack) | 256Mi-512Mi | Dashboard UI |
| **Prometheus** | Helm (kube-prom-stack) | 512Mi-1Gi | Metrics store + scraping |
| **kube-state-metrics** | Helm | 64Mi-128Mi | k8s object metrics |
| **Node Exporter** | Helm (DaemonSet) | 32Mi/node | Host metrics (CPU/mem/disk/net) |
| **Loki** | Helm (SingleBinary) + promtail DaemonSet | 256Mi-512Mi | Log aggregation |
| **Tempo** | Helm | 256Mi-512Mi | Trace storage |
| **Alloy** | Helm (Deployment) | 100m/128Mi → 300m/256Mi | OTLP trace collector → Tempo |
| **Pyroscope** | Helm (single-process) | 256Mi-512Mi | Continuous profiling |
| **k6 Trace Generator** | Manifest | 100m/128Mi | Synthetic OTLP traces (dev) |

## Quick Start

```bash
# 1. Create env file
cp .env.observability.example .env.observability
vim .env.observability  # edit GRAFANA_DOMAIN, passwords, etc.

# 2. Install (needs: kubectl + helm, cluster running)
./install.sh

# 3. Check
kubectl get pods -n observability
```

## Spring Boot Service Integration

### Local development: push telemetry to the deployed stack

Run a service on your localhost but still send metrics/traces/profiles to the
deployed observability stack via the Cloudflare tunnel:

```bash
export OTLP_TRACES_ENDPOINT=https://web-dev2-otlp.vucongtuanduong.dpdns.org/v1/traces
export OTLP_METRICS_ENDPOINT=https://web-dev2-otlp.vucongtuanduong.dpdns.org/v1/metrics
export PYROSCOPE_ENDPOINT=https://web-dev2-pyroscope.vucongtuanduong.dpdns.org
./gradlew bootRun   # or however you start the local service
```

Both hostnames are routed by the Cloudflare tunnel → Traefik → the in-cluster
Alloy (:4318) and Pyroscope (:4100) receivers. ArgoCD CI/CD keeps deploying the
real services normally; the local instance is just an extra telemetry source.

### Dependencies (pom.xml)

Spring Boot 4.x — needs `actuator` (Prometheus + health) and `opentelemetry` (OTLP tracing), both already present:

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

### application.yaml (merge the block under `management`)

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  tracing:
    enabled: true
    sampling:
      probability: 1.0  # 1.0 = dev (100%), 0.1-0.3 for prod
  otlp:
    tracing:
      endpoint: http://alloy.observability.svc.cluster.local:4318/v1/traces
      transport: http
# No OTLP metrics export — Prometheus scrapes /actuator/prometheus directly.
spring:
  application:
    name: my-service  # appears as service name in Grafana traces
logging:
  pattern:
    level: "%5p [${spring.application.name:},%X{traceId:-},%X{spanId:-}]"
```

### Log shipping (Loki)

promtail ships logs from pods that carry the `app.kubernetes.io/name` label, so
each backend service Deployment/Service should set it (most do by default). Drop
`templates/logback-spring.xml` into each Spring Boot service's
`src/main/resources` so JSON logs include `trace_id`/`span_id`.

### What you get

- **Traces**: every HTTP/DB/outbound call is auto-traced (`alloy → Tempo`).
- **Metrics**: RED metrics from traces + Prometheus scrapes of `actuator/prometheus` and node-exporter.
- **Logs**: JSON logs correlated with traces via `trace_id`/`span_id`.
- **Service map**: dependency graph of backend services in Grafana.

## Dashboard

The shared `k8s-general.json` dashboard is imported by `install.sh` and includes:

| Section | Panels |
|---------|--------|
| Cluster Overview | Pods, Deployments, CPU%, Memory%, Not Ready |
| CPU & Memory by Service | Time series per pod |
| Node Metrics (Node Exporter) | Cluster CPU%, Memory%, node count, per-node CPU usage |
| Logs | Log volume by service/container, live log stream |
| Traces & Service Map | Service graph, request rate, error rate, duration P99 |
| Trace Search | Search traces by service, operation, duration |

Access at: `http://<GRAFANA_DOMAIN>` (admin / `GRAFANA_ADMIN_PASSWORD`).

## File Structure

```
deploy/observability/
├── .env.observability.example  # Template (copy to .env.observability)
├── install.sh                  # Install all
├── uninstall.sh                # Remove all
├── README.md
├── charts/
│          ├── kube-prometheus-stack-values.yaml  # Prometheus + Grafana + Node Exporter + kube-st-m
│   ├── loki-values.yaml                   # Loki + promtail (logs)
│   ├── tempo-values.yaml                  # Tempo (traces)
│   ├── alloy-values.yaml                  # Alloy (OTLP collector → Tempo)
│   └── pyroscope-values.yaml              # Pyroscope (continuous profiling)
├── manifests/
│   ├── monitoring/
│   │   └── trace-generator.yaml           # k6 synthetic trace generator
│   └── ingress/
│       ├── grafana.yaml
│       ├── otlp.yaml                        # web-dev2-otlp → alloy:4318 (local dev)
│       └── pyroscope.yaml                   # web-dev2-pyroscope → pyroscope:4100 (local dev)
├── templates/
│   ├── application-observability.yaml     # merge-block for Spring Boot services
│   └── logback-spring.xml                 # JSON logging with trace IDs
└── dashboards/
    └── k8s-general.json                  # Shared Grafana dashboard
```

## Resource Usage

Estimated total (full stack with traces/metrics/logs): **~4-5Gi RAM**

| Component | CPU Req | Mem Req | CPU Limit | Mem Limit |
|-----------|---------|---------|-----------|-----------|
| Prometheus | 200m | 512Mi | 1000m | 1Gi |
| kube-state-metrics | 100m | 64Mi | 200m | 128Mi |
| Node Exporter (per node) | 10m | 16Mi | 100m | 64Mi |
| Loki (single + promtail) | 100m | 256Mi | 500m | 512Mi |
| Tempo | 100m | 256Mi | 500m | 512Mi |
| Alloy (OTLP collector) | 100m | 128Mi | 300m | 256Mi |
| Pyroscope | 100m | 256Mi | 300m | 512Mi |
| Grafana | 100m | 256Mi | 500m | 512Mi |

> Tip: set `prometheus-node-exporter.enabled: false` and `kube-state-metrics.enabled: false` if you only need service-level metrics, to trim ~200Mi.
