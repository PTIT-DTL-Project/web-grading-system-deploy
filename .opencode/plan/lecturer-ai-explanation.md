# Lecturer access to a student's AI explanation

> Status: detailed, approved, in progress.
> Touches `src-services/result-service` (one internal route), `src-services/ai-assistant-service`
> (role gates + lecturer routes + authorization), `frontend-src/web-grading-system-fe`
> (move card to `shared/`, lecturer variant, mount), `docs/design/usecase-flows.md`, both skill trees.
> `course-service` is **not** touched.

## Goal

A lecturer grading an assignment can read the AI explanation of a student's submission where
they already read the grading evidence, and can trigger the explanation when the student never
opened it. The student's view keeps working exactly as today.

## 0. Decisions locked with the user

1. **Scope** — GET (cache read) + an explicit "generate" button (POST).
2. **Authorization lives in `ai-assistant-service`**, implemented the way every other service
   does it: a role gate (`@PreAuthorize`) plus an owner check in the service answering 404.
   No service impersonates another caller.
3. **Routes are split by audience** — one route must not serve two audiences (the lesson written
   into `result-service/.../ResultController.java:36-41`).
4. Adding `@PreAuthorize("hasRole('STUDENT')")` to the two existing student routes is approved,
   even though it changes behaviour on a live endpoint.
5. UI mount point: the per-result expanded row of `AssignmentResultsPage`.

A course-service proxy that called the AI service as the student was designed first and
**rejected** — it needed no AI-service change but made course-service forge the student's
identity and created a `course-service ↔ ai-assistant-service` dependency cycle.

## 1. Research — verified facts

### What the AI service is missing

- `SecurityConfig` has `.anyRequest().authenticated()` and **no `@PreAuthorize` anywhere**
  (`config/SecurityConfig.java:46-49`).
- The machinery is already in place, so no SecurityConfig change is needed:
  `@EnableMethodSecurity` is on (`SecurityConfig.java:20`), and
  `HeaderAuthenticationFilter` turns `X-User-Roles` into `ROLE_*` authorities
  (`security/HeaderAuthenticationFilter.java:82-93`). Existing tests already send
  `X-User-Roles: ROLE_STUDENT`.
- The gateway stamps `X-User-Roles` from the validated `realm_access.roles`, filtered by an
  allowlist defaulting to `ROLE_LECTURER,ROLE_STUDENT`, and **omits the header entirely when
  nothing survives** so `@PreAuthorize` fails closed
  (`api-gateway/.../AuthenticationContextFilter.java:100-104`, `application.yaml:43`).

### The lecturer-ownership oracle already exists

- `GET /api/v1/assignments/{id}` (course-service) is `@PreAuthorize("hasRole('LECTURER')")` and
  resolves through `getById(id, ownerId)` → `requireOwnedAssignment` → **404 when the caller does
  not own it** (`controller/AssignmentController.java:54-60`, `service/AssignmentService.java:100-102`).
  It returns the same `AssignmentResponse` as the student route the AI service already binds, so
  the existing `ApiEnvelope<AssignmentDetailDto>` mirror works unchanged.
- Called with the **real caller id** (the one the gateway stamped) it is a plain identity
  propagation, not impersonation.

### What is genuinely missing: `submissionId → assignmentId / studentId`

- Public `GET /api/v1/results/{submissionId}` enforces `caller == studentId`
  (`ResultController.java:52-58`) and must stay that way.
- Internal `/api/v1/internal/results/assignment/{assignmentId}` needs an `assignmentId` the AI
  service does not have yet.
- `ResultService.getBySubmissionId(UUID)` **already exists** (`service/ResultService.java:258`)
  and `ResultResponse` carries `assignmentId` + `studentId` (`dto/response/ResultResponse.java:19-21`),
  so the new internal route is a wrapper with no new logic.
- `/api/v1/internal/**` is `permitAll` and **not** gateway-routed
  (`result-service/config/SecurityConfig.java:29-34`, `api-gateway/application.yaml:17-32`), and
  `FormatRestResponse.isExcluded` drops the envelope for `/internal/` paths
  (`course-service/.../FormatRestResponse.java:62` — same helper copied per service).

## 2. Endpoints after the change

