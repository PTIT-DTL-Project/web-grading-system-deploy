# Keycloak Reference — realm `ptit-wgs`

> Auto-generated 2026-10-04 from live realm + runbook. Not a substitute for the
> runbook — this is the **quick-lookup** for client IDs, secrets, URIs, and
> admin-API recipes.

---

## Keys

| Item | Value |
|---|---|
| Realm | `ptit-wgs` |
| Keycloak host | `https://web-dev1-keycloak.vucongtuanduong.dpdns.org` |
| Admin Console (realm `ptit-wgs`, bypass master landing) | `https://web-dev1-keycloak.vucongtuanduong.dpdns.org/admin/ptit-wgs/console/` — log in with the realm `admin` user (granted `realm-management` `manage-users` + `view-users`, 2026-10-10); FE import stays for routine bulk ops, console for ad-hoc management |
| Issuer | `https://web-dev1-keycloak.vucongtuanduong.dpdns.org/realms/ptit-wgs` |
| Admin user | `admin` (from `.env` `KEYCLOAK_ADMIN_USERNAME`) |

---

## Clients

| Client | Type | Direct Grants | Standard Flow | Purpose |
|---|---|---|---|---|
| `web-grading-fe` | public | **OFF** (since 2026-10-03) | ON | SPA — PKCE S256 |
| `wgs-password-verify` | confidential | **ON** | OFF | Gateway ROPC grant |
| `wgs-user-service` | confidential (service account) | — | — | Admin API (lookup/reset) |

### `web-grading-fe` — URIs

| Attribute | Values |
|---|---|
| `redirectUris` | `http://localhost:5173/*`, `https://web-dev1-fe.vucongtuanduong.dpdns.org/*` |
| `webOrigins` | `http://localhost:5173`, `https://web-dev1-fe.vucongtuanduong.dpdns.org` |
| `post.logout.redirect.uris` | `http://localhost:5173/* ## https://web-dev1-fe.vucongtuanduong.dpdns.org/*` |
| `pkce.code.challenge.method` | `S256` |

### `wgs-password-verify` — secret

- Lives in K8s Secret `keycloak-admin-client` → env `KEYCLOAK_PASSWORD_CLIENT_SECRET`
- **Never in git or FE bundle**
- Blank secret → no `client_secret` on wire → `unauthorized_client` → 502 (fail-loud)

---

## Env vars (gateway)

| Var | Default | Source |
|---|---|---|
| `KEYCLOAK_ISSUER_URI` | `https://web-dev1-keycloak.vucongtuanduong.dpdns.org/realms/ptit-wgs` | K8s Secret / `.env` |
| `KEYCLOAK_ADMIN_CLIENT_ID` | `wgs-user-service` | K8s Secret |
| `KEYCLOAK_ADMIN_CLIENT_SECRET` | *(blank)* | K8s Secret `keycloak-admin-client` |
| `KEYCLOAK_PASSWORD_CLIENT_ID` | `wgs-password-verify` | K8s Secret |
| `KEYCLOAK_PASSWORD_CLIENT_SECRET` | *(blank)* | K8s Secret `keycloak-admin-client` |
| `RATE_LIMIT_ENABLED` | `false` | env / Helm value |

---

## Admin API recipe

```bash
BASE="https://web-dev1-keycloak.vucongtuanduong.dpdns.org"

# 1. Admin token
AT=$(curl -s -X POST \
  "$BASE/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=admin" \
  -d "password=<admin-password>" \
  -d "grant_type=password" | jq -r .access_token)

# 2. Client ID from clientId
CID=$(curl -s -H "Authorization: Bearer $AT" \
  "$BASE/admin/realms/ptit-wgs/clients?clientId=web-grading-fe" \
  | jq -r '.[0].id')

# 3. GET full client → mutate → PUT full client (FULL REPLACE — never partial)
curl -s -H "Authorization: Bearer $AT" \
  "$BASE/admin/realms/ptit-wgs/clients/$CID" > /tmp/client.json
# ... edit /tmp/client.json ...
curl -s -X PUT -H "Authorization: Bearer $AT" -H "Content-Type: application/json" \
  --data-binary @/tmp/client.json \
  "$BASE/admin/realms/ptit-wgs/clients/$CID"
```

---

## Gotchas

- **`PUT /admin/realms/{realm}` = full replace** — always GET → mutate → PUT
- **`post.logout.redirect.uris` format**: single string in GET/PUT (not JSON array);
  multiple values joined with **`##`** (KC `CFG_DELIMITER`), NOT comma/space — a
  comma-joined value parses as one garbage entry → logout **400 "Invalid redirect
  uri"** (verified fixed 2026-10-04; probe: registered uri → 302, unregistered → 400)
- **Ordering**: create `wgs-password-verify` → deploy gateway → **then** disable direct grants on `web-grading-fe`
- **Brute force**: `bruteForceProtected=true` is set via admin API (not in export)
- **Realm export** (`src-services/keycloak/realm-export.json`) does NOT contain `web-grading-fe` or `wgs-password-verify` — re-export after any client change