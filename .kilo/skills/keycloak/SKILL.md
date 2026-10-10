---
name: keycloak
description: Keycloak realm ptit-wgs conventions for this project - realm export, admin API (PUT realm = full replace), client scope sub/basic, brute force lockout, password policy, reset-password body, password grant required actions, service account roles, admin creds, token refresh/logout revoke, PKCE/S256 client config, direct access grants vs gateway password-verify client, redirectUris/webOrigins. Use when touching Keycloak realm config, clients, scopes, tokens, refresh, required actions, brute force, admin API calls, PKCE/login redirect, or debugging login/token/sub/forced-change-password issues.
---

# Keycloak conventions (realm `ptit-wgs`)

Evidence is repo paths or admin-API checks — do not trust memory for realm settings.
Plan that drove the Phase 1 changes:
`docs/design/keycloak-password-gateway-plan-2026-10-03-v1.md`.

## 1. Realm export + the full-replace trap

- Realm export lives at `src-services/keycloak/ptit-wgs-realm.json` (realm `ptit-wgs`).
  Verified facts in it: `loginWithEmailAllowed: true`, `accessTokenLifespan: 300`,
  `ssoSessionMaxLifespan: 36000` (refresh token can live 10 h).
- **`PUT /admin/realms/{realm}` is a FULL REPLACE.** Always: `GET` the realm → mutate
  the one field → `PUT` the whole body back. A partial/detached body silently wipes every
  other realm setting (brute force, SMTP, themes, …).
- The export contains only `wgs-postman` and `wgs-user-service` — **`web-grading-fe` is
  NOT in it** (created by hand in the live realm; `frontend-keycloak-login.md` §3), and
  neither is **`wgs-password-verify`** (created live 2026-10-03, §10) → re-export (§10.7)
  before trusting it as a mirror.
  Re-importing the export does not recreate it.

## 2. `sub` claim lives in the `basic` client scope (Keycloak >= 24)

- The `sub` protocol mapper ships inside the `basic` client scope. A client with only
  `['web-origins','roles','profile','email']` issues user tokens **without `sub`** → the
  gateway's `AuthenticationContextFilter` stamps an empty `X-User-Id` → downstream 400,
  while the token itself still decodes fine (misleading).
- Fixed 2026-10-02 for `web-grading-fe`, `wgs-postman`, `wgs-user-service` by adding
  `basic` to `defaultClientScopes` (the two exportable clients now carry `"basic"` in
  `ptit-wgs-realm.json`; `web-grading-fe` only in the live realm).
- Verify: fresh password-grant token has `sub` = user UUID; or
  `POST .../token -d '...&scope=basic'` → `invalid_scope` means the scope is missing.
- Note `client_credentials` tokens always carried `sub` — only user tokens broke, so do
  not test this with a service-account token.

## 3. Brute force lockout (Phase 1 release, 2026-10-03)

- Config to have in the **live** realm: `bruteForceProtected: true`, `failureFactor: 30`,
  `permanentLockout: false`, `maxFailureWaitSeconds: 900`. Verify before trusting it —
  `GET /admin/realms/ptit-wgs | grep bruteForce` (the change is applied via the admin
  API, cluster-side; as of 2026-10-03 the cluster was down, so confirm rather than assume —
  **confirmed `bruteForceProtected: true` live 2026-10-04**).
- With `permanentLockout: false` a lock is **temporary (~15 min wait)**; 30 wrong
  passwords on one account locks that victim — accepted trade-off, documented in the
  plan §6.1. **E2E tests that guess passwords can lock `lecturer_test`** → wait it out or
  reset the password via the admin API.
- Recipe (remember rule 1 — full replace):

  ```bash
  KC="https://web-dev1-keycloak.vucongtuanduong.dpdns.org"   # + REALM=ptit-wgs, AT=admin token
  curl -s -H "Authorization: Bearer $AT" "$KC/admin/realms/$REALM" > /tmp/realm.json
  python3 - <<'EOF'
  import json
  r = json.load(open('/tmp/realm.json'))
  r['bruteForceProtected'] = True      # failureFactor/permanentLockout keep their values
  json.dump(r, open('/tmp/realm.json','w'))
  EOF
  curl -s -X PUT "$KC/admin/realms/$REALM" -H "Authorization: Bearer $AT" \
       -H "Content-Type: application/json" --data-binary @/tmp/realm.json -o /dev/null -w '%{http_code}\n'
  # 204 expected; never send a hand-built partial body.
  ```

