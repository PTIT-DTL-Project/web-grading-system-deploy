---
name: cloudflare-tunnel
description: Cloudflare Zero Trust Tunnel setup and troubleshooting for exposing this project's k3s services via *.vucongtuanduong.dpdns.org hostnames. Use when a tunnel hostname shows Cloudflare Error 1033, adding a new public hostname (e.g. kafka-ui), or when external URLs fail while the cluster itself is healthy.
---

# Cloudflare Zero Trust Tunnel (dashboard-only)

The project moved from local cloudflared to **Cloudflare Zero Trust tunnels** —
managed entirely in the Cloudflare Dashboard. The local `deploy/cloudflared/`
directory was deleted; there is no config file in the repo to edit.

Traffic path: internet → Cloudflare edge (TLS terminated) → Zero Trust tunnel →
machine's gateway (Traefik NodePort 30195) → Traefik Ingress → k8s service.

## 1. Hostnames

Pattern: `web-dev{N}-<sub>.vucongtuanduong.dpdns.org`.
Current subs: api, course, submission, result, grading, rustfs, rustfs-api,
argocd, keycloak, grafana, otlp, pyroscope, kafka-ui.

## 2. Adding a new public hostname

1. Deploy the k8s workload + Traefik Ingress for the new host (repo work).
2. Cloudflare Dash → Zero Trust → Networks → Tunnels → your tunnel
   → Public Hostnames → Add:
   - Subdomain: `web-dev1-<sub>.vucongtuanduong.dpdns.org` (or pattern host)
   - Service: `http://localhost:30195` (Traefik NodePort)
   - TLS: leave default
3. Save — no restart needed, live immediately.

## 3. Troubleshooting Error 1033

Cloudflare Error 1033 means the edge can't reach your gateway—not the tunnel.

1. Is Traefik reachable? `kubectl get svc -n kube-system traefik` — needs
   LoadBalancer IP; `curl -H "Host: web-dev1-…" http://192.168.103.27:30195/`.
2. Is the tunnel connected? Dash → Tunnels — check status Healthy, not
   Disconnected.
3. Does the public hostname exist in the Dash? Compare exact string — typos
   in the subdomain are the most common cause.

Note: health probes inside the pod still run independent of the tunnel, so a
pod "Healthy" but 1033 means the gateway/hostname chain, not the workload.

## 4. Don't touch

- There is no longer a `deploy/cloudflared/` folder to edit.
- Don't recreate `config.yml.tmpl` — Zero Trust config is dashboard-only.
