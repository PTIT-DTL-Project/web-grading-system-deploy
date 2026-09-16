# Repository Over-Engineering Audit

> Whole-tree scan, over-engineering only (not correctness).
> Ranked biggest cut first. Source: `benchmarks/` + README for benchmark
> medians; this file records the code-level findings.

---

## Full findings

```
  audit — whole tree, over-engineering only, ranked biggest cut first

  delete  [DONE 2026-09-12] docs/architecture/architecture.md (3202 lines) — superseded by
          system-design-v1.0.md, documents a system never built (Eureka,
          Config Server, Java 25, Spring Cloud Gateway).
          [docs/architecture/architecture.md]

  delete  [DONE 2026-09-12] docs/guide/WORKFLOW_ANALYSIS_REPORT.md
          + FIX_COMPLETED_SUMMARY.md + TEST_RUN_SUMMARY.md (789 lines) —
          ephemeral CI/CD debugging session reports from 2026-08-06;
          not durable documentation.
          [docs/guide/]

  delete  config-services/*/templates/_helpers.tpl ×4 copies (68 lines) —
          5 byte-identical copies; config-services/generate-charts.sh
          is the source of truth. Keep 1 as reference.
          [config-services/*/templates/_helpers.tpl]

  delete  config-services/*/templates/service.yaml ×4 copies (60 lines) —
          5 identical 15-line K8s Service manifests; same generator.
          [config-services/*/templates/service.yaml]

  delete  config-services/*/Chart.yaml ×4 copies (20 lines) —
          5 identical 5-line charts; same generator.
          [config-services/*/Chart.yaml]

  delete  [DONE 2026-09-12] config-services/*/README.md ×4 copies (88 lines) —
          kept api-gateway/README.md as the sole canonical reference;
          4 duplicates deleted.
          [config-services/*/README.md]

  delete  [DONE 2026-09-12] deploy/ingress/notification-service.yaml (18 lines) —
          Notification Service deferred; no deployment exists.
          [deploy/ingress/notification-service.yaml]

  delete  [DONE 2026-09-12] config-services/api-gateway/values-stg.yaml
          spring.dbName (1 line) — api-gateway has no DB.
          [config-services/api-gateway/values-stg.yaml:13]

  delete  deploy/keycloak/ empty directory (0 files) — directory exists but
          contains nothing; keycloak.yaml ingress points at nothing.
          [deploy/keycloak/]

  shrink  config-services/*/values-stg.yaml ×5 (150 lines) — 5 near-duplicates
          differing only in image.repository, port, service.name; consolidate
          to 1 values file + service-specific overrides in the generator.
          [config-services/*/values-stg.yaml]

  shrink  deploy/ingress/*.yaml ×7 (126 lines) — 7 identical 18-line Ingress
          manifests; single template with host + service.name parameters.
          [deploy/ingress/]

  shrink  src-services/README.md (240 lines) — duplicates config-services/
          README.md (CI/CD pipeline), docs/guide/SETUP_SUMMARY.md (setup),
          docs/design/usecase-flows.md (testing flow). Reduce to pointer doc.
          [src-services/README.md]

  shrink  10 duplicated classes across 3-4 services (800+ lines) —
          HttpLogService, LoggingAspect, FormatRestResponse, ApiMessage,
          BaseEntity, HttpLog, HttpLogDirection, ReadableLogstashEncoder,
          GsonConfig, HttpClientConfig each copied 3×; extract to shared
          grader-common module or delete duplicates.
          [src-services/*/src/main/java/**/]

  shrink  docs/deploy-concepts.md (637 lines) — 637 lines of generic K8s
          concepts (what is a Pod, Deployment, Service) available in any
          tutorial; project-specific value is in the inline YAML comments.
          [docs/deploy-concepts.md]

  shrink  deploy/observability/charts/kube-prometheus-stack-values.yaml
          Alertmanager section (70 lines) — full Alertmanager config with
          placeholder credentials (CHANGE_ME, your-email@example.com) for
          an 8GB dev k3s cluster; the chart defaults are sufficient.
          [deploy/observability/charts/kube-prometheus-stack-values.yaml]

  shrink  deploy/observability/manifests/monitoring/trace-generator.yaml
          (53 lines) — k6 synthetic-traffic Deployment on an 8GB RAM box;
          traces can be generated locally without a cluster resource.
          [deploy/observability/manifests/monitoring/trace-generator.yaml]

  shrink  [DONE 2026-09-12] GradingOrchestrator.deleteRecursively() (20 lines) —
          inlined in finally block; removed method.
          [executor-service/.../GradingOrchestrator.java]

  shrink  [DONE 2026-09-12] GradingOrchestrator.messageOf() + truncate() (10 lines) —
          inlined; removed both methods.
          [executor-service/.../GradingOrchestrator.java]

  shrink  [DONE 2026-09-12] GradingOrchestrator.toItem() + skippedItem() (22 lines) —
          merged into stepItem(plan, step, result, passed, errorMessage);
          removed both, added one.
          [executor-service/.../GradingOrchestrator.java]

  shrink  [DONE 2026-09-12] GradingOrchestrator.persistSkipped() (3 lines) —
          inlined to persist(job, plan, step, SKIPPED, ...); removed.
          [executor-service/.../GradingOrchestrator.java]

  shrink  [DONE 2026-09-12] GradingOrchestrator.transition() (8 lines) —
          inlined at 3 call sites; removed method.
          [executor-service/.../GradingOrchestrator.java]

  shrink  [PARTIAL] GradingOrchestrator.nz() — `nz(Integer, int)` kept
          (Java can't merge int/long overloads cleanly); `nz(Integer, long)`
          kept for long cases. Net: 1 overload removed.
          [executor-service/.../GradingOrchestrator.java]

  shrink  Frontend App.tsx social-link <li> blocks (49 lines) — 5 repeated
          <li><a><svg><use></a></li> blocks; map over array of {href, icon, label}.
          [frontend-src/web-grading-system-fe/src/App.tsx:63-113]

  shrink  Frontend App.css + index.css media queries (45 lines) — 9 repeated
          @media (max-width: 1024px) blocks; consolidate into one.
          [frontend-src/web-grading-system-fe/src/App.css, index.css]

  shrink  Frontend index.css code, .counter grouping (6 lines) — code (inline
          text) and .counter (button) grouped; code gets wrong display:
          inline-flex; split rules.
          [frontend-src/web-grading-system-fe/src/index.css:99]

  shrink  Frontend App.css place-content/place-items (5 lines) — on flex
          container, equivalent to align-items/justify-content; simplify.
          [frontend-src/web-grading-system-fe/src/App.css:60-65]

  shrink  Frontend App.tsx <section id="spacer"> + <div className="ticks">
          (22 lines) — 2 empty DOM elements + 18 lines CSS for spacing/
          decorative triangles; replace with CSS margin/pseudo-element.
          [frontend-src/web-grading-system-fe/src/App.tsx:33,117]

  yagni  GradingOrchestrator.gate Semaphore(1) — @Async thread pool already
          handles concurrency; synchronized on 'this' is simpler.
          [executor-service/.../GradingOrchestrator.java:68]

  yagni  StepExecutor interface (1 impl: HttpStepExecutor) — concrete class
          directly.
          [executor-service/.../service/step/StepExecutor.java]

  yagni  EventHandler interface (1 impl: GradeSubmissionHandler) — concrete
          class directly.
          [executor-service/.../event/EventHandler.java]

  yagni  StepRegistry (1 type: HTTP_REQUEST) — instantiate HttpStepExecutor
          directly where needed.
          [executor-service/.../service/step/StepRegistry.java]

  yagni  GsonConfig bean ×3 — project uses tools.jackson as primary mapper;
          adds unnecessary Gson dependency.
          [*/config/GsonConfig.java]

  yagni  HttpClientConfig bean — Spring Boot auto-configures HttpClient.
          [executor-service/.../config/HttpClientConfig.java]

  yagni  OpenApiConfig ×3 — springdoc auto-configures; only useful if
          swagger-ui is actively used.
          [*/config/OpenApiConfig.java]

  yagni  LoggingFeignClient implements Feign Client — Feign RequestInterceptor
          is the native extension point.
          [executor-service/.../config/LoggingFeignClient.java]

  yagni  ResultServiceClient.AverageRequest record + weighted() method —
          referenced by course-service but no weighted endpoint exists;
          dead code from a removed feature.
          [course-service/.../client/ResultServiceClient.java]

  yagni  WgsEvent<T> generic envelope — only GRADE_SUBMISSION action exists;
          simple sealed class or record suffices.
          [executor-service/.../event/WgsEvent.java]

  stdlib  GradingOrchestrator.deleteRecursively() — Files.walk +
          Comparator.reverseOrder() loop; simple Files.deleteIfExists
          loop in try-with-resources is shorter.
          [executor-service/.../GradingOrchestrator.java:445]

  stdlib  GradingOrchestrator.messageOf(Exception) — Exception.toString()
          already returns message + cause; null check is redundant.
          [executor-service/.../GradingOrchestrator.java:434]

  stdlib  GradingOrchestrator.truncate() — String::substring with ternary;
          no utility class needed.
          [executor-service/.../GradingOrchestrator.java:438]

  stdlib  VariableContext.substitute() — custom ${var} regex replacement;
          java.text.MessageFormat or String.replace covers it.
          [executor-service/.../service/VariableContext.java]

  stdlib  GsonStructureComparator.sameStructure() — Jackson JsonNode.equals()
          compares structure; custom deep comparison is redundant.
          [executor-service/.../util/GsonStructureComparator.java]

  stdlib  ClassService.parseCsv() — naive string split; OpenCVS or
          Apache Commons CSV is standard.
          [course-service/.../service/ClassService.java:138]

  stdlib  GradingOrchestrator.MAX_SCORE new BigDecimal("10.00") —
          BigDecimal.TEN exists.
          [executor-service/.../GradingOrchestrator.java:52]

  stdlib  ScoreService.ONE static constant — BigDecimal.ONE used inline
          everywhere else.
          [course-service/.../service/ScoreService.java:28]

  stdlib  GradingOrchestrator.nz() overloaded methods — Optional.ofNullable
          or Math.max is more idiomatic.
          [executor-service/.../GradingOrchestrator.java:426]

  native  RustFSService.registerWebhookNotification() creates inline S3Client
          with AwsBasicCredentials — MinioClient already handles S3-compatible
          ops; adds unnecessary AWS SDK dependency.
          [submission-service/.../service/RustFSService.java:82]

  native  3 identical ReadableLogstashEncoder classes — identical copy in
          executor, result, course, api-gateway; extract to shared module.
          [executor-service/.../config/ReadableLogstashEncoder.java]

  fix   config-services/generate-charts.sh line 19 — maps course-service
          to port 8085 and assignment_db; actual values-stg.yaml has
          port 8081; generator produces configs that don't match.
          [config-services/generate-charts.sh:19]

  net   ~8,200 lines removable (excluding GradingOrchestrator shrink)
  GradingOrchestrator.java: 462 → 426 lines (−36, all 6 shrink cuts applied)
  net   ~12 dependencies removable (Gson ×3, springdoc-openapi ×3,
        aws-java-sdk-s3, httpclient explicit, springdoc-openapi-ui if unused)

  Largest 3 cuts alone: docs/architecture/architecture.md (3202) +
  3 ephemeral guide reports (789) + 10 duplicated service classes (~800) =
  ~4,800 lines from 3 files/groups.
```