| ai-assistant-service | Role gate | Owner check |
|---|---|---|
| `GET\|POST /api/v1/ai/submissions/{submissionId}/explain` | `hasRole('STUDENT')` | `caller == result.studentId` (unchanged) |
| `GET\|POST /api/v1/ai/assignments/{assignmentId}/submissions/{submissionId}/explain` | `hasRole('LECTURER')` | lecturer owns `assignmentId` |

Result-service gains `GET /api/v1/internal/results/submission/{submissionId}` (identity-free,
cluster-internal only). The gateway already routes `/api/v1/ai/**`.

```
FE (lecturer)  GET|POST /api/v1/ai/assignments/{aid}/submissions/{sid}/explain
   │ Bearer JWT
   ▼ gateway  → X-User-Id (lecturer), X-User-Roles=LECTURER, X-Gateway-Secret
   ▼ ai-assistant-service @PreAuthorize LECTURER
        1. course-service GET /api/v1/assignments/{aid}  (as the lecturer) → 404 = not yours
        2. result-service GET /api/v1/internal/results/submission/{sid} → rows
           verify rows[0].assignmentId == aid, take rows[0].studentId
        3. return cache row  |  run the LLM
```

## 3. Backend

### 3.1 `result-service` — one route, no new logic

`controller/ResultInternalController.java`:

```java
@GetMapping("/submission/{submissionId}")
public ResponseEntity<List<ResultResponse>> bySubmission(@PathVariable UUID submissionId) {
    return ResponseEntity.ok(resultService.getBySubmissionId(submissionId));
}
```

Javadoc must state: the caller is ai-assistant-service *after* it has completed its own
authorization; the public route keeps its owner check for students. No change to
`ResultController`, `ResultService`, or the security config.

### 3.2 `ai-assistant-service`

**`controller/AiExplanationController.java`**
- `@PreAuthorize("hasRole('STUDENT')")` on the existing GET and POST.
- Two new handlers `GET|POST /assignments/{assignmentId}/submissions/{submissionId}/explain`,
  both `@PreAuthorize("hasRole('LECTURER')")`, reading `X-User-Id` as the existing ones do.

**`service/AiExplanationService.java`**
- Extract the tail shared by both audiences (assignment metadata → prompt → LLM → parse → save →
  response) into one private method so the lecturer branch does not duplicate it.
- New public methods `getExplanationForLecturer(assignmentId, submissionId, lecturerId)` and
  `explainSubmissionForLecturer(...)`, plus the authorization helper:

```java
private record LecturerTarget(UUID studentId, UUID assignmentId, List<ResultDto> results) {}

private LecturerTarget authorizeLecturer(UUID assignmentId, UUID submissionId, UUID lecturerId) {
    try {
        // Ownership first: an unowned (or foreign) submission id must never reach result-service.
        courseServiceClient.getOwnedAssignment(assignmentId, lecturerId.toString(), gatewayProperties.secret());
    } catch (FeignException.NotFound e) {
        // 404, never 403 — an existing assignment outside the caller's classes stays
        // indistinguishable from a missing one.
        throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Assignment not found: " + assignmentId);
    }
    List<ResultDto> results = resultServiceClient.getBySubmissionIdInternal(submissionId);
    if (results.isEmpty()) {
        throw new ResponseStatusException(HttpStatus.NOT_FOUND, "No grading results found for submission");
    }
    ResultDto first = results.get(0);
    if (!assignmentId.equals(first.getAssignmentId())) {
        throw new ResponseStatusException(HttpStatus.NOT_FOUND, "Submission not found in this assignment");
    }
    return new LecturerTarget(first.getStudentId(), assignmentId, results);
}
```

- GET lecturer: authorize, then read the cache row by `submissionId`; absent → 404, and a row
  whose `studentId` disagrees with the resolved owner also → 404 (data invariant, not authorization).
- POST lecturer: authorize → cache check → run the LLM tail with the **real student id**, so the
  cache row is written under the student and their next visit is a hit.
- Student path: untouched, including its use of result-service's public owner-enforcing route
  (defence in depth stays for students).
- No `@Transactional` around the Feign/LLM work (rule already documented in the file).

**`client/CourseServiceClient.java`** — one new method against the existing endpoint:

