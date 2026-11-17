---
name: performance-reliability-testing
description: Staging performance and reliability testing conventions for k6 API load, grading smoke flows, database reconciliation, and guarded Kubernetes fault tests.
---

# Performance & Reliability Testing

- Keep read-only API load profiles separate from workflows that create real submissions or grading jobs. Restrict grading-flow automation to an explicitly identified staging smoke unless concurrent grading has been designed and approved.
- Before any load or fault run, verify the staging URL, Kubernetes context, namespace, test identity, assignment and storage access. Never point scripts at production or real-user data; guarded scripts must fail closed on production-like contexts and require explicit confirmation.
- Do not store passwords or bearer tokens in Git. Obtain access tokens through the approved OIDC/PKCE login flow; use separate test identities/tokens when virtual users need distinct ownership.
- Treat database reconciliation as read-only evidence across submission, grading-job and result state. A script's PASS label or row counts do not replace reviewing statuses, timestamps, soft-deleted rows and service logs.
- Match Kubernetes Deployment names to the actual Helm release/ArgoCD application before fault injection; document immediate recovery steps for every disruptive action.
- Report measured outcomes only after a real run. Clearly distinguish script validation from staging measurements and state any instrumentation or concurrency limits that constrain conclusions.