---

## Priority order to act

1. **`docs/architecture/architecture.md`** — delete (3202 lines, superseded)
2. **`config-services/generate-charts.sh`** — fix port bug (done, see `generate-charts-fix.md`)
3. **`config-services/*/templates/*`** — keep 1 copy, delete 4 (248 lines)
4. **`config-services/*/README.md`** — delete 4, keep 1 (88 lines)
5. **`docs/guide/WORKFLOW_ANALYSIS_REPORT.md` + `FIX_COMPLETED_SUMMARY.md` + `TEST_RUN_SUMMARY.md`** — delete (789 lines, ephemeral)
6. **`docs/idea/idea.md` + `docs/idea/nghiepvu.md`** — delete (167 lines, superseded)
7. **`deploy/argocd-apps/generated/*.yaml`** — delete (115 lines, gitignored)
8. **`deploy/ingress/notification-service.yaml` + `keycloak.yaml`** — delete (36 lines, reference non-existent services)
9. **`config-services/.github/workflows/pullfrog.yml`** — delete (67 lines, experimental)
10. **Duplicate classes across services** — extract to shared `grader-common` module or delete (800+ lines)

## Dependencies to evaluate removing

| Dependency | Where | Why |
|---|---|---|
| `com.google.code.gson:gson` | executor, submission, course services | Project uses `tools.jackson` as primary mapper |
| `org.springdoc:springdoc-openapi-starter-webmvc-ui` | executor, submission, course | Only useful if swagger-ui is actively used |
| `software.amazon.awssdk:s3` (via `RustFSService`) | submission-service | `MinioClient` already handles S3-compatible ops |
| `org.apache.httpcomponents:httpclient` (explicit) | executor-service | Spring Boot auto-configures HttpClient |
