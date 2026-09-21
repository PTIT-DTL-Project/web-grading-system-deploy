# Project Rules

Web grading system: Java microservices under `src-services/`, k3s deploy config under `deploy/`,
Helm charts repo checked out at `config-services/`.

## Convention maintenance (mandatory)

When the user gives requirements, standards, or corrections, and the work succeeds:

1. After implementing AND verifying, update the matching skill file under
   `.opencode/skills/`:
   - Java backend patterns → `java-spring-boot-backend/SKILL.md`
   - A different domain (deploy scripts, frontend, DB, ...) → create
     `.opencode/skills/<topic>/SKILL.md` with proper frontmatter
     (`name` = folder name, lowercase-hyphenated; `description` front-loads trigger keywords)
2. Record only durable conventions: patterns, decisions, gotchas, exact commands.
   Never one-off task details.
   - Postman + real-response duty for new endpoints → `java-spring-boot-backend/SKILL.md` §12.5.
3. If the new convention contradicts an existing skill section, rewrite that
   section — stale rules are worse than missing ones.
4. Do this silently as part of finishing the task; mention it in one line max.

## Use-case flow documentation (mandatory)

Every time you add or change an endpoint/API (or anything client-facing):

1. First imagine the FULL use-case flow it belongs to end-to-end: who calls what,
   in which order, preconditions, and expected result at each step.
2. Write/update that flow in `docs/design/usecase-flows.md` (create the file if
   missing): one section per use case, with numbered steps (method + path +
   body example), preconditions, and expected responses.
3. If an existing endpoint changes (renamed, moved, new validation, new step),
   update its flow section in the same task — stale flows are worse than none.
4. Quick per-service test recipes may also live in `src-services/README.md`,
   but the canonical flow doc is `docs/design/usecase-flows.md`.

Example of the expected format: the Classes & Scores flow in `src-services/README.md`
(create → import → score-components → scores → transcript).

## Configuration must use @ConfigurationProperties, not @Value

NEVER use `@Value` for configuration properties. Group all related
settings into a `@ConfigurationProperties` record in `config/`.

- The only exception is framework-internal properties (e.g.
  `@Value("${spring.application.name}")` inside Logstash encoder
  config). Everything business-related goes in a record.
- Records are registered via `@ConfigurationPropertiesScan` on the
  application class. Env overrides stay in `application.yaml` placeholders.
- Inject the properties record (constructor/final field), never re-declare
  the same `@Value` fields in multiple classes — one source of truth.
- Canonical example: `submission-service/config/RustFsProperties.java`,
  `config/SubmissionProperties.java`.

## Coding convention: no all-args positional constructors (mandatory)

When a record constructor call has more than 2 positional arguments,
do NOT write `new X(a, b, c, d...)`. Use Lombok `@Builder` and the
builder pattern (`X.builder().field(val)...build()`), or a `static X of(Entity)`
named factory method on the DTO when no entity import is needed
(to avoid circular dependency). The factory approach yields readable
`.map(X::of)` at call sites; the builder approach is used inline
when a factory would need an entity import. Triggers at >2 positional
args — 1-2 arg constructors are fine as-is. See `java-spring-boot-backend/SKILL.md` §§12.6–12.7.

## Code comments for future review (mandatory)

When fixing bugs or implementing features that address review feedback:

1. Add an inline comment above each fix explaining WHY (not what it does).
2. Include the review date and reviewer reference (e.g. `Review: 2026-09-20, Pullfrog PR #16`).
3. Comment the reasoning for non-obvious decisions (e.g. why a fallback is needed, why a check is ordered a certain way).
4. Purpose: future code reviewers can understand the historical context without reading the PR.
5. Do NOT over-comment — one comment per logical block, not per line.

## Comment accuracy (mandatory)

Whenever code is edited that affects behavior, ALL associated comments must be updated to match the new code. A comment describing old behavior is worse than no comment — it actively misleads readers. This applies to:
- Javadoc/block comments on methods whose implementation changed
- Inline comments explaining logic that was modified
- Review attribution comments if the fix scope changed
Never leave a comment that no longer describes what the code actually does.