- The export file does **not** carry `bruteForceProtected` (Keycloak default = off) —
  it is set only in the live realm via the recipe above.

## 4. Password reset & forced-change semantics

- **Reset body is FLAT**: `{"type":"password","value":"<new>","temporary":false}` on
  `PUT /admin/realms/{realm}/users/{id}/reset-password`. Wrapping it in a `credential`
  object returns 400 (both the old FE code and the gateway follow this).
- **Password grant against a user with required action `UPDATE_PASSWORD` returns
  `invalid_grant` + `error_description: "Account is not fully set up"` — that means
  "password correct, forced change pending", NOT "wrong password".** The gateway's
  change-password endpoint treats it as a successful current-password verification.
- **The same marker fires for a user created with NO email** (live-verified 2026-10-04:
  `emailVerified: true` but no `email` field → correct password answers
  `Account is not fully set up`, `requiredActions` shows `[]`; a `PUT …/users/{id}`
  adding the email flips the very next grant to 200). Wrong password still answers
  `Invalid user credentials`, so verification semantics hold either way — but **probe
  users for captures/tests must be given an email**, or every correct-password attempt
  looks like a pending required action.
- **Wrong credentials answer `401` + `invalid_grant` / `"Invalid user credentials"`, NOT
  400** (live-verified 2026-10-03 against Keycloak 26.8). Code that only accepts 400 maps
  every wrong-password case to `identity_provider_unavailable` (502). Accept 400 **and**
  401, but only when the body still carries `invalid_grant`/`Invalid user credentials` —
  `invalid_client` / `unauthorized_client` must stay provider trouble.
- Login accepts email as username (`loginWithEmailAllowed: true`), but the **admin** search
  keeps `username` and `email` in two separate query parameters. Choose the parameter from
  the shape of the identifier (`@` → `?email=`, otherwise `?username=`) and treat an empty
  result as "not found". Sending only one keeps the account resolved in this step identical
  to the one the password grant authenticated.
- The admin search is a **"starts with"** query — never take `users[0]`. Filter the returned
  rows for an exact (case-insensitive) match on the same field, otherwise an account that
  merely shares the prefix gets its password reset with credentials that were only ever
  verified against the caller's own.
- User lookup must come **after** the password verification, otherwise an
  unauthenticated caller gets a user-enumeration oracle (both failures answer the same
  `current_password_invalid`).

## 5. Service accounts & secrets

- `wgs-user-service` (confidential, `serviceAccountsEnabled: true`) service-account
  roles: `manage-users, view-users, query-users, query-groups, create-client`
  (plan R2; `manage-users` is what allows `reset-password` — 403 without it).
  Bulk import additionally needs **`view-realm`** on the service account:
  `GET /admin/realms/{realm}/roles/{name}` answers 403 without it (hit
  2026-10-10; user search + create/reset kept working, only role lookup failed).
- **User creation must always send `lastName`.** Keycloak 26's default user
  profile requires it; an account created with only `firstName` stalls on the
  "Update Account Information" wall right after login (hit 2026-10-10 — new
  lecturers and students alike; pre-existing accounts were unaffected).
  Backend splits Vietnamese `fullName` (first token = family name → `lastName`,
  rest → `firstName`); blank falls back to the username, never a reject.
- **Bulk import lowercases usernames.** Keycloak stores the username lowercased
  but keeps the initial password verbatim — importing `B22DCCN001` as-is minted
  user `b22dccn001` with password `B22DCCN001`, unguessable (hit 2026-10-10).
  Normalize (`trim().toLowerCase(ROOT)`) once at CSV parse so lookup, creation
  and password all use the stored form.
- **Its client secret must NEVER appear in frontend code** — Phase 1 (2026-10-03) moved
  the password-change call into api-gateway; the secret lives only in the K8s Secret
  `keycloak-admin-client` (created by `deploy/setup-namespace.sh`, fail-loud if unset)
  and the FE's `VITE_KEYCLOAK_ADMIN_*` vars are gone.
