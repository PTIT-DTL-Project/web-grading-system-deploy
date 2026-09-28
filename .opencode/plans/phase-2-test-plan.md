# Phase 2 — Test Plan: Executor async Docker image pre-pull scanner

> Date: 2026-09-27 · Axis 2 (getting bytes onto the box) · depends on Phase 1 (image library + `CourseInternalClient.images()`).

---

## 1. Test strategy

| Layer | Framework | Docker needed? | Covers |
|---|---|---|---|
| **Unit** | JUnit 5 + Mockito (`new Scanner(...)` construction) | No | `ImageScanner` branch logic, backoff, prune args, defensive Feign |
| **Gateway unit** | Mockito-free, real `DockerImageGatewayImpl` | **Yes** (gated per-method) | `present`/`pull` against the live `DOCKER_HOST` DinD daemon |
| **Repository slice** | `@SpringBootTest` + H2 (`flyway=off`, `ddl-auto=create-drop`) | No | `V7` DDL, `@SQLRestriction`, `findByImageUrlAndPodId`, `pruneBefore` |
| **Config / wiring** | Compile + context load | No | `ExecutorProperties` binding (incl. new `ImageScan`), `@Scheduled` expression |

Run command (from `src-services/executor-service`):
```bash
/var/lib/snapd/snap/intellij-idea/12/plugins/maven/lib/maven3/bin/mvn \
  test -Dtest='!*ApplicationTests' -Dsurefire.failIfNoSpecifiedTests=false
```

---

## 2. Unit tests — `ImageScannerTest` (no Docker)

Construct `ImageScanner` directly with mocked dependencies (mirrors `StaleJobReaperTest`):
`new ImageScanner(gateway, courseInternalClient, stateRepository, props)`.

| # | Test | Assertion |
|---|---|---|
| 1 | `disabledSkipsCycle` | `enabled=false` → `verifyNoInteractions(gateway, client, repo)` |
| 2 | `fetchFailureAbortsCycle` | `client.images()` throws → `verify(client).images()`, `verifyNoInteractions(gateway)`, `repo.pruneBefore` never called, `repo.save` never called |
| 3 | `presentImageMarksPulledWithoutPull` | `gateway.present=true` → `gateway.pull` never called; `repo.save` argument status `PULLED`, `lastPulledAt` null |
| 4 | `absentImagePullsWithConfiguredTimeout` | `gateway.present=false` → `gateway.pull(eq(url), any())` called; saved row `PULLED` + `lastPulledAt` non-null |
| 5 | `pullFailureMarksFailedAndContinues` | 2 URLs, first `pull` throws `ImagePullException` → first row `FAILED`, second still pulled; both `gateway.pull` calls verified |
| 6 | `failedRowWithinBackoffSkipped` | existing `FAILED` row `lastPulledAt=now-1min`, backoff 10min → `gateway.present` never called, `repo.save` never called |
| 7 | `failedRowAfterBackoffRetried` | existing `FAILED` row `lastPulledAt=now-20min` → `gateway.present` called, row refreshed to `PULLED` |
| 8 | `prunesStaleRowsAtSixIntervals` | `ArgumentCaptor<OffsetDateTime> cutoff` on `repo.pruneBefore` → `cutoff` is between `now-31min` and `now-29min` (horizon = 6 × 300s = 30min) |

**Coverage targets**: every branch of `scanOne` (warm / pull / pull-failure / backoff), the prune paths, the two pod-id resolution branches (env `HOSTNAME` present / fallback), the `cfg == null` guard.

---

## 3. Gateway tests — `DockerImageGatewayImplTest` (Docker-gated)

Gated **per method** with `Assumptions.assumeTrue(DockerClientFactory.instance().isDockerAvailable())` — **never** on `@BeforeAll` (skill §10 trap: a failing gate on `@BeforeAll` aborts the class and makes the Mockito tests inside vanish → `Tests run: 0`).

| # | Test | Assertion |
|---|---|---|
| 1 | `presentReturnsFalseForUnknownImage` | `gateway.present("wgs-never-exists:0.0.0")` → `false`, no exception |
| 2 | `pullThenPresentReturnsTrue` | `gateway.pull("alpine:3.20", 120s)` then `gateway.present("alpine:3.20")` → `true` — proves the `DOCKER_HOST` wiring that already powers `DockerComposeRunner` |

If the daemon is absent both tests **skip cleanly** (the suite still reports green).

---

