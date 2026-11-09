# Plan: Submission identity via **required** `X-User-Id` on presigned-url

> Date: 2026-09-28 (v2 — decision changed to **required** header per review) ·
> Scope: **submission-service code + tests + docs/Postman only**. No executor-, result-,
> or course-service code changes (they already carry `studentId`).

---

## 1. Decision (TL;DR)

`POST /api/v1/submissions/presigned-url` now **requires** `X-User-Id` (Option B).
A submission without identity is broken data — unattributable result (403 on read),
exercise score always `null`, invisible in "my submissions" — so **fail fast with 400**
instead of silently storing a random `student_id`.

Rejected: optional + random fallback (v1 of this plan) — it preserves today's broken-by-
design path, and header-less calls are *nobody's* working flow anymore once the docs and
Postman (the only known callers) are updated in the same change.

**Required is a 2-part fix** — research found that simply marking the header required is
NOT enough:

1. `SubmissionController.requestUpload` → `@RequestHeader("X-User-Id")` (required).
2. **New `MissingRequestHeaderException` handler in `GlobalExceptionHandler`** —
   today no handler exists in *any* service; the catch-all `@ExceptionHandler(Exception.class)`
   (`GlobalExceptionHandler:103-107`) wins over `DefaultHandlerExceptionResolver` →
   a missing required header returns **500 "An unexpected error occurred"**, not 400.
   (course-service never hits this because every its endpoints use
   `defaultValue = "anonymous"` → `UUID.fromString("anonymous")` → 400 via IAE.)

Bonus: the same handler fixes the **existing latent 500** on `GET /api/v1/submissions`
without a header, making the documented matrix (`API-TEST-GUIDE:301,310` —
"missing `X-User-Id` → 400 … applies everywhere") finally true for submission-service.

Forward-compatible: when the gateway starts injecting the header (designed in
`system-design-v1.0.md:99`, not yet implemented) nothing changes.

---

## 2. Doc research — what the docs actually say (evidence)

### 2.1 The header is the system's designed identity channel
- `docs/design/system-design-v1.0.md:99` — gateway: *"Validate JWT … inject header
  `X-User-Id`, `X-User-Role` cho downstream services."* **Not implemented** — api-gateway
  = `ApiGatewayApplication` + `ReadableLogstashEncoder`, no filter. Pre-Keycloak the
  **client** sends it (skill `java-spring-boot-backend/SKILL.md:303-304`: *"no endpoint
  trusts client-sent identity beyond that header today"*). presigned-url is the **only**
  endpoint that ignores it.
- `docs/design/usecase-flows.md:230-242` — UC-04: *"student (`X-User-Id` =
  `class_students.student_user_id`). Identified by the gateway-injected header. …
  Enrollment = `class_students.student_user_id = X-User-Id`."*
- `docs/api/API-TEST-GUIDE.md:33` — *"send `X-User-Id: <uuid>` on every request that
  cares about identity."* · `src-services/README.md:133` — same-uuid-entire-flow rule.
- Sibling precedent inside the very same controller: `listMySubmissions`
  (`SubmissionController:46`) already has required `@RequestHeader("X-User-Id")`.

### 2.2 Stale claims this change invalidates (must rewrite)
| File | Line | Current text |
|---|---|---|
| `docs/design/usecase-flows.md` | 268 | *"Identity is stubbed server-side (random student UUID per call)."* |
| `src-services/docs/api/postman/FULL_FLOW_TESTING_GUIDE.md` | 269 | *"⚠️ Pre-Keycloak caveat: server generates a **random `studentId`** per upload."* |

### 2.3 Documented examples that omit the header → will now 400 (must add it)
- `docs/api/API-TEST-GUIDE.md:241` — presigned example, no header. (Also says **"→ 200"**
  but code returns **201 `HttpStatus.CREATED`** — fix while editing.)
- `FULL_FLOW_TESTING_GUIDE.md:277` — §5.1 presigned, no header.
- `FULL_FLOW_TESTING_GUIDE.md:291-294` — §5.3 `GET /api/v1/submissions (mine)` requires
  the header the guide never shows → guide's own flow already broken at verify.
- `FULL_FLOW_TESTING_GUIDE.md:19-20` — variables table defines only `ownerLecturer1/2`;
  **no student identity variable** → §5 needs one.
- `API-TEST-GUIDE.md:310` + `FULL_FLOW:34,326` — *"missing X-User-Id → 400"* written as a
  global rule; true for course-service (`defaultValue="anonymous"` path), **500 for
  submission-service today** → becomes 400 with the new handler (§4.2).

### 2.4 What the identity is FOR (why random is unsalvageable)
- `src-services/README.md:204-212` — exercise score needs 3 conditions incl. results for
  the (assignment, **student**) pair → random ids make it unreachable (always `null`).
