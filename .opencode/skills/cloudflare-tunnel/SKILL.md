---
name: cloudflare-tunnel
description: Cloudflare Tunnel (cloudflared) setup and troubleshooting for exposing this project's k3s services via *.vucongtuanduong.dpdns.org hostnames. Use when a tunnel hostname shows Cloudflare Error 1033, when running deploy/cloudflared/setup-tunnel.sh or its docker-compose, editing config.yml.tmpl, or when external URLs fail while the cluster itself is healthy.
---

# Cloudflare Tunnel (host docker-compose)

The tunnel runs on the HOST via `deploy/cloudflared/docker-compose.yml`
(`network_mode: host`), NOT as a Kubernetes pod. `kubectl get pods -A | grep
cloudflared` finding nothing is EXPECTED — check `docker ps` instead.

Traffic path: internet → Cloudflare edge → tunnel → cloudflared container →
`http://localhost:<GATEWAY_PORT>` (Traefik NodePort, default 30195 from `.env`)
→ Traefik ingress → service.

## 1. Hostnames

Pattern: `web-dev{N}-<sub>.vucongtuanduong.dpdns.org` (dev1/dev2 per
branch/user). Subs: api, assignment, submission, grading, result, notification,
argocd, keycloak, rustfs, grafana, otlp, pyroscope.

## 2. Setup flow

```bash
deploy/cloudflared/setup-tunnel.sh [domain] [tunnel-name] [port]
```

It: creates tunnel if missing → extracts TUNNEL_ID → renders `config.yml.tmpl`
into `~/.cloudflared/config.yml` (substitutes TUNNEL_ID + GATEWAY_PORT) → runs
`cloudflared tunnel route dns` for every subdomain. Start it with
`docker compose -f deploy/cloudflared/docker-compose.yml up -d` (or `start.sh`).

## 3. Two traps that cause Error 1033

Both bit us on 2026-08-17. If a tunnel URL returns Cloudflare Error 1033, the
edge can't reach cloudflared — it's almost always one of these.

### Trap A: stale repo config.yml overrides the generated one

docker-compose mounts BOTH:
- `~/.cloudflared:/etc/cloudflared` (whole dir)
- `./config.yml:/etc/cloudflared/config.yml:ro` ← **this file WINS**

So the repo copy `deploy/cloudflared/config.yml` is what the container reads,
NOT the freshly rendered `~/.cloudflared/config.yml`. After every
setup-tunnel.sh run:

```bash
cp ~/.cloudflared/config.yml deploy/cloudflared/config.yml
```

Symptom of staleness: logs show `error parsing tunnel ID: Can't read origin
cert...` even though cert.pem exists — because an old config references the
tunnel by NAME (needs cert.pem lookup) plus a credentials-file JSON that no
longer exists. Fresh configs use the tunnel UUID directly.

### Trap B: cert.pem unreadable by the container user

`cloudflare/cloudflared:latest` runs as uid 65532. `~/.cloudflared/cert.pem`
from `cloudflared login` is mode 600 owned by uid 1000 → unreadable → crash
loop. Fix once:

```bash
chmod 644 ~/.cloudflared/cert.pem ~/.cloudflared/<TUNNEL_ID>.json
```

## 4. Error 1033 diagnosis chain (in order)

```bash
curl -sI https://web-dev1-api.vucongtuanduong.dpdns.org   # 1033 = tunnel down
docker ps | grep cloudflared                              # Restarting? crash loop
docker logs cloudflared-web-dev1 --tail 30                # read root cause
# fix per trap A or B above, then:
docker restart cloudflared-web-dev1
docker logs -f cloudflared-web-dev1                       # want: "Registered tunnel connection" x4
curl -sI https://web-dev1-api.vucongtuanduong.dpdns.org   # expect app-level status (404/200), NOT 1033
```

Success looks like four `Registered tunnel connection` lines (hkg locations,
protocol http2). An HTTP 404/503 after that is an APP/ingress problem, not a
tunnel problem — check Traefik ingress hosts match the hostname.

## 5. Rules

- NEVER edit `~/.cloudflared/config.yml` directly for persistent changes — edit
  `config.yml.tmpl`, re-run setup-tunnel.sh, then re-copy to the repo dir.
- Tunnel name convention: `web-dev{N}-web-grading`.
- DNS route failures (`route dns`) are non-fatal in the script; verify CNAMEs
  `<TUNnel_ID>.cfargotunnel.com` exist at the DNS provider if a sub stays 1033.