## 4. Repository slice — `DockerImageStateRepositoryTest` (H2, no Docker)

`@SpringBootTest` + `spring.flyway.enabled=false` + `spring.jpa.hibernate.ddl-auto=create-drop` + `jdbc:h2:mem:test` (entity-driven schema, matching the course-service H2-slice convention).

| # | Test | Assertion |
|---|---|---|
| 1 | `saveAndFindByImageUrlAndPodId` | insert → `findByImageUrlAndPodId` returns row with `status = PULLED` |
| 2 | `findExcludesSoftDeleted` | insert → set `deletedAt` → `findBy…` → empty (`@SQLRestriction` works) |
| 3 | `pruneBeforeDeletesStaleRows` | insert row, force `updatedAt` old via `EntityManager` bulk update, `pruneBefore(now-30min, now)` → `pruned > 0`, `findBy…` empty |
| 4 | `pruneBeforeKeepsFreshRows` | insert row (updatedAt = now) → `pruneBefore(now-30min, now)` → `pruned == 0`, `findBy…` present |

**Note on test 3**: Hibernate's `@UpdateTimestamp` stamps `updatedAt = now()` on insert, so the row is fresh by default. The test overrides `updatedAt` with a bulk JPQL update (`executeUpdate()`) to age it past the horizon — this bypasses the listener and exercises the prune predicate directly.

`pruneBefore` is a `@Modifying @Query` with `@Param` on both params (the PR #20 nitpick).

---

## 5. Config / wiring tests

- **Compile**: `mvn -q compile` from `src-services/executor-service` — `ExecutorProperties` with the new `ImageScan` component + `@Builder` must bind; the three existing test constructions (converted to builder) must compile.
- **Context load**: the `application.yaml` additions (`spring.task.scheduling.pool.size`, `executor.image-scan.*` with env overrides) must resolve without `IllegalArgumentException` on context startup. The `@Scheduled(fixedDelayString = "${executor.image-scan.interval-ms:300000}")` expression must parse.
- **No orphan `#N` markers**: `grep -rn "Pullfrog PR #N"` → 0 hits.

---

## 6. Validation checklist (all must pass)

1. `mvn test -Dtest='!*ApplicationTests' -Dsurefire.failIfNoSpecifiedTests=false` → **all green, `BUILD SUCCESS`** (baseline + new tests). Docker-gated tests skip if no daemon.
2. `mvn -q compile` → clean.
3. `grep -rn "Pullfrog PR #N" .` → 0 hits.
4. `grep -rn "softDeleteByAssignmentId(id" src-services/course-service/src/main/java/` → only `AssignmentService.java:211` (the correct assignment-id call).

---

## 7. Risks and mitigations

- **Docker-gated tests stall the scheduler thread**: `pull` is bounded by `pullTimeoutMs` (default 10 min) per image, but the scheduler has `pool.size=4` so `StaleJobReaper` keeps its slot. A failed `present`/`pull` is fast.
- **Prune horizon invariant**: default `fail-backoff-ms` (600s) < 6 × `interval-ms` (1800s). If a user tunes backoff above the horizon, a backing-off row gets pruned early — harmless (one early retry).
- **Pod churn**: Deployment `replicaCount: 2` means pod names change on restart; the age-based prune (D1) GC's orphan rows automatically.
- **V7 partial unique index on H2**: not validated in the H2 slice (the index is PG-specific). Validated against a live Postgres in CI and the migration runs `CREATE INDEX IF NOT EXISTS ... WHERE deleted_at IS NULL` on the real engine.
- **Private registries / digest drift / Kafka events / `emptyDir` disk growth**: explicitly out of scope (YAGNI).

---

## 8. Commit plan (one concern per commit)

1. `feat(executor-service): async pre-pull scanner with per-pod image state (Phase 2)` — V7 + `ImageScanStatus` + `DockerImageState` + repo + `ExecutorProperties.ImageScan` + `Constant.ImageScan` + `DockerImageGateway`/`Impl` + `ImageScanner` + `application.yaml` + all tests.
2. (if needed) `docs(course-service): add internal docker-images Postman request` — the endpoint existed from Phase 1 with no collection entry; add it (boot course-service locally for a real response, or leave `response` empty and say so, per §12.5).

Then, on green: rewrite `.opencode/skills/executor-grading/SKILL.md` §9 *Axis 2: FUTURE* → built (stale "FUTURE" rules are worse than missing).