- `docs/design/usecase-flows.md:292` — *"`results.is_latest` is unique per
  `(student_id, assignment_id, plan_id)`"* → flyway
  `result-service V2__…plan_weight_and_latest.sql:6`: `CREATE UNIQUE INDEX idx_results_latest
  ON results(student_id, assignment_id, plan_id) WHERE is_latest = true`.
- `docs/design/execute-plan-v1.0.md` §2 step 2 — the `latest = false` demotion this change
  re-enables. No identity claim elsewhere → **no edit**.

### 2.5 Postman collection audit (parsed, not guessed)
- `Submission service` folder: 8 requests, **zero** `X-User-Id` headers; no folder-level
  headers; no collection variables (env-provided) → `list my submissions` (required)
  fails as-shipped; **presigned will 400 after this change unless the header is added**.
- `Result service` folder: 3 requests, zero headers → ownership check never exercised.
- `Student` folder: 3 requests use `X-User-Id: {{fake_student_id}}` ← **pattern to copy**.
- `Course service`: 23 requests use `{{fake_lecturer_id}}`.

### 2.6 Places that need NO edit
`execute-plan-v1.0.md`, `docs/idea/detail.md`, `system-design-v1.0.md:160-176`,
`docs/db/*` (schema unchanged — value-only), skill `SKILL.md:303` (convention already
correct, no contradiction).

---

## 3. What the random `studentId` breaks today (impact)

`Submission.studentId` → `GradeSubmissionPayload` (`SubmissionService:110-116`) → `results.student_id`:

| # | Consumer | Code | Broken today |
|---|---|---|---|
| 1 | Result ownership | `result-service ResultController:36-43` | header sent → `callerId != random` → **403** on own result |
| 2 | Weighted exercise score | `course-service ScoreService:176-190` → `ResultService.weightedScoreByPlan:34` | queries real `student_user_id` → **always `null`** |
| 3 | "My submissions" | `SubmissionService.listByStudent:124` | **always empty page** |
| 4 | `latest` demotion | `SubmissionService.requestUpload:43-47` | never matches the real student's previous row → contradicts `execute-plan-v1.0` §2 |

## 4. Code change — two files

### 4.1 `submission-service/.../controller/SubmissionController.java` (replace lines 28-42)

```java
@PostMapping("/presigned-url")
@ApiMessage("Upload URL generated")
public ResponseEntity<PresignedUrlResponse> requestUpload(
        @RequestParam UUID assignmentId,
        @RequestParam String zipFileName,
        @RequestParam(required = false) UUID planId,
        // Review: 2026-09-28 — identity used to be a per-call UUID.randomUUID(), so no
        // result could ever be attributed to the submitting student: result-service
        // ownership check 403'd, weighted exercise score (keyed by
        // class_students.student_user_id) was always null, and "my submissions" was
        // always empty. X-User-Id is now REQUIRED, like the sibling listMySubmissions:
        // fail fast with 400 instead of silently storing an unattributable student_id.
        // Missing → MissingRequestHeaderException → 400 via the new handler in
        // GlobalExceptionHandler (previously the catch-all turned it into 500);
        // present-but-malformed/blank → UUID.fromString throws → 400 via the existing
        // IllegalArgumentException handler.
        @RequestHeader("X-User-Id") String studentIdHeader) {
    UUID studentId = UUID.fromString(studentIdHeader);
    PresignedUrlResponse response = submissionService.requestUpload(
            assignmentId, studentId, zipFileName, planId);
    return ResponseEntity.status(HttpStatus.CREATED).body(response);
}
```

`String` + `UUID.fromString` (not typed `UUID`) matches the sibling `listMySubmissions`
and keeps the malformed case unit-testable inside the method.

### 4.2 `submission-service/.../exception/GlobalExceptionHandler.java` (new handler)

```java
// Required-header failures previously fell into the @ExceptionHandler(Exception.class)
// catch-all → 500. 400 here also covers GET /api/v1/submissions without a header and
// makes API-TEST-GUIDE's negative matrix ("missing X-User-Id → 400") true for this
// service. Review: 2026-09-28.
@ExceptionHandler(MissingRequestHeaderException.class)
public ResponseEntity<ApiResponse<Void>> handleMissingHeader(MissingRequestHeaderException e) {
    return build(HttpStatus.BAD_REQUEST, "Missing required header: " + e.getHeaderName(), null);
}
```
+ `import org.springframework.web.bind.MissingRequestHeaderException;` — message style
mirrors `handleMissingParam` (`:88-91`).

**Not changed:** `SubmissionService.requestUpload` signature, webhook path,
`GradeSubmissionPayload`, executor, `ResultService`, `ScoreService`, DTO shapes, DB
schema. `ResultController`'s optional header (ownership check) stays as designed/tested.

