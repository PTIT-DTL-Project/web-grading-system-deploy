# Plan: Fix remaining Pullfrog review findings on Vercel/README/.env

## Context

Pullfrog's latest review (after vercel.json was updated) identified three remaining issues in the deployment/docs delta:

1. **vercel.json** — `/api/:path*` rewrite has no cache-control headers. Vercel's CDN does not key on `X-User-Id`, so the first cacheable response from the gateway gets replayed to every later visitor.
2. **.env.development** — committed default is the tunnel URL, contradicting the comment above it. The tunnel is only for contributors without a local gateway. `.env.development` only affects Vite dev; Vercel uses the hardcoded `vercel.json` rewrite.
3. **README.md** — three issues: wrong path (`web-grading-system-fe` vs `frontend-src/web-grading-system-fe`), tunnel misdescription ("Cloudflare Zero Trust tunnel" for a `*.dpdns.org` hostname), and deployment listed as "out of scope" despite this PR introducing Vercel deployment.

---

## Tasks

### 1. Add cache-busting headers to `vercel.json`

**File:** `frontend-src/web-grading-system-fe/vercel.json`

Add a `headers` array to the `/api/:path*` rewrite rule:

```json
{
  "outputDirectory": "dist",
  "rewrites": [
    {
      "source": "/api/:path*",
      "destination": "https://web-dev1-api.vucongtuanduong.dpdns.org/api/:path*",
      "headers": [
        { "key": "x-vercel-enable-rewrite-caching", "value": "0" },
        { "key": "Cache-Control", "value": "no-store" },
        { "key": "CDN-Cache-Control", "value": "no-store" }
      ]
    },
    { "source": "/(.*)", "destination": "/index.html" }
  ]
}
```

This ensures the API responses are never cached at Vercel's edge, regardless of what the gateway's `Cache-Control` header says.

---

### 2. Fix `.env.development` default

**File:** `frontend-src/web-grading-system-fe/.env.development`

The committed default should be the local NodePort (`http://localhost:30195`), because:
- `.env.development` is read by the Vite dev server only
- A fresh clone with no local gateway should see the local default, not a third-party tunnel
- Contributors who need the tunnel can uncomment that line or use `.env.development.local`

Current (wrong):
```
# Local dev (default — uncomment this line and comment the tunnel line below):
# VITE_API_PROXY_TARGET=http://localhost:30195     # Traefik NodePort (this machine)
# Public tunnel (used by Vercel preview/deploy via vercel.json rewrite):
VITE_API_PROXY_TARGET=https://web-dev1-api.vucongtuanduong.dpdns.org
# Gateway booted locally:
# VITE_API_PROXY_TARGET=http://localhost:8080
```

New:
```
# Local dev (default — uncomment if you need to override):
VITE_API_PROXY_TARGET=http://localhost:30195     # Traefik NodePort (this machine)
# Public tunnel (for contributors without a local gateway):
# VITE_API_PROXY_TARGET=https://web-dev1-api.vucongtuanduong.dpdns.org
# Gateway booted locally:
# VITE_API_PROXY_TARGET=http://localhost:8080
```

Remove the misleading "Vercel preview/deploy via vercel.json rewrite" comment — `.env.development` is not read by Vercel.

---

### 3. Fix README.md

**File:** `frontend-src/web-grading-system-fe/README.md`

Three fixes:

**a. Path correction** — every `cd frontend-src/web-grading-system-fe` reference is correct; the README already uses it on line 12. The Pullfrog comment says the app is at `web-grading-system-fe/` — verify the actual path. If the app lives at `frontend-src/web-grading-system-fe/`, keep the current README paths.

**b. Tunnel description** — `*.dpdns.org` is a DDNS domain, not the tunnel itself. The tunnel is Cloudflare Zero Trust; the hostname is the public address that points through it. Reword the Vercel deployment section:

```markdown
- `vercel.json` declares `outputDirectory: "dist"` and two rewrites:
  - `/api/:path*` → `https://web-dev1-api.vucongtuanduong.dpdns.org/api/:path*`
    (public hostname routed through the Cloudflare Zero Trust tunnel → Traefik gateway)
  - `/(.*)` → `/index.html` (SPA fallback for `createBrowserRouter`)
```

**c. Status table** — replace "deployment (Dockerfile/CI/Helm/ArgoCD)" out-of-scope row with a Vercel deployment row:

```markdown
| 6 | Vercel frontend deployment + CDN cache hardening | **done** |
| 7 | Hardening + docs | pending |
```

And update the out-of-scope line to remove deployment:
```
Out of scope for now: assignment/plan authoring, submissions + results, Docker image
library, Keycloak.
```

---

## Out of scope

- The 16 open Pullfrog threads from earlier reviews (theme tokens, FilterBar i18n, ListPage error handling, useList filter reset, duplicate JSON keys, etc.) — those belong to the frontend PR and are not addressed by this deployment/docs delta.
- Backend authorization architecture (`X-User-Id` is client-asserted) — product decision, not a code fix.
