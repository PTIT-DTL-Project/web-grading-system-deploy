# Appendix — DB-read policy (binding) + smallest safe experiment

## DB-read policy

Chatbot reads user-scoped data **only via APIs**, never direct DB:

| # | Risk in this system |
|---|---|
| 1 | Prompt injection via DB-stored student content (descriptions, zips, logs, errors) |
| 2 | PII / cross-tenant leakage (4 DBs hold user ids, emails, scores; one missing `WHERE owner` leaks) |
| 3 | Authz bypass (JWT → roles → owner checks sidestepped by a DB role) |
| 4 | Stale derived scores (is_latest/scope/max-per-plan/skip-exclusion reimplemented wrong) |
| 5 | Write hazards (bad config JSONB, unique-index violations, Flyway breakage) |
| 6 | Cleartext secrets (DB passwords, tokens in bodies) echoed by the model |

DB reads allowed only for offline, one-time ingestion of **curated non-PII**
sources (the 4 design docs + anonymized golden configs) into `vector_store`,
or read-only replica with column allowlist + ownership predicate + JWT identity.

## Smallest safe experiment (before/while B1)

1. Template-only explainer + Drawer, validated on 2 real submissions.
2. Agent dry-run local (Ollama `qwen2.5:7b`, 3 read-only tools, static docs):
   prompt "create step POST /api/v1/books expect 201 + extract bookId" →
   draft must POST 201 through the real API first try. Tool accuracy <80% →
   fix tools/prompts before RAG/hosted models.