### 4.3 `repository/SubmissionRepository.java` + `service/SubmissionService.java` — demote-all hardening

`SubmissionRepository` return type changed to `List<Submission>` (renamed
`findLatestByAssignmentAndStudent` → `findAllLatestByAssignmentAndStudent`, single
call site at `SubmissionService:48`) so a concurrent double-submit cannot throw
`NonUniqueResultException` (500):

```java
// Repository: no unique constraint guards submissions.latest (docs/db/README.md:442
// is a plain partial index), so a concurrent double-submit can leave 2+
// latest=true rows. Returning a single entity throws NonUniqueResultException;
// a list lets requestUpload collapse all stale rows and self-heal. Review: 2026-09-28.
@Query("SELECT s FROM Submission s WHERE s.assignmentId = :assignmentId AND s.studentId = :studentId AND s.latest = true")
List<Submission> findAllLatestByAssignmentAndStudent(
        @Param("assignmentId") UUID assignmentId,
        @Param("studentId") UUID studentId);
```
```java
// Service: demote every previous latest row (not just the first) — the next
// submit then self-heals any duplicate latest rows left by a race. Still inside
// the existing @Transactional. Review: 2026-09-28.
submissionRepository.findAllLatestByAssignmentAndStudent(assignmentId, studentId)
        .forEach(previous -> previous.setLatest(false));
```

## 5. Test change

New `src-services/submission-service/src/test/java/.../controller/SubmissionControllerTest.java`
(plain Mockito, direct construction — repo convention; **no MockMvc anywhere in this repo**):

| # | Test | Assertion |
|---|---|---|
| 1 | `requestUpload_withHeader_usesHeaderStudentId` | fixed uuid → `ArgumentCaptor` shows service received exactly it; 201 |
| 2 | `requestUpload_malformedHeader_throwsBadRequest` | `"not-a-uuid"` → `IllegalArgumentException` (existing handler → 400) |
| 3 | `missingHeader_returns400_not500` | build `new MissingRequestHeaderException("X-User-Id", new MethodParameter(controllerMethod, 3))` → `new GlobalExceptionHandler().handleMissingHeader(ex)` → 400 + message `"Missing required header: X-User-Id"` |
| 4 | `requestUpload_multipleLatestRows_demotesAll` | repo returns 2 latest rows → both `latest=false`; new row persisted `latest=true` |
| 5 | `requestUpload_noExistingLatest_persistsNewRow` | empty list → no demotion, new row persisted `latest=true` |

Note (verified against `spring-web-7.0.8` bytecode): the `(String, MethodParameter)`
constructor stashes the parameter without dereferencing it, but `getMessage()` calls
`parameter.getNestedParameterType()` → pass a **real** `MethodParameter` (from
`SubmissionController.class.getDeclaredMethod("requestUpload", UUID.class, String.class, UUID.class, String.class)`,
index 3), never `null`.

Existing suites green (25 passing; the one `Tests run` error is the pre-existing
`@SpringBootTest` needing a live Postgres):
```bash
/var/lib/snapd/snap/intellij-idea/12/plugins/maven/lib/maven3/bin/mvn \
  -f src-services/submission-service/pom.xml test
```

## 6. Documentation updates (mandatory — endpoint behavior changed)

| # | File · lines | Edit |
|---|---|---|
| 1 | `docs/design/usecase-flows.md` · UC-04 Step 3 (264-268) | Add `X-User-Id: <student-uuid>` to the request block (marked **required**, `400 "Missing required header: X-User-Id"` when absent); replace the line-268 stub claim: identity = `X-User-Id` (= `class_students.student_user_id`) stamped into `submissions.student_id` |
| 2 | `docs/design/usecase-flows.md` · UC-04 Step 4 (286) | `GET /api/v1/results/{submissionId}` sends the **same** `X-User-Id` — mismatch ⇒ `403 "Not owner of submission"` |
| 3 | `FULL_FLOW_TESTING_GUIDE.md` · 19-20 | Add student identity variable row (the `studentUserId` uuid used in the class CSV import) |
| 4 | `FULL_FLOW_TESTING_GUIDE.md` · 269 | Rewrite ⚠️ caveat: header **required**; random-studentId era over; without the header the call now 400s |
| 5 | `FULL_FLOW_TESTING_GUIDE.md` · 277 (§5.1), 291-294 (§5.3) | Add `X-User-Id: {{studentUser1}}` to presigned + `GET /submissions (mine)` + results-poll examples |
| 6 | `docs/api/API-TEST-GUIDE.md` · 241-248 | Add `-H "X-User-Id: <student-uuid>"`; fix `"→ 200"` → `"→ 201"` |
| 7 | `docs/api/API-TEST-GUIDE.md` · 310 | Update message hint for submission-service: `Missing required header: X-User-Id` (course-service stays `invalid UUID "anonymous"`) — row becomes fully accurate |
| 8 | `src-services/README.md` · 234 | Identity rule on the per-plan submission line (`X-User-Id` → `submissions.student_id`) |
| 9 | `src-services/submission-service/README.md` · 42 | Same — note the header is **required** |
| 10 | `src-services/docs/api/postman/Web grading service.postman_collection.json` | Add `"header": [{"key":"X-User-Id","value":"{{fake_student_id}}"}]` to **3** requests: `Get presigned url for a document` (**breaks with 400 otherwise**), `list my submissions` (already broken), `get results by submission (poll score)` (exercises ownership). Leave webhook/internal/health/get-by-id/list-by-assignment header-less — no identity semantics |

