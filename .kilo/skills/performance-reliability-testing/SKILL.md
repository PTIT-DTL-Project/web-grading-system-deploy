---
name: performance-reliability-testing
description: Staging performance and reliability testing conventions for k6 API load, grading smoke flows, database reconciliation, and guarded Kubernetes fault tests.
---

# Performance & Reliability Testing

- Keep read-only API load profiles separate from workflows that create real submissions or grading jobs. Restrict grading-flow automation to an explicitly identified staging smoke unless concurrent grading has been designed and approved.
- Before any load or fault run, verify the staging URL, Kubernetes context, namespace, test identity, assignment and storage access. Never point scripts at production or real-user data; guarded scripts must fail closed on production-like contexts and require explicit confirmation.
- Do not store passwords or bearer tokens in Git. Obtain access tokens through the approved OIDC/PKCE login flow; use separate test identities/tokens when virtual users need distinct ownership.
- Keycloak access tokens in this realm live about five minutes, shorter than a load/stress/grading run. Put `{access_token, refresh_token}` pairs in `TOKENS_FILE` so the k6 scripts renew mid-run, and run `scripts/check-tokens.sh` first; a run with any expired token fails with HTTP 401 and its numbers must be discarded, not reported as capacity. Every consumer of the token file (runner validation, k6 scripts, preflight check) must accept both a bare token string and an `{access_token, refresh_token}` object — update them together, or the runner rejects a valid file.
- Treat database reconciliation as read-only evidence across submission, grading-job and result state. A script's PASS label or row counts do not replace reviewing statuses, timestamps, soft-deleted rows and service logs. Standalone scripts under `scripts/` should load the package-local `.env` themselves (without tracing secrets), matching the main runner.
- Match Kubernetes Deployment names to the actual Helm release/ArgoCD application before fault injection; document immediate recovery steps for every disruptive action.
- Report measured outcomes only after a real run. Clearly distinguish script validation from staging measurements and state any instrumentation or concurrency limits that constrain conclusions. For k6 summaries, handle both direct metric fields and nested `values` objects, including rate metrics stored under `value`; verify report numbers against the saved summary before accepting a run report.
- For automated test runs, keep raw k6 JSON, summaries, logs, run metadata and a human-readable report together in a unique per-run directory. Protect result files because they may contain test identifiers or temporary upload URLs; never store tokens or database credentials in the report.
- Keep destructive/fault tests opt-in with explicit staging/context checks and interactive confirmation; do not let enabling a generic test runner silently delete Pods or stop services.
