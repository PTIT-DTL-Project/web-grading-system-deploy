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

## Coding convention: no all-args positional constructors (mandatory)

When a record constructor call has more than 2 positional arguments,
do NOT write `new X(a, b, c, d...)`. Use Lombok `@Builder` and the
builder pattern (`X.builder().field(val)...build()`), or a `static X of(Entity)`
named factory method on the DTO when no entity import is needed
(to avoid circular dependency). The factory approach yields readable
`.map(X::of)` at call sites; the builder approach is used inline
when a factory would need an entity import. Triggers at >2 positional
args — 1-2 arg constructors are fine as-is. See `java-spring-boot-backend/SKILL.md` §§12.6–12.7.