`execute-plan-v1.0.md`, `system-design-v1.0.md`, `docs/db/*`, skills: **no edits** (§2.6).

## 7. Behavior matrix — breaking change is deliberate and fully covered

| Call | Today | After |
|---|---|---|
| presigned + valid header | **ignored** → random id | `studentId` = header ✅ |
| presigned **no header** | 201, random id | **400 `Missing required header: X-User-Id`** |
| presigned blank header (`X-User-Id:`) | ignored → random | **400** (`UUID.fromString("")`) |
| presigned malformed header | ignored → random | **400** (was silently misattributed) |
| `GET /submissions` no header | **500** (catch-all) | **400** (same new handler — side fix) |
| `GET /results/{id}` header mismatch | 403 | 403 (unchanged, still tested) |
| `GET /results/{id}` no header | 200, no check | unchanged — result-service out of scope |

- **Who breaks?** Only header-less presigned callers: the Postman request, the two guide
  examples — all updated in this same change. No FE exists (`usecase-flows` UC-04 note);
  no service calls presigned-url internally; gateway injects nothing yet (clients already
  send the header everywhere else).
- **No contract change** otherwise: params, response envelope/DTO, webhook, Kafka schema,
  executor/result APIs untouched.
- **Demotion activates** (by design): `submissions` has only a *plain* index on
  `(assignment_id, student_id)` → demote-then-insert safe; `results.idx_results_latest` is
  **UNIQUE** (`V2`) and `ResultService.createResult:124-132` demotes previous latest rows
  in the same transaction before insert. Neither path ever fired with random ids.
- **Legacy rows** keep random `student_id` — invisible to the real student, excluded from
  the weighted score. Dev data: re-submit. No migration.

## 8. Verification

1. **Unit**: command in §5 — previous 14/14 + 3 new tests green.
2. **Doc sweep**: `grep -rn "random student" docs src-services --include='*.md'` → no hits;
   presigned examples in both guides show the header + 201.
3. **Live smoke** (after submission-service deploy — `build-services.yml` → `publish.yml`
   tag bump → ArgoCD sync; see `cicd-gitops-argocd` skill), header
   `X-User-Id: 2d93941a-4221-458b-a03d-43bd6315d02e`:

   | Step | Call | Expected (was) |
   |---|---|---|
   | 1 | presigned + header | 201 (201) |
   | 2 | presigned **without** header | **400 `Missing required header: X-User-Id`** (was 201+random) |
   | 3 | presigned `X-User-Id: not-a-uuid` | 400 (was 201+random) |
   | 4 | `PUT {uploadUrl}` zip → webhook → grading | grading runs |
   | 5 | `GET /api/v1/results/{submissionId}` + same header | **200** (was 403) |
   | 6 | `GET /api/v1/submissions` + header / without | non-empty (was `[]`) / **400** (was 500) |
   | 7 | `POST /api/v1/internal/results/weighted` with real `studentId` | **non-null** (was always null) |

## 9. Adjacent findings — report, do NOT fix here

1. **Designed-but-missing assignment validation**: `system-design-v1.0.md:153` says
   submission-service validates via `GET /api/v1/internal/assignments/{id}/exists` —
   submission-service has **no Feign client at all**; any `assignmentId` is accepted and
   there is no enrollment check (student can submit to an assignment they can't see).
   Separate task.
2. **Stale route**: `API-TEST-GUIDE:278` documents `POST /internal/results/average`;
   real route is `/weighted` (`ResultInternalController:26`).
3. **Doc drift**: `docs/db/README.md:681` shows `idx_results_latest` as plain
   `CREATE INDEX`; the real `V2` migration makes it `UNIQUE`.
4. *(resolved by this plan)* the `MissingRequestHeaderException` → 500 gap is now **in
   scope** (§4.2) — it also affects `GET /submissions` and any future required header.
