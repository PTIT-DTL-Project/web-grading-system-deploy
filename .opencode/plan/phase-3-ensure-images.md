# Phase 3 — ENSURE_IMAGES (grading-time guarantee)

> **Date:** 2026-09-28
> **Source:** `.opencode/plans/lecturer-docker-image-management-v1.0.md`
> **Depends on:** Phase 1 + Phase 2 (`feat/executor-service`, HEAD `2d30dcb`)

## Goal

Before `composeRunner.boot()`, ensure every image the assignment declared actually exists in this pod's DinD — close the emptyDir race.

## Tasks (per plan)

1. Call `ensureImages(assignmentImages, timeout)` between DB-port pre-scan/claim and `composeRunner.boot()`
2. inspect → absent → pull (bounded by `imageScan.pull-timeout-ms`) → failure → job `FAILED` with a message naming the image
3. the existing `finally` still releases the port
4. add `ImageEnsureTest` to the orchestrator test suite

## Locked decisions

### Insertion point: slot B (after `claimDbPort`, before `boot`)

`grade()` order: `scanDbRequirements` (141-151) → `BUILDING` (153) → download (167) → `appPort` claim (181) → `dbPort` claim (184) → `startupTimeoutMs` computed (192) → **slot** → `bootRow = sagaTracker.step(...)` (193) → `composeRunner.boot()` (202).

Why B and not A or C:
- Task 3 (*"the existing finally still releases the port"*) is only meaningful if a port was actually claimed when the failure happens. Under slot A there is nothing to release — the task would be vacuous. Existing precedent `claimDbPortThrows_appPortReleasedAndWorkDirCleaned` (line 872) already asserts claim→fail→release.
- The pool is 10,001 ports (`PortAllocator:17`) so holding two during a 10-minute pull costs nothing. (My earlier "starvation" argument rested on a false premise and is retracted.)
- The plan's literal wording "between DB-port pre-scan/claim and `composeRunner.boot()`" maps to B.
- Wasted work: B wastes a download (seconds) if the image is missing; A would waste a pull (≤10 min, Docker Hub quota) for a job whose zip later fails. B is cheaper.

### Gated on `executor.image-scan.enabled`

`enabled=false` means byte-for-byte pre-Phase-3 behavior (compose pulls at boot and reports a generic infra failure).

- If the flag is used to stop interfering (rate limits, disk, debugging), Phase 3 must not still run pull loops that can stall a job.
- In all failure scenarios (image truly unavailable) the job fails either way — compose would fail too — so gating costs nothing diagnostically.

### No `docker_image_state` write

Scanner self-heals in ≤5 min (`interval-ms: 300000`): next cycle finds `present()==true` → `upsertWarm`.

### No saga step

`Constant.Saga` has no `ENSURE_IMAGES` constant (line 125-133); plan doesn't request one; `fail()` already persists the error.

### Status during ensure is `BUILDING` (slot B), not `FETCHING`

Line 153 sets `BUILDING` before the slot. Honest, no need to lie about it.

## Changes

### `GradingOrchestrator.java`
- Add `java.time.Duration` import.
- Append `private final DockerImageGateway imageGateway;` as 15th field (index 14, after `dialectRegistry`).
- Insert call block between lines 192 and 193 (see plan file; here summarized).
- Add private `ensureImages(List<String> urls, long pullTimeoutMs)`.
- Wrap in `try/catch (ImagePullException) { fail(...); return; }`.
- Gate: `imageScan != null && imageScan.enabled() && assignmentImages != null && !assignmentImages.isEmpty()`.

**Why `GradingOrchestrator`:** `scanDbRequirements` is a private method beside this seam; the seam is named `scanImageRequirements` in the class javadoc (`:266`). A private method is the smallest thing that fits. `DockerImageGateway` is already a `@Service` — no new component.

**Failure path (slot B) on failure:**
- `appPort` claimed (181), `dbPort` claimed (184) → `finally` (244) releases both ✓
- `bootRow` still `null` → no dangling saga step ✓
- `downloadRow` already finished (168) ✓
- `fail()` → `finally` → `return` ✓

### `Constant.java`
- Add `ENSURING_PREFIX = "Ensuring images: "` in the `Message` inner class (beside `BUILDING_PREFIX`).

### `GradingOrchestratorTest.java`
- `Fixture` record: append `DockerImageGateway gateway`, `CourseInternalClient course`.
- `fixture()`: create gateway mock, stub `present(any()) → true`, pass as 15th ctor arg; append to `new Fixture(...)` (single construction site at line 183).
- Lines 329-330, 774-776, 931-933: append one `null` each (mechanical; these only reflectively call `scanDbRequirements`/`autoInjectExtracts`, never `grade()`).
- New section `// ─── ensureImages tests ───`: 2 tests.

### `ImageEnsureTest.java` (new)
Reflection fixture mirroring `invokeScan` (line 772), 15 args with gateway last. 3 tests via reflection on private `ensureImages`.

## Test plan — 5 new tests → **206 + 5 = 211**

| # | Test | File | Asserts |
|---|---|---|---|
| 1 | `presentImage_isSkipped` | ImageEnsureTest | `pull` never called |
| 2 | `absentImage_isPulledWithConfiguredTimeout` | ImageEnsureTest | `eq(Duration.ofMillis(600000))` — not `any()` |
| 3 | `pullFailure_throwsNamingTheImage` | ImageEnsureTest | cause message contains the URL |
| 4 | `imagePullFailure_failsJobAndReleasesPorts` | GradingOrchestratorTest | `FAILED` + `errorMessage` contains URL + `ports().claim()` + `release(23456)` + `runner().never().boot()` + `artifacts().fetchWorkDir()` **was** called |
| 5 | `imagesPresent_bootsNormallyWithoutPull` | GradingOrchestratorTest | `DONE` + `pull` never called |

Null-guard coverage is free: existing tests keep `dockerImageUrls = null`, exercising the `assignmentImages != null` branch (the common case — most assignments have no images).

Dropped: my earlier 6th test ("empty images, no gateway interaction"). The guard is one condition and existing tests cover it; restructuring the fixture for a redundant assertion isn't worth it.

## Known gaps (not fixed)

- Assignment-declared ≠ compose-referenced. An undeclared image in a student compose isn't ensured; compose's own pull is the fallback.
- `withBuild(true)` rebuilds student images each job regardless of pre-pull — inherent, not addressed.
- 15th positional ctor arg re-confirms why the project bans positional constructors >2 args (`GradingOrchestrator` → `@Builder` is a candidate, out of scope).

## Verification

```
mvn test -Dtest='!*ApplicationTests' -Dsurefire.failIfNoSpecifiedTests=false   # expect 211
KAFKA_CA_PATH=/nonexistent/ca.pem mvn test -Dtest='!*ApplicationTests'          # CI gate
```

## Commit

`feat(executor-service): ensure assignment images exist before compose boot (Phase 3)` — one commit.

## After it lands (Phase 4)

7 doc/SKILL items: executor-grading §9 FUTURE→built; §10 conventions; `usecase-flows.md` image-management section; `design-db-v1.0.md` docker_images + changelog v1.2; `execute-plan-v1.0.md:370` mark realized; `grading-full-flow.md` note ENSURE_IMAGES filled; `src-services/README.md` test recipes. Note `usecase-flows.md:503` already has a `Step 2 — Grading-time guarantee (ENSURE_IMAGES)` section written in advance — it needs reconciling against what actually ships (slot B, gated, no saga step, no `docker_image_state` write), not written fresh.
