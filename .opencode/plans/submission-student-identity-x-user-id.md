# Plan: Submission identity from `X-User-Id` (presigned-url)

> Date: 2026-09-27 · Scope: submission-service only (+ docs/Postman). No changes to
> executor-, result-, course-service code. Goal: stop inventing a random `studentId`
> per upload — without breaking any current caller.

---

## 1. Problem & evidence

`POST /api/v1/submissions/presigned-url` is the **only** endpoint in the system that
ignores the `X-User-Id` header and fabricates identity:

```java
// src-services/submission-service/.../controller/SubmissionController.java:30-42
public ResponseEntity<PresignedUrlResponse> requestUpload(...) {
    UUID studentUUID = UUID.randomUUID();          // ← identity is thrown away here
    String studentId = String.valueOf(studentUUID);
    ... UUID.fromString(studentId) ...             // (also a pointless round-trip)
}
```

Every other endpoint reads the header — `SubmissionController.listMySubmissions`
(line 46), all course-service controllers (`defaultValue = "anonymous"`), the
result-service ownership check. The api-gateway (`src-services/api-gateway`) does no
header manipulation, so `X-User-Id` sent by FE/curl reaches submission-service as-is.

The docs already admit the stub — these two lines become stale after this change:
- `docs/design/usecase-flows.md:268` — "Identity is stubbed server-side (random student UUID per call)."
- `src-services/docs/api/postman/FULL_FLOW_TESTING_GUIDE.md:269` — "server generates a **random `studentId`** per upload."

## 2. What the random `studentId` breaks today (impact analysis)

The random UUID propagates `Submission.studentId` → `GradeSubmissionPayload.studentId`
(`SubmissionService.java:110-116`) → `results.student_id`. Downstream, everything that
queries by the **real** student silently fails:

| # | Consumer | Code | Broken behavior today |
|---|---|---|---|
| 1 | Result ownership check | `result-service ResultController.java:36-43` | Caller sends `X-User-Id` → `callerId != stored random` → **403 "Not owner of submission"** on their own result |
| 2 | Weighted exercise score | `course-service ScoreService.java:176-190` → `result-service ResultService.weightedScoreByPlan:34-35` | Looks up `class_students.student_user_id` (real student) → never matches rows written with a random id → **average always `null`** → auto exercise score never populates |
| 3 | "My submissions" list | `SubmissionService.listByStudent:124-128` (header **required**) | `findByStudentIdOrderByCreatedAtDesc(realId)` → **always empty page** |
| 4 | `latest` demotion | `SubmissionService.requestUpload:43-47` | `findLatestByAssignmentAndStudent(assignmentId, randomId)` never finds the student's previous submission → old rows stay `latest=true` forever; same for `is_latest` demotion in `ResultService.createResult:124-131` |

Item 4 shows the *intended* design (`docs/design/execute-plan-v1.0.md` §2 step 2:
"Nếu submission đang có `latest = true` cũ → set `latest = false`") can never fire
while identity is random.

## 3. Design decision

**Read identity from `X-User-Id`, optional, with the old random fallback.**

Options considered:

| Option | Verdict |
|---|---|
| **A. `required = false` + random fallback when absent/blank** ✅ | Chosen. Strictly additive: header present → real identity (fixes all 4 rows above); header absent → byte-for-byte today's behavior. Zero breakage for existing scripts. |
| B. `required = true` → 400 when missing | Rejected: the Postman request "Get presigned url for a document" has `"header": []` (line 15), the API guide/curl examples send no header, no FE exists yet (UC-04 note), and the gateway does **not** inject identity. Required header would break every current caller. |
| C. New `studentId` request param | Rejected: identity is already a header convention everywhere else; a second identity channel invites mismatch with `listMySubmissions` / result ownership (both read the header). |
| D. Keep random, add ownership by `submissionId` only | Rejected: cannot fix #2 (weighted score is keyed by `student_id`) nor #3/#4 without the real id. |

Details:
- **Binding style**: `String` + `UUID.fromString` when present (matches the sibling
  method `listMySubmissions` in the same controller). A malformed header →
  `IllegalArgumentException` → **400** via existing
  `submission-service GlobalExceptionHandler.handleBadRequest:29-32`.
  Blank/whitespace header → treated as absent (fallback), so an empty
  `X-User-Id:` doesn't 400.
- The `UUID`-typed binding was rejected only because an empty string header would
  400 through `MethodArgumentTypeMismatchException` instead of falling back.

### Behavior matrix (review surface)