- **Local run gotcha:** the gateway reads `KEYCLOAK_ADMIN_CLIENT_SECRET` from the process
  environment (blank default). Starting it from an IDE run config without that var makes
  `client_credentials` fail `401 unauthorized_client` → 502 on every case that reaches
  step 2 (user lookup/reset). Check `/proc/<pid>/environ` before suspecting Keycloak.
- The repo export's `"secret": "REVOKE-AND-SET-VIA-ADMIN"` is a **placeholder**, not a
  working credential; rotate the real secret after it ever shipped in a bundle (plan §6.6).
- Admin token: `POST {KC}/realms/master/protocol/openid-connect/token` with
  `client_id=admin-cli` (`frontend-keycloak-login.md` §3.2). For a **realm client's**
  `client_credentials` grant (e.g. `wgs-user-service`) the realm path is mandatory —
  `POST {KC}/realms/ptit-wgs/protocol/openid-connect/token`; omitting `/realms/{realm}`
  returns 404.

## 6. Admin console creds = accepted open risk (R8)

- Admin console login comes from `.env` keys `KEYCLOAK_ADMIN_USERNAME` /
  `KEYCLOAK_ADMIN_PASSWORD` (default `admin` — see the `keycloak-db` secret block in
  `deploy/setup-namespace.sh`). The default admin/admin pair is a **known, accepted-but-open
  risk (R8, Phase 2)** — do not "fix" it silently in a deploy task; changing it is a
  separate, coordinated change (update `.env` + secret `keycloak-db`).
- Never print or commit these values; reference key names only.

## 7. Logout must terminate the IdP session (full-page)

- Since 2026-10-03 (**D12 chốt**) FE logout calls
  `keycloak.logout({ redirectUri: <origin>/login })` → GET
  `{issuer}/protocol/openid-connect/logout?client_id&id_token_hint&post_logout_redirect_uri`
  → `location.replace`. The old XHR POST (`client_id` + `refresh_token`, fire-and-forget)
  is gone: it never cleared the browser SSO cookie, so the next `/login` bounced
  straight back into the app (no user switching).
- Realm requirement: client attribute `post.logout.redirect.uris` must include the app
  origin (`http://localhost:5173/*`), else Keycloak renders its own "logged out" page
  and never returns to the app.
- **Multivalued separator in `post.logout.redirect.uris` is `##`, NOT comma or space**
  (`Constants.CFG_DELIMITER = "##"`; KC 26.0 `AbstractClientConfigWrapper.getAttributeMultivalued`
  splits on `\s*##\s*`). Two origins:
  `http://localhost:5173/* ## https://web-dev1-fe.vucongtuanduong.dpdns.org/*`.
  A comma/space-joined value parses as ONE garbage entry that matches no URI →
  `GET …/openid-connect/logout?client_id=…&post_logout_redirect_uri=…` answers
  **400 "Invalid redirect uri"** (`LogoutEndpoint` → `RedirectUtils` null).
  Verified 2026-10-04: switching the separator to `##` turned that probe from 400 into
  `302 Location: <origin>/login`. Probe recipe (hint optional): registered uri →
  `302 Location: <uri>`, unregistered uri → `400` (negative control must stay 400).
