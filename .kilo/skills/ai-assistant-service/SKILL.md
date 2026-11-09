---
name: ai-assistant-service
description: AI assistant service (agent chat) conventions for ai-assistant-service - use when editing ContextBuilder system prompts (SYSTEM_TEMPLATE), student/lecturer agent tools in DomainToolConfiguration, student deep links (frontend routes) in chat replies, or when agent chat fails with "Not all variables were replaced". Covers StringTemplate brace escaping in SystemPromptTemplate, deep-link routes matching the FE router role guards, and prompt-vs-config source of truth.
---

# AI assistant service (agent chat) conventions

Service: `src-services/ai-assistant-service` (port 8086). Agent chat path:
`AgentOrchestrator.executeRun` → `ContextBuilder.buildSystemPrompt` → `AgentRuntime` → `LlmClient`.

## 1. ContextBuilder.SYSTEM_TEMPLATE is a StringTemplate — escape literal braces

`buildSystemPrompt` renders `SYSTEM_TEMPLATE` through Spring AI `SystemPromptTemplate`
(Spring AI 2.0 = StringTemplate with `{`/`}` delimiters). Every `{name}` is a variable
reference, and the render map only holds `role`, `planSection`, `catalogSection`,
`taskSection`. Any other `{name}` in the template makes `render(...)` throw

```
IllegalStateException: Not all variables were replaced in the template.
Missing variable names are: [<names>]
```

`AgentOrchestrator` catches that into a FAILED run whose only user-visible reply is the
generic "Đã xảy ra lỗi khi xử lý yêu cầu" — i.e. every agent chat message fails, both roles.

Rule: literal brace text (e.g. route templates like `/student/assignments/{assignmentId}`)
must be escaped in the Java text block as `\\{...}` (Java `\\{` → template `\{` → literal
`{`). Regression guard: `ContextBuilderTest.studentPromptRendersLiteralDeepLinkRoutes`.

Verify: `cd src-services/ai-assistant-service && ./mvnw -o test -Dtest='ContextBuilderTest,AgentRuntimeTest'`.

## 2. Student deep links must mirror the FE router role guards

The prompt tells students to click markdown links; the route must match
`frontend-src/web-grading-system-fe/src/app/router.tsx`. A route behind a different
`RequireRole` fails closed to `/no-role`. Verified student routes:

- List assignments: `/student/assignments`
- Assignment detail: `/student/assignments/{assignmentId}` (`?submit=1` opens the submit
  modal — `StudentAssignmentDetailPage` reads the param and strips it)
- Practice list: `/student/practice`; practice detail: `/student/practice/{assignmentId}`
- Submissions list: `/student/submissions`
- Submission results: `/student/submissions/{submissionId}/results`

`/practice/:assignmentId` is LECTURER-only (`PracticePage`) — never link students there.
Links are relative (no domain); the FE renders assistant markdown links with
`target="_blank" rel="noopener noreferrer"` (`AssistantMessage.tsx`).

## 3. Frontend routes live in the prompt — not duplicated as backend config

`ContextBuilder.SYSTEM_TEMPLATE` is the single source for student routes. Do not add
`app.frontend.*`-style config unless a Java reader exists (`@ConfigurationProperties` record
+ env wiring in `config-services/ai-assistant-service/templates/deployment.yaml`).
The dead `app.frontend.base-url`/`routes` entries in `application.yaml` and
`values-stg.yaml` were removed (2026-11-02) — nothing read them.

## 4. Agent tools

Tools are `@Bean AgentTool` methods in `config/DomainToolConfiguration.java`; `ToolRegistry`
auto-registers every bean, so there is no list to update. Student result tools use the
result-service RestClient (`feign.result-service.url` / `RESULT_SERVICE_URI`, already wired):
`getMyAssignmentResults` → `GET /api/v1/results/student/assignment/{assignmentId}`,
`getMySubmissionResults` → `GET /api/v1/results/{submissionId}`.

## 5. Test plan capabilities & validation (single source of truth)
- `StepConfigValidator` in course-service is the source of truth for step config schemas/capabilities.
- Internal endpoints: `GET /api/v1/internal/test-plans/capabilities`, `POST /api/v1/internal/test-plans/validate-step` (`{stepType, config}`), `POST /api/v1/internal/test-plans/validate` (plan+steps), `GET /api/v1/internal/assignments/{id}/config-schema?type=`.
- Agent tools: `getTestStepCapabilities` (calls capabilities endpoint), `getStepConfigSchema` (calls config-schema by type). Replace bespoke static tool classes with DomainApiTool beans.
- `DomainApiTool.validateStepPayloads`: `createTestQuestion`/`createTestStep` validated via validate endpoints; `updateTestStep` validated via `/validate-step` only if `config` present, and requires `stepType` when validating config; skip validation if no config.
- DB steps require `connection` with `database`, `username`, `password`. `auto_inject_headers` applies to subsequent steps only; negative auth steps must shield headers.