```java
@GetMapping("/api/v1/assignments/{assignmentId}")
ApiEnvelope<AssignmentDetailDto> getOwnedAssignment(@PathVariable("assignmentId") UUID assignmentId,
        @RequestHeader("X-User-Id") String lecturerId,
        @RequestHeader("X-Gateway-Secret") String gatewaySecret);
```

**`client/ResultServiceClient.java`** — one new method, internal so **no** envelope:

```java
@GetMapping("/api/v1/internal/results/submission/{submissionId}")
List<ResultDto> getBySubmissionIdInternal(@PathVariable("submissionId") UUID submissionId);
```

**Unchanged**: `config/SecurityConfig.java`, `application.yaml`, `config-services/ai-assistant-service`
(the `COURSE_SERVICE_URI` / `RESULT_SERVICE_URI` env values already exist).

## 4. Frontend

1. **Move to `shared/`** (feature folders must not import each other,
   `.opencode/skills/react-frontend-antd/SKILL.md:266`):
   - `features/student/results/AiExplanationCard.tsx` → `shared/ui/AiExplanationCard.tsx`
   - `features/student/results/useAiExplanation.ts` → `shared/hooks/useAiExplanation.ts`
   - rewrite the relative imports in both; update `SubmissionResultPage.tsx:26,394`.
2. **`shared/api/endpoints/aiExplanation.ts`**: two lecturer functions hitting the new route, with
   the same 404→`null` normalisation as the student GET.
3. **Hook + card**: optional `assignmentId` prop; when present they call the lecturer endpoint.
   Query key stays `['ai-explanation', submissionId]` — the payload is identical and the two
   audiences are never on screen together.
4. **`features/assignments/AssignmentResultsPage.tsx`**: render the card in the per-result
   expanded row next to `stepTable`, guarded by `result.submissionId`
   (`AssignmentResultResponse.java:29`).
5. **No i18n change** — the `ai.*` keys are reused verbatim.

## 5. Tests

- `result-service` `ResultInternalControllerTest`: the new route returns rows, and `[]` for a
  submission with none.
- `ai-assistant-service`:
  - `AiExplanationControllerTest`: student route + `ROLE_LECTURER` → 403; lecturer route +
    `ROLE_STUDENT` → 403; lecturer route + `ROLE_LECTURER` → 200 (GET and POST); no roles → 403.
  - `AiExplanationServiceTest`: lecturer not owning → 404 **and no result-service interaction**;
    `assignmentId` mismatch → 404; empty results → 404; lecturer cache hit; lecturer generate.
- `course-service`: its suite must be back to green untouched (revert verification).

## 6. Docs and skills

- `docs/design/usecase-flows.md` UC-18: lecturer branch — endpoint, both guards, the 404 contract,
  the warm-cache side effect.
- `java-spring-boot-backend`: the pattern "a service authorizes its own endpoints with a role gate
  plus an owner check answering 404; routes are split by audience; ownership is checked before any
  downstream read".
- `react-frontend-antd`: "a component needed by two feature folders moves to `shared/ui` +
  `shared/hooks`"; update the `AiExplanationCard` path named at `SKILL.md:40`.
- Both `.opencode/skills` and `.kilo/skills` updated identically.

## 7. Verification

1. `cd src-services/result-service && ./mvnw -q -Dtest=ResultInternalControllerTest test`
2. `cd src-services/ai-assistant-service && ./mvnw -q -Dtest='AiExplanationControllerTest,AiExplanationServiceTest' test`
3. `cd src-services/course-service && ./mvnw -q test`
4. `cd frontend-src/web-grading-system-fe && npm run i18n:check && npm run lint && npm run build`
5. Optional E2E: lecturer token → GET the new route on a submission with a cache row (200,
   `fromCache:true`) and one without (404), then POST (200, `fromCache:false`), then re-read with
   the student token to confirm the warmed cache.

## 8. Risks / notes

- The new internal result route has no owner check by design (cluster-only, not gateway-routed);
  adding the gateway secret to it is the upgrade path if that ever needs tightening.
- No `course ↔ ai` cycle: the edges stay one-directional (`ai → course`, `ai → result`).
- `@PreAuthorize('STUDENT')` on a live endpoint depends on the gateway still stamping
  `X-User-Roles`; the default allowlist already contains `ROLE_STUDENT`.