| Call | Today | After |
|---|---|---|
| presigned-url **with** valid `X-User-Id` | header ignored, random id stored | stored id = header |
| presigned-url **without** header | random id | unchanged (fallback) |
| presigned-url **blank** header | ignored (random) | unchanged (fallback) |
| presigned-url **malformed** header | ignored (random, silently wrong) | **400** "Invalid value…" (new, correct) |
| `GET /results/{id}` w/ header, own submission | 403 | 200 |
| `GET /submissions` w/ header | empty page | returns own submissions |
| `POST /internal/results/weighted` (course-service) | always `null` | returns weighted score |
| 2nd submission, same (assignment, student) | never demotes previous | demotes previous `latest=true` — **intended design** (execute-plan-v1.0 §2) |

## 4. Code change — one file

`src-services/submission-service/src/main/java/vn/edu/ptit/web_grading_system/submission_service/controller/SubmissionController.java`

Replace lines 28-42:

```java
@PostMapping("/presigned-url")
@ApiMessage("Upload URL generated")
public ResponseEntity<PresignedUrlResponse> requestUpload(
        @RequestParam UUID assignmentId,
        @RequestParam String zipFileName,
        @RequestParam(required = false) UUID planId,
        // Review: 2026-09-27 — identity used to be a per-call UUID.randomUUID(), so no
        // result could ever be attributed to the submitting student: result-service
        // ownership check 403'd, weighted exercise score (keyed by class_students.
        // student_user_id) was always null, and "my submissions" came back empty.
        // Identity now comes from the same X-User-Id header every other endpoint reads.
        // Kept optional with the old random fallback so header-less callers (existing
        // Postman/curl scripts, pre-Keycloak clients) behave exactly as before.
        @RequestHeader(value = "X-User-Id", required = false) String studentIdHeader) {
    UUID studentId = (studentIdHeader == null || studentIdHeader.isBlank())
            ? UUID.randomUUID()
            : UUID.fromString(studentIdHeader); // malformed header → 400 (IllegalArgumentException handler)
    PresignedUrlResponse response = submissionService.requestUpload(
            assignmentId, studentId, zipFileName, planId);
    return ResponseEntity.status(HttpStatus.CREATED).body(response);
}
```