- Session termination revokes the refresh token (runbook verify #9 still holds); an
  already-issued access token lives until `accessTokenLifespan` (300 s) expires.
- Do not call `keycloak.clearToken()` before building the logout URL — it drops
  `idToken`, leaving `id_token_hint` empty.

## 8. Gotchas when scripting the admin API

- Admin endpoint paths are relative to `{KC}` (the server base), e.g.
  `/admin/realms/ptit-wgs/...` — never prepend the realm issuer URL.
- `GET /clients/{id}/client-scopes` does not exist; use `/default-client-scopes` and
  `/optional-client-scopes`.
- When adding a default scope:
  `PUT /admin/realms/{realm}/clients/{cid}/default-client-scopes/{scopeId}` → expect 204.
- The change-password endpoint the gateway exposes is documented end-to-end in
  `docs/design/usecase-flows.md` (UC-14) and `docs/api/API-TEST-GUIDE.md` (§5).

## 9. Phase 2 hardening (chốt 2026-10-03): policy syntax, bootstrap admin, rotation

Plan: `.opencode/plan/keycloak-hardening-phase-2.md` (decisions D1–D6); runtime commands in
`docs/guide/PASSWORD-GATEWAY-RUNBOOK.md` §9. `Review: 2026-10-03, Phase 2 hardening (D1–D6).`

- **`passwordPolicy` syntax.** Separator is the literal **` and `** (spaces around `and`) —
  not a bare space, not `;`. Real provider IDs: `length`, `specialChars`, `upperCase`,
  `lowerCase`, `digits`, `notUsername`, `hashIterations`, `passwordHistory`. Chosen string
  (D2 + D6, strict):

  ```
  length(8) and specialChars(1) and upperCase(1) and digits(1) and notUsername
  ```

  Set via `kcadm.sh update realms/ptit-wgs -s 'passwordPolicy="<string>"'` or the
  GET → mutate → PUT recipe (rule 1, full replace). Source: Keycloak 26.8 Server Admin
  Guide, Admin CLI § *Setting a password policy*. Common draft mistake: inventing short
  names (e.g. `special`, `upper`) instead of the real IDs (`specialChars`, `upperCase`) —
  Keycloak rejects unknown providers.
- **Realm scoping — no admin lockout risk.** `passwordPolicy` is a **realm attribute**:
  set on `ptit-wgs` it does **not** touch the `admin` user, who lives in the `master`
  realm. Never claim it "applies to every user including admin" — that is false.
- **Not retroactive.** Keycloak docs: the policy *"will not be effective for existing
  users"* — existing passwords keep working until the user's next change. Enforcing
  existing users to rotate needs a required action (separate change, do not bundle).
- **`KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` are first-boot only.**
  Keycloak parses them **at first startup to create the initial user**; changing the env
  var + restarting the pod does **NOT** reset an existing `admin` password. Correct way:
  Admin Console → Master realm → Users → `admin` → Credentials → Set password (uncheck
  *Temporary*), then update `.env` `KEYCLOAK_ADMIN_PASSWORD` + `./deploy/setup-namespace.sh`.
- **Refresh rotation semantics.** `revokeRefreshToken: true` + `refreshTokenMaxReuse: 0`
  = refresh token is **one-time use**. Replaying a used token returns `400 invalid_grant`
  with `"Maximum allowed refresh token reuse exceeded"`. Two tabs refreshing the same RT
  concurrently → exactly one wins, the loser is kicked to `/login` — enable rotation **only
  after** the cross-tab refresh lock (Web Locks in `keycloak.ts`) is deployed and the
  2-tab × 10 protocol passes (runbook §9.6).
- **Caveat (UNVERIFIED):** whether Keycloak's **admin** reset-password endpoint
  (`PUT /admin/realms/{realm}/users/{id}/reset-password`) enforces the realm password
  policy is **not verified** — it is decided by the runtime probe (runbook §9.5): reset a
  password to `abcdefgh` after the policy is on → `400 weak_password` = enforced,
  `204` = bypass (only then add gateway-side validation). Do not assume either outcome
  and do not write gateway validation code before the probe decides (D5).
  **Still unresolved 2026-10-04: the live realm's `passwordPolicy` is `None`** (the
  Phase 2 policy was never applied to the live realm), so a weak new password answers
  `204` today and the gateway's `weak_password` branch is unreachable until the policy
  lands.

## 10. Phase 3 (2026-10-03): PKCE client config, direct grants, and the gateway's OWN client

Plan/decisions: `.opencode/plan/phase-3-pkce.md` (**D7–D12**) · runtime commands:
`docs/guide/PASSWORD-GATEWAY-RUNBOOK.md` **§10**.
`Review: 2026-10-03, Phase 3 PKCE plan (D7–D12).`

