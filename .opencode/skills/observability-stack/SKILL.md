---
name: observability-stack
description: Observability stack for this project - kube-prometheus-stack (Grafana/Prometheus), Loki logs, Tempo traces via Alloy OTLP collector, Pyroscope profiling, k6 trace generator on k3s. Use when installing/updating deploy/observability/, wiring Spring Boot services to OTLP endpoints, debugging missing metrics/traces/logs, or touching Grafana dashboards.
---

# Observability stack (k3s, sized for an 8 GB RAM box)

All components in namespace `observability`. Full docs: `deploy/observability/README.md`.

## 1. Components

| Component | Helm chart | Purpose |
|---|---|---|
| Grafana + Prometheus + Node Exporter + kube-state-metrics | prometheus-community/kube-prometheus-stack | UI, metrics store, host + k8s object metrics |
| Loki (+ promtail DaemonSet) | grafana/loki | Log aggregation; pod JSON logs carry trace_id/span_id |
| Tempo | grafana/tempo | Trace storage |
| Alloy (Deployment) | grafana/alloy | OTLP collector :4317/:4318 → Tempo; also receives Pyroscope profiles |
| Pyroscope | grafana/pyroscope | Continuous profiling |
| k6 trace generator | raw manifest (`manifests/monitoring/trace-generator.yaml`) | Synthetic OTLP traces in dev |

Data paths:
- Metrics: Prometheus scrapes backend `/actuator/prometheus` + node_exporter + kube-state-metrics.
- Traces: services → OTLP → Alloy → Tempo.
- Logs: promtail tails container logs → Loki.
- Grafana is the single pane with Prometheus, Loki, Tempo datasources pre-wired.

## 2. Install / uninstall

```bash
cd deploy/observability
cp .env.observability.example .env.observability   # set GRAFANA_DOMAIN, GRAFANA_ADMIN_PASSWORD...
./install.sh     # helm upgrade --install per chart, pinned versions, then ingress manifests
./uninstall.sh
kubectl get pods -n observability
```

- Env file is REQUIRED — install.sh exits without it.
- Helm values live in `charts/*.yaml` (loki, tempo, alloy, pyroscope,
  kube-prometheus-stack). Edit values there; install.sh just applies them.
- Ingress for grafana/otlp/pyroscope: `manifests/ingress/*.yaml` → routed out
  via the Cloudflare tunnel (see cloudflare-tunnel skill).

## 3. Spring Boot service integration

Dependencies (already present per service):

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

Endpoints are env-var driven, so a service running ANYWHERE can feed the
deployed stack through the tunnel:

```bash
export OTLP_TRACES_ENDPOINT=https://web-dev1-otlp.vucongtuanduong.dpdns.org/v1/traces
export OTLP_METRICS_ENDPOINT=https://web-dev1-otlp.vucongtuanduong.dpdns.org/v1/metrics
export PYROSCOPE_ENDPOINT=https://web-dev1-pyroscope.vucongtuanduong.dpdns.org
```

In-cluster pods reach the same collectors by cluster-internal service DNS; the
tunnel hostnames are for local-dev runs and external sources. ArgoCD keeps
deploying services normally (see cicd-gitops-argocd skill) — telemetry config
must not change that contract.

Log correlation: logback template at `templates/logback-spring.xml` injects
trace_id/span_id into JSON logs so Loki entries link to Tempo traces.

## 4. Verify & debug

```bash
kubectl get pods -n observability                       # all Running?
kubectl logs -n observability deploy/alloy --tail 20    # OTLP ingest errors
curl -s https://web-dev1-otlp.vucongtuanduong.dpdns.org/v1/traces -X POST -d '' -o /dev/null -w '%{http_code}\n'
# 4xx from collector = reachable (good); 1033 = tunnel down (cloudflare-tunnel skill)
```

Symptom map:
- No traces in Grafana → check Alloy logs first, then that the service actually
  exports (env vars set), then Tempo datasource in Grafana.
- No logs in Loki → promtail DaemonSet not scheduled or wrong namespace labels.
- Prometheus target down → scrape annotations on the Deployment must expose
  `/actuator/prometheus`; check Targets page in Grafana for the exact URL.
- OOM kills after stack changes → re-check memory table in README before
  raising limits; the box only has 8 GB total.
