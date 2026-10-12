# Phase B2 — DETAIL: lecturer agentic assistant (after B1)

> Parent: `README.md` (master plan). Status: detailed, not started.
> Goal: a lecturer chats in Vietnamese, the agent reads docs, understands
> intent, and returns a **validated step draft** — never writing autonomously
> in v1 (human clicks Apply; the unchanged step APIs do the write).
> Depends on: B1 done (ExplanationBuilder patterns reused for rationale text).
> Stack facts verified: Boot 4.1.0 + Java 21 all services
> (`course-service/pom.xml:7-19`); Spring AI 2.0.x is the Boot-4-compatible
> line (re-verify exact BOM at execution against docs.spring.io).

## 1. Service scaffold (new `chatbot-service`, port 8085)

Mirror the smallest existing service layout (`result-service` as template):
`chatbot-service/` Maven module (parent Boot 4.1.0), packages
`.../chatbot/{controller,service,tools,retrieval,config}` + `dto/`.

1. **Dependencies** (additive only): `spring-ai-bom` import (2.0.x line) +
   `spring-ai-starter-model-ollama` (experiment profile) and/or
   `spring-ai-starter-model-openai` (OpenAI-compatible endpoint profile).
   No touch to grading dependencies of any service.
2. **Config** (project rule: `@ConfigurationProperties` record, never `@Value`):
   `ChatbotProperties(prefix="chatbot")` — `model.provider` (`ollama|openai`),
   `model.name`, `base-url`, `api-key` (env-only, K8s Secret at deploy),
   `max-tool-iterations: 5`, `retrieval.top-k: 4`. Local `application.yaml`
   defaults point at `http://localhost:11434`.
3. **Gateway**: one route block in `api-gateway/.../application.yaml`
   (copy the `course-service` block style):
   `- id: chatbot-service`, `uri: ${CHATBOT_SERVICE_URI:http://localhost:8085}`,
   `Path=/api/v1/chatbot/**`.
4. **Deploy**: Helm chart copy (copy `result-service` chart shape: deployment +
   values-stg with `CHATBOT_SERVICE_URI`-style env only where needed + model
   Secret refs). No DB for v1 (stateless + audit log to stdout/logstash;
   `vector_store` only if §5 triggers).

## 2. Tools (allowlist: read + validate only in v1)

`PlanDraftTools` (`@ToolCallback` methods, Spring AI `ToolCallingAdvisor`):
1. `listPlans(assignmentId)` → course-service internal plans (proves context +
   gives ids/weights/sequenceOrders for ordering new steps).
2. `getStepSchema(stepType)` → returns the per-type required/optional keys +
   quirks, generated FROM `StepConfigValidator` + `http-test-plan-config.md §3`
   (single source — add a `describeSchema(StepType)` static next to the
   validator in course-service, or duplicate the table in chatbot-service with
   a test asserting parity on key names; decide at execution by diff size).
3. `validateStepDraft(stepType, configJson)` → calls the real
   `StepConfigValidator.validateAndSerialize` (same class the write path uses
   — a draft passing here passes on Apply, by construction).
4. Caller identity: every tool forwards the request's `X-User-Id`/`X-User-Roles`
   (gateway-stamped) and runs `TestPlanService.requireOwnedAssignment`
   semantics first (`AssignmentRepository.findByIdAndOwnerId`, same 404 convention
   — unowned ids stay indistinguishable). No service-account shortcuts.

Explicitly NOT tools in v1: `createPlan/createStep/update/delete` (drafts only),
anything touching submissions/results/scores, anything writing DBs.

## 3. Prompt + retrieval (staged, pgvector last)

**System prompt v1 (static text, no vector store):**
- Role: Vietnamese-first assistant drafting grading steps; output schema
  (draft JSON + `rationale_vn` + `applyPreview`).
- Embedded knowledge (verbatim from verified sources):
  `http-test-plan-config.md §3` (schemas) + `§8` (8 mismatches:
  lowercase kinds, `/`-leading path, `${var}` not `{{}}`, unique orders,
  DELETE-drops-body, OPTIONS-runs-as-GET, no URL-encoding, EXTRACT/DELAY have
  no executors) + assertion/extract tables from `grading-config-reference.md`.
- Output contract: `{ planId?, steps[]: {stepType, name, config, expectedResult?,
  weight?, stepOrder?}, rationale_vn, warnings[] }` — JSON-schema-validated
  before return; invalid → single retry, then template error (never raw model
  text to FE).

**Staging rule:** ship static prompt first; run the §6 dry-run battery. Only if
recall demonstrably fails (wrong keys/quirks despite prompt) → add pgvector
(`CREATE EXTENSION vector` + `vector_store` migration + ingestion job over the
4 design docs + `DocsRetriever` top-k prepend). Never start with pgvector.

## 4. Guardrails (non-negotiable, each tested)

1. LECTURER role only (gateway `X-User-Roles`; service 403 otherwise).
2. Per-assignment ownership check before ANY tool runs (unowned → 404, same
   shape as `TestPlanService`).
3. Max 5 tool iterations → stop with partial draft + `warnings` (never loop).
4. Every returned draft re-validated by `StepConfigValidator` server-side
   (a draft failing here is a bug — log + 500, don't soften).
5. Secret masking in previews (reuse A4 `EvidenceRedactor` patterns:
   `password|authorization|secret|token` → `***`; connection blocks never
   echoed — drafts reference `connection.db_service` by name only).
6. Audit: log (lecturer id, assignment id, draft hash, tool calls) to stdout
   for logstash — no PII beyond ids.

## 5. FE (2 touches)

1. `features/assignments/ChatAssistantDrawer.tsx`: chat panel inside
   `TestPlanEditor` (FloatButton or side button next to "Add test case") —
   message list, input, draft preview cards with per-step Validate ✓/✗ marks
   (server returns validation per step), **Apply** button per draft calling the
   existing `POST .../plans/{planId}/steps` endpoint (unchanged path, lecturer's
   own token) + refetch plans.
2. `shared/api/endpoints/chatbot.ts`: `draftSteps(assignmentId, message, history?)`.
3. i18n keys for chrome only (`chat.*`: title, placeholder, apply, warnings) —
   draft content arrives in Vietnamese from BE.

## 6. Tests

- **Tool tests** (mocked Feign/validator): owner-check 404 before tools;
  `validateStepDraft` agrees with real create path (golden valid + golden
  invalid configs).
- **Schema tests**: malformed model output → retry-then-template-error; secret
  in model output → masked.
- **Dry-run battery (local Ollama, no key)**: scripted prompts —
  (a) "POST /api/v1/books expect 201 + extract bookId" → draft POSTs 201 first
  try; (b) "DB check users table has email column" → valid DB_SCHEMA_CHECK;
  (c) "delay 5s" → refusal with guidance (unsupported type). Tool accuracy
  <80% → fix tools/prompts, do NOT add RAG/hosted models yet.
- Existing suites green (no shared code touched).

## 7. Verify (manual, staging)

1. Lecturer chats in Vietnamese on a real assignment → draft validates →
   Apply → step runs and grades (end-to-end loop closed).
2. Unowned assignment id → 404 before any tool output.
3. Model Secret present only in K8s Secret/env — grep bundle + repo for leaks.

## 8. Explicitly out of scope (later versions)

- Autonomous POST/PUT (v2+: explicit per-draft confirm + audit table).
- Student-facing chat (B1 covers students; this route is LECTURER-only).
- pgvector/RAG (staged per §3), hosted-model profile (staged per battery),
  persisting drafts (stateless v1), B3 paraphrase coupling (independent flag).