- **SPA client = PUBLIC + PKCE, never confidential.** `web-grading-fe` stays
  `publicClient: true` with `standardFlowEnabled: true` and PKCE S256 stored as the
  client **attribute** `pkce.code.challenge.method: "S256"` — `ClientRepresentation`
  has NO top-level `pkceMethod` field; a PUT body carrying one fails HTTP 400
  `Unrecognized field "pkceMethod"` (verified 2026-10-03). Same PUT also sets
  `post.logout.redirect.uris` (§7).
  A confidential client's secret would land in the browser bundle — that is exactly the
  R1/R2 leak Phase 1 removed (`VITE_KEYCLOAK_ADMIN_CLIENT_SECRET`). No client secret ever
  belongs to a browser; the pre-rewrite sketch in `frontend-keycloak-login.md` §7 proposed
  exactly the wrong thing (a dedicated confidential client for the SPA, invented name) —
  corrected 2026-10-03, do not revive it.
- **`redirectUris` / `webOrigins` gotcha:** list the exact origins —
  `redirectUris: ["http://localhost:5173/*"]`, `webOrigins: ["http://localhost:5173"]` —
  and **never `*`/`+` when credentials are involved**. The team hit a CORS failure on
  2026-10-01 (no ACAO without matching `webOrigins`). **Every deployed FE origin must be
  in THREE places: `redirectUris`, `webOrigins`, AND the client attribute
  `post.logout.redirect.uris`** (§7 — its multivalue separator is `##`) — missing
  `redirectUris` is not a silent problem:
  `GET …/protocol/openid-connect/auth` answers **400** for that origin, which kills
  `silent-check-sso` (console: 400 + a `frame-ancestors 'self'` CSP error, because the
  400 page carries that header inside the iframe) and makes `login()` show Keycloak's
  "Invalid parameter: redirect_uri" instead of the login form. Probe before/after with a
  plain authorize GET: registered → `302`/`200` (login page), unregistered → `400`.
  Origins so far: `http://localhost:5173` (dev) and
  `https://web-dev1-fe.vucongtuanduong.dpdns.org` (Vercel, added 2026-10-04). The live
  client is NOT in the realm export (§1) — these live-only entries vanish from any
  export/re-import unless re-added (runbook §10.8 checklist).
- **Direct Access Grants off on `web-grading-fe` breaks the gateway — that is why
  `wgs-password-verify` exists (D11).** Step 2 of `POST /api/v1/account/change-password` is
  a resource-owner-password grant; it used to run on `web-grading-fe`. Once
  `directAccessGrantsEnabled: false` on that client (**done 2026-10-03**, runbook §10.6 ✓),
  the gateway gets `unauthorized_client` → `502 identity_provider_unavailable` on every
  password change. The fix is client **`wgs-password-verify`**: confidential, Direct Access
  Grants **ON**, Standard Flow OFF, Service Accounts OFF — **CREATED live 2026-10-03**
  (§10.2 ✓, secret only in `.env` gitignored + K8s Secret, never in chat/git); id + secret
  via env `KEYCLOAK_PASSWORD_CLIENT_ID/SECRET` → K8s Secret `keycloak-admin-client` →
  `keycloak.admin.password-client-id/secret` (`KeycloakAdminProperties.passwordClientSecret`,
  form carries `client_secret` only when configured — **blank = 502 now**, the "old
  public-client" fallback is dead while fe direct grants are off).
- **Ordering constraint (runbook §10.2 → §10.6):** CREATE `wgs-password-verify`, put its
  secret in `.env`, `./deploy/setup-namespace.sh`, and DEPLOY the gateway **BEFORE**
  disabling direct grants on `web-grading-fe`. Never reverse it — the endpoint returns 502
  in between, and a `502` there always means "the env var was not wired" (check `.env` →
  secret → deployment env → pod). **Current state (2026-10-03): both steps done but in the
  "wrong" order on purpose** (user accepted the window): fe direct grants OFF while the
  cluster still runs old image → deployed change-password answers **502 until the backend
  MR deploys**; local gateway already has the pair and returns 400/204 (verified).
  `lecturer_test` password is `Dev2026!!` (reset 2026-10-03 — same-day change-password
  tests had silently changed it; a wrong-password answer on BOTH clients means the password
  moved, not the client config).
- **Realm export:** partial-export the live realm afterwards — the export in the repo does
  not contain `web-grading-fe` nor `wgs-password-verify` (§1), so it is not a faithful
  mirror; strip every client's `secret` field before committing, and check `wgs-postman`
  (`redirectUris: ["*"]`, direct ON) is still used before keeping it that permissive.