Comment rules honored: WHY + review date (project AGENTS.md § "Code comments for
future review"), and the comment must be rewritten with the code (§ "Comment accuracy").

**Explicitly NOT changed** (the rest of the pipeline already carries `studentId`):
- `SubmissionService.requestUpload(...)` signature — already takes `UUID studentId`.
- Webhook path `handleUploadComplete` / `publishGradingIfNotStarted` — reads the id
  from the stored row.
- `GradeSubmissionPayload`, `GradeSubmissionHandler`, `GradingOrchestrator`,
  result-service `createResult`, course-service `ScoreService` — all already consume
  a real `studentId`.
- Response DTO of presigned-url (`PresignedUrlResponse`) — shape unchanged, so no FE
  contract change.
- No DB migration: `submissions.student_id` / `results.student_id` are plain UUID
  columns; only the **value** changes.

## 5. Test change

New `src-services/submission-service/src/test/java/.../controller/SubmissionControllerTest.java`
(unit, `new SubmissionController(mockService)` — mirrors
`result-service ResultControllerTest` style; no Spring context, no DB):

| # | Test | Assertion |
|---|---|---|
| 1 | `requestUpload_withHeader_usesHeaderStudentId` | header `"<fixed-uuid>"` → `ArgumentCaptor` on `service.requestUpload(...)` captures exactly that UUID; status 201 |
| 2 | `requestUpload_withoutHeader_fallsBackToRandom` | header `null` → captured studentId is non-null (still succeeds, 201) |
| 3 | `requestUpload_blankHeader_fallsBackToRandom` | header `"   "` → captured studentId non-null, 201 |
| 4 | `requestUpload_malformedHeader_throwsBadRequest` | header `"not-a-uuid"` → `IllegalArgumentException` thrown (which `GlobalExceptionHandler:29-32` maps to 400) |

Existing tests untouched: `SubmissionServiceWebhookTest`, `HttpLogServiceTest`,
`HttpLoggingFilterTest`, `KafkaConfigBindingTest`, `SubmissionServiceApplicationTests`
(previously green — submission-service 14/14).

Run (no `mvn` on PATH; use the IDEA-bundled Maven, same as phase-2 test plan):

```bash
/var/lib/snapd/snap/intellij-idea/12/plugins/maven/lib/maven3/bin/mvn \
  -f src-services/submission-service/pom.xml test
```

## 6. Doc changes (mandatory — endpoint behavior changed)

| File | Where | Change |
|---|---|---|
| `docs/design/usecase-flows.md` | UC-04 Step 3, line 268 | Replace "Identity is stubbed server-side (random student UUID per call)." with: identity = `X-User-Id` header (same uuid as enrollment/`class_students.student_user_id`); header optional — absent ⇒ server falls back to a random uuid and the result is unattributable |
| `src-services/docs/api/postman/Web grading service.postman_collection.json` | "Get presigned url for a document", line 15 `"header": []` | Add the `X-User-Id` header block, same shape as sibling requests (value = the flow uuid used by the other requests) |
| `src-services/docs/api/postman/FULL_FLOW_TESTING_GUIDE.md` | §5 caveat line 269 + §5.1 line 277 | Caveat becomes: send `X-User-Id` (the *same* uuid used when creating the class/students) or the result can't be read back / scored; without the header identity falls back to random |
| `docs/api/API-TEST-GUIDE.md` | line 241 presigned example | Add `-H "X-User-Id: <uuid>"` |
| `src-services/submission-service/README.md` | endpoint list (~line 43) | Note presigned-url accepts optional `X-User-Id` (identity) |

`docs/design/execute-plan-v1.0.md` needs **no** edit — its flow diagram/example never
claimed identity was random.

Per project AGENTS.md, after implementing **and verifying**, record the durable
convention ("every endpoint that needs caller identity reads `X-User-Id`; never
fabricate identity server-side") in `.opencode/skills/java-spring-boot-backend/SKILL.md`
— check the nearest section first and rewrite it if it conflicts.

## 7. No-breakage guarantees / regression surface

- **Header-less callers unchanged**: fallback reproduces today's exact behavior
  (this is why option B was rejected).
- **No contract change**: request params, status codes (201), response envelope/DTO,
  webhook, Kafka payload schema, executor and result APIs all untouched.
- **Ownership check only loosens**: `ResultController` 403 can only disappear for the
  genuine owner (caller id now equals stored id). Mismatched header still 403s
  (`ResultControllerTest` case 3 stays valid).
- **Legacy rows**: submissions/results already written keep their random
  `student_id` — they won't appear under the real student and won't contribute to the
  weighted score. Dev/stg data: re-submit to verify; no migration planned.
- **New 400 on malformed header** is the only tightened behavior (see matrix) —
  previously the garbage header was silently ignored.

## 8. Verification

1. Unit: command in §5 (expect previous 14/14 + 4 new tests green).
2. Docs readback: the 5 files in §6 — no remaining "random studentId" claims
   (`grep -rn "random student" docs/ src-services/docs/`).
3. Live smoke (after CI/CD deploy of submission-service — `build-services.yml` builds
   the changed service, `publish.yml` bumps the tag, ArgoCD syncs; see
   `cicd-gitops-argocd` skill), with `X-User-Id: 2d93941a-4221-458b-a03d-43bd6315d02e`:

   ```bash
   # 1. presigned (with header) → 201
   curl -X POST ".../api/v1/submissions/presigned-url?assignmentId=76b359be-...&zipFileName=book-app.zip" \
        -H "X-User-Id: 2d93941a-4221-458b-a03d-43bd6315d02e"
   # 2. PUT the zip to uploadUrl → RustFS webhook → grading
   # 3. poll results WITH the same header → 200 (was 403 before)
   curl ".../api/v1/results/{submissionId}" -H "X-User-Id: 2d93941a-..."
   # 4. "my submissions" → non-empty (was [] before)
   curl ".../api/v1/submissions" -H "X-User-Id: 2d93941a-..."
   # 5. weighted score → non-null once results land (was always null before)
   curl -X POST ".../api/v1/internal/results/weighted" -d \
        '{"assignmentIds":["76b359be-..."],"studentId":"2d93941a-4221-458b-a03d-43bd6315d02e"}'
   # 6. presigned WITHOUT header → still 201 (fallback preserved)
   ```

## 9. Out of scope (flag, don't fix here)

1. **Enrollment check on submit**: presigned-url accepts any `assignmentId` for any
   student — no `class_students` / `published` validation (course-service only gates
   *reading* assignments in `StudentAssignmentService.requireVisible`). Security-
   adjacent; needs a course-service call → separate task.
2. **`MissingRequestHeaderException` → 500**: submission-service's
   `GlobalExceptionHandler` has no handler for it, and the `@ExceptionHandler(Exception.class)`
   catch-all likely wins over `DefaultHandlerExceptionResolver`, so *required* headers
   missing (e.g. `GET /api/v1/submissions` with no header) return 500 instead of 400 —
   verify, then add a 400 handler. 3 lines; unrelated to this endpoint (ours is optional).
3. **Keycloak / real auth**: `X-User-Id` is a self-asserted header until identity
   provider integration — the fallback keeps that story honest rather than inventing
   trust.
