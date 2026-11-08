# Observability Stack (Lite)

Prometheus + Grafana UI + Tempo (distributed tracing), for a k3s cluster.
Optimized for an 8 GB RAM box.

## Architecture

```
                      ┌──────────────────────────────────────────────┐
                      │                    Grafana                     │  ← UI for metrics + traces
                      └─┬────────────────────────────────────────────┘
                        │ datasources: Prometheus, Tempo
          ┌─────────────┼──────────────┐
          ▼             ▼              ▼
    ┌─────────┐   ┌─────────┐   ┌────────────┐
    │Prometheus│   │ Tempo   │   │ (no Loki)  │
    │(scrape)  │   │(traces) │   │ (no Alloy) │
    └────┬────┘   └────┬────┘   └────────────┘
         │             │
   scrape │             ▲ OTLP traces
   /actuator/prometheus │             │
         │             │
    ┌────▼─────────────▼─────┐
    │ Backend pods           │
    │ (web-grading)          │
    └────────────────────────┘
```

- **Prometheus** scrapes backend `/actuator/prometheus` (Spring Boot Actuator).
- **Tempo** receives OTLP traces directly from backend services (`tempo.observability.svc.cluster.local:4318`) and stores them.
- **Grafana** (bundled by kube-prometheus-stack) is the single pane: Prometheus datasource auto-provisioned, Tempo datasource provisioned in `kube-prometheus-stack-values.yaml`.

## Components

| Component | Mode | Memory | Purpose |
|-----------|------|--------|---------|
| **Grafana** | Helm (kube-prometheus-stack) | 256Mi-512Mi | Dashboard UI for Prometheus + Tempo |
| **Prometheus** | Helm (kube-prom-stack) | 512Mi-1Gi | Metrics store + scraping backend `/actuator/prometheus` |
| **Tempo** | Helm | 256Mi-512Mi | Distributed tracing storage (OTLP receiver on 4317/4318) |

## Quick Start

```bash
# 1. Create env file
cp .env.observability.example .env.observability
vim .env.observability  # edit GRAFANA_ADMIN_PASSWORD, GRAFANA_DOMAIN

# 2. Install (needs: kubectl + helm, cluster running)
./install.sh

# 3. Check
kubectl get pods -n observability
```

## Spring Boot Service Integration

### Dependencies (pom.xml)

Spring Boot 4.x — needs `actuator` (Prometheus + health) and `opentelemetry` (OTLP tracing):

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
      endpoint: http://tempo.observability.svc.cluster.local:4318/v1/traces
      transport: http
spring:
  application:
    name: my-service  # appears as service name in Grafana traces
logging:
  pattern:
    level: "%5p [${spring.application.name:},%X{traceId:-},%X{spanId:-}]"
```

### What you get

- **Traces**: every HTTP/DB/outbound call is auto-traced (backend → Tempo OTLP receiver).
- **Metrics**: Prometheus scrapes `http_server_requests_*` and other Actuator metrics from each backend pod.
- **Grafana UI**: query Prometheus metrics and Tempo traces from one place.

## File Structure

```
deploy/observability/
├── .env.observability.example  # Template (copy to .env.observability)
├── install.sh                  # Install Prometheus + Grafana + Tempo
├── uninstall.sh                # Remove all
├── README.md
├── charts/
│   ├── kube-prometheus-stack-values.yaml  # Prometheus + Grafana (Node Exporter on; kube-state-metrics/Alertmanager off)
│   └── tempo-values.yaml                  # Tempo (traces)
├── manifests/
│   └── ingress/
│       └── grafana.yaml                   # web-dev1-grafana → monitoring-grafana:80
└── templates/
    └── application-observability.yaml     # merge-block for Spring Boot services
```

## Resource Usage

Estimated total (Prometheus + Grafana + Tempo): **~1.5-2Gi RAM**

| Component | CPU Req | Mem Req | CPU Limit | Mem Limit |
|-----------|---------|---------|-----------|-----------|
| Prometheus | 200m | 512Mi | 1000m | 1Gi |
| Grafana | 100m | 256Mi | 500m | 512Mi |
| Tempo | 200m | 384Mi | 1 | 1Gi |

## Access

- Grafana: `https://web-dev1-grafana.vucongtuanduong.dpdns.org` (admin / `GRAFANA_ADMIN_PASSWORD`)
- Prometheus (in-cluster): `monitoring-kube-prometheus-prometheus.observability.svc.cluster.local:9090`
- Tempo query (in-cluster): `tempo.observability.svc.cluster.local:3200`
- Tempo OTLP (in-cluster): `tempo.observability.svc.cluster.local:4318`
