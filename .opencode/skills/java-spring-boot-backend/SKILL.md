---
name: java-spring-boot-backend
description: Spring Boot backend coding conventions for this project's Java microservices - use when writing or reviewing controllers, DTOs, exception handlers, MapStruct mappers, repositories, or file uploads in src-services/*. Covers ApiResponse envelope, FormatRestResponse auto-wrapping, GlobalExceptionHandler catalog, soft delete with SQLRestriction, MapStruct setup.
---

# Java Spring Boot backend conventions

Applies to all services under `src-services/` (course-service, submission-service,
result-service, executor-service; api-gateway only routes and produces no JSON DTOs).
Each service is an independent Maven project — shared classes are duplicated per
service with only the package changed (no shared module).

Canonical examples live in course-service unless noted. Copy them, don't reinvent.

## 1. Response envelope: ApiResponse<T>

Every client-facing endpoint returns this shape on the wire:

```json
{ "status": 200, "message": "Class created", "data": { }, "error": null }
```

- `status`: real HTTP status as int. `message`: success text or error explanation.
  `error`: short error detail, null on success. `data`: payload, null on error.
- `@JsonInclude(JsonInclude.Include.NON_NULL)` — null fields are omitted from JSON.
- Static factories only: `ApiResponse.ok(data)`, `ok(data, message)`, `error(status, message, errorDetail)`.
- File: `dto/response/ApiResponse.java`.

NEVER wrap responses manually in controllers. See section 2.

## 2. Auto-wrapping via FormatRestResponse (ResponseBodyAdvice)

Controllers return plain types — `ResponseEntity<SomeResponse>`, `Page<SomeResponse>`,
or even `ResponseEntity<Void>`. The advice wraps everything automatically:

- Reads the real HTTP status from the servlet response (`201 Created` works).
- Plain body → `ApiResponse` with status + `@ApiMessage("...")` value or default `"Success"`.
- `Page<T>` body → pagination lives INSIDE data:
  ```json
  "data": { "meta": { "page": 0, "pageSize": 20, "pages": 3, "total": 42 },
            "result": [ ... ] }
  ```
  Built by `ResultPaginationDTO.from(page)` (meta fields: page, pageSize, pages=ceil(total/size), total).
  Controllers just return `Page<T>` — zero pagination code per endpoint.
- Pass-through untouched: bodies already of type `ApiResponse` (exception handler output),
  `String`, `org.springframework.core.io.Resource`, and excluded paths:
  `/api/v1/internal/**`, any `*webhook*` path, `*/health`, `*/version`
  (Feign targets, RustFS callbacks, CI probes must stay raw).
- File-streaming endpoints (`void` + HttpServletResponse) never reach the advice.

Files: `util/FormatRestResponse.java`, `util/annotation/ApiMessage.java`,
`dto/response/ResultPaginationDTO.java`. Add a custom success message with
`@ApiMessage("Students imported")` on the handler method.

## 3. GlobalExceptionHandler catalog

One `@RestControllerAdvice` class per service (`exception/GlobalExceptionHandler.java`),
returning `ApiResponse.error(...)` for every case:

| Exception | HTTP | Notes |
|---|---|---|
| `ResourceNotFoundException` | 404 | entity lookup misses |
| `BadRequestException` / `IllegalArgumentException` | 400 | business rule violations |
| `MethodArgumentNotValidException` | 400 | join field errors into `error` detail |
| `HandlerMethodValidationException` | 400 | Spring 6.1+ routes container-element validation (`List<@Valid T>`) here — MUST be handled or it falls to 500. Detail must include position + field, e.g. `[1].score: must be >= 0.00` (use `getParameterValidationResults()`; `ParameterErrors` → `FieldError.getField()` + `getContainerIndex()`) |
| `ConstraintViolationException` | 400 | |
| `HttpMessageNotReadableException` | 400 | malformed JSON body |
| `MethodArgumentTypeMismatchException` | 400 | bad UUID/path param |
| `MaxUploadSizeExceededException` | 413 | keep BEFORE generic MultipartException handler |
| `MissingServletRequestPartException` | 400 | include part name |
| `MultipartException` | 400 | malformed multipart body |
| `HttpRequestMethodNotSupportedException` | 405 | wrong HTTP verb |
| `MissingServletRequestParameterException` | 400 | includes missing param name |
| `HttpMediaTypeNotSupportedException` | 415 | unsupported Content-Type |
| `NoResourceFoundException` | 404 | unknown URL path |
| `Exception` | 500 | log full stack server-side, return generic message — keep LAST, it swallows everything unhandled |

Rules:
- Custom exceptions are tiny: `ResourceNotFoundException`, `BadRequestException`
  (`extends RuntimeException`, one String constructor).
- Services throw these instead of bare `RuntimeException` for expected failures.
- All error responses use the same envelope — never ad-hoc `{error: ...}` maps.

## 4. Soft delete

`BaseEntity` provides `id` (`@UuidGenerator`), `createdAt`, `updatedAt`, `deletedAt`.

- Annotate every BUSINESS entity with `@SQLRestriction("deleted_at IS NULL")`
  (`org.hibernate.annotations.SQLRestriction`, Hibernate 6+/7 — not deprecated `@Where`).
- NEVER annotate log tables (`HttpLog`) or similar non-domain entities.
- NEVER write `...AndDeletedAtIsNull` in repository derived-query names — the
  restriction appends the filter to every JPA read automatically.
- Delete = `entity.setDeletedAt(OffsetDateTime.now())` + save. Never hard DELETE.
- Caveat: soft-deleted rows are invisible to ALL JPA reads; reading them back
  requires native SQL.

## 5. Mapping with MapStruct

pom.xml wiring per service (this exact setup avoids the Lombok processor clash):

- Properties: `<mapstruct.version>1.6.3</mapstruct.version>`
- Dependency: `org.mapstruct:mapstruct:${mapstruct.version}`
- `maven-compiler-plugin` has TWO executions (`default-compile` AND `default-testCompile`);
  each `annotationProcessorPaths` lists, in order: lombok →
  `org.projectlombok:lombok-mapstruct-binding:0.2.0` → `org.mapstruct:mapstruct-processor`.

Mappers (`mapper/` package):

```java
@Mapper(componentModel = "spring")
public interface ClassMapper {
    ClassResponse toResponse(CourseClass courseClass);
}
```

- Inject mappers via Lombok `@RequiredArgsConstructor` final fields in services.
- Pure entity→DTO field copies go through mappers (enum→String maps via `.name()` automatically).
- Computed/composite assembly (totals, entries combining several sources) stays hand-written —
  do not force it through MapStruct.
- One style only: NO static `from()` factories on DTOs alongside mappers.
- After pom changes, verify generation: check
  `target/generated-sources/annotations/**/*MapperImpl.java` actually contains field setters.

## 6. Lombok trap: @Qualifier is NOT copied

Lombok's generated constructor does not carry field annotations. Two `MinioClient`
beans + `@Qualifier` on a final field silently injects the `@Primary` one everywhere.

Fix (required): write the constructor explicitly with `@Qualifier` on the PARAMETER:

```java
public RustFSService(MinioClient minioClient,
        @Qualifier("publicMinioClient") MinioClient publicMinioClient) {
```

Verify by checking the compiled class has `RuntimeVisibleParameterAnnotations`.

## 7. File upload endpoints

- Configure multipart limits explicitly in `application.yaml` (Spring default is 1MB):
  ```yaml
  servlet:
    multipart:
      max-file-size: 5MB
      max-request-size: 6MB
  ```
- Endpoint takes `@RequestParam("file") MultipartFile file`; Postman sends form-data, key `file`, type File.
- Guard in service before parsing: null/`isEmpty()` → BadRequestException;
  filename must match expected extension (case-insensitive, null-safe).
- Malformed rows are COUNTED as skipped in the result, never silently dropped.
- Stream-read IOException → throw `IllegalStateException` (honest 500), not IllegalArgumentException (would become 400).

## 8. Swagger / OpenAPI (springdoc)

- Boot 4.x requires springdoc **3.x**: `org.springdoc:springdoc-openapi-starter-webmvc-ui:3.1.0`
  (2.x does not support Boot 4). Gateway has no controllers — no springdoc there.
- Per-service `config/OpenApiConfig.java`: `@Bean OpenAPI` with title/version so tabs are
  distinguishable. Docs live at `/swagger-ui.html` (302 → `/swagger-ui/index.html`) and
  `/v3/api-docs` on each service's own port.
- CRITICAL: `FormatRestResponse.isExcluded()` MUST pass through `/v3/api-docs*` and
  `/swagger-ui*` paths — otherwise the advice wraps the OpenAPI JSON in the ApiResponse
  envelope and swagger-ui cannot parse it. Keep the exclusion when editing the advice.
- When Keycloak resource-server security is wired into services, permit docs paths FIRST:
  `.requestMatchers("/v3/api-docs/**", "/swagger-ui/**", "/swagger-ui.html").permitAll()`
  (comment is already inside each OpenApiConfig.java).
- Verified live: raw openapi json at `/v3/api-docs`, UI 200, business endpoints still enveloped.

## 9. Configuration: @ConfigurationProperties, not @Value

- Grouped settings live in a record per prefix in `config/`:
  ```java
  @ConfigurationProperties(prefix = "rustfs")
  public record RustFsProperties(String endpoint, String publicEndpoint,
          String accessKey, String secretKey, String bucketName) {}
  ```
- Registered by `@ConfigurationPropertiesScan` on the application class.
- Env overrides stay in `application.yaml` placeholders (`rustfs.access-key: ${RUSTFS_ACCESS_KEY:minioadmin}`)
  — Java code never references env vars directly; relaxed binding maps env to yaml to record.
- Inject the properties record (constructor/final field), never re-declare the same
  `@Value` fields in multiple classes — one source of truth.
- `@Value` is allowed ONLY for one-offs like `@Value("${spring.application.name}")`
  inside framework-ish beans (e.g. log-pattern decorators).
- Canonical example: submission-service `config/RustFsProperties.java`,
  `config/SubmissionProperties.java`, consumed by `RustFSConfig`, `RustFSService`,
  `SubmissionService`.

## 10. Gotchas

- Boot 4 auto-configures **Jackson 3** (`tools.jackson.databind.ObjectMapper`) — the old
  `com.fasterxml.jackson.databind.ObjectMapper` is NOT a bean anymore. New code injecting
  an ObjectMapper must import from `tools.jackson.databind`. Exceptions are unchecked there,
  so readTree/writeValueAsString need no throws clauses.

- `Map.of(...)` throws NPE on null VALUES — never feed it nullable data
  (e.g. computed averages). Use `Collections.singletonMap(k, v)` or a HashMap.
- Not-found is ALWAYS `ResourceNotFoundException` (404) — never IllegalArgumentException
  for a missing entity (that maps to 400 and splits the contract).
- Derived Spring Data query names validate at BOOTSTRAP, not compile: a wrong property
  in `findBy...` compiles clean but kills startup (`No property 'X' found`). Property
  name follows the FIELD, not the column (`latest`, not `is_latest`).
- Defensive Feign: wrap client calls that degrade gracefully (e.g. exercise score) in
  try/catch -> log.warn + return null, so a dependency outage never fails the whole endpoint.
- ENV OVERRIDES CANNOT CARRY UNDERSCORES INSIDE PACKAGE NAMES: relaxed binding turns
  `LOGGING_LEVEL_VN_EDU_PTIT_WEB_GRADING_SYSTEM` into `vn.edu.ptit.web.grading.system`
  (dots), which matches no logger. Alias instead: yaml
  `vn.edu.ptit.web_grading_system: ${app.log.level:INFO}` + env `APP_LOG_LEVEL`.
- LoggingAspect pointcut covers ONLY @Service + @RestController beans — never
  @ControllerAdvice/@Configuration (actuator/advice tracing is pure noise; Boot 4's
  health handler method is named `handle`, which defeats name-based filters).

## 11. Logging

- Every business service has `util/LoggingAspect.java` (`@Aspect`, spring-boot AOP via
  `org.aspectj:aspectjweaver` — Boot 4 has NO `spring-boot-starter-aop` artifact, add
  aspectjweaver directly, version managed by the BOM).
- Aspect traces at **DEBUG**: `-> Class.method(args)` entry (args truncated to 200 chars,
  MultipartFile summarized as name+size), `<- Class.method (Nms)` exit, `!! ...` ERROR on
  exceptions before rethrow.
- Pointcut covers @Service/@RestController/@ControllerAdvice/@RestControllerAdvice/
  @Configuration beans inside the service package; skips noise: HttpLog* classes,
  OpenApiConfig, health/version methods.
- Targeted business lines go in by hand at **INFO** where they mean something:
  operation start/end with counts (e.g. import results), WARN for rejected
  business rules (e.g. duplicate class creation).
- Log level: root stays INFO; every service yaml sets
  `logging.level.vn.edu.ptit.web_grading_system: DEBUG` so aspect traces appear
  while third-party libs stay INFO.
- Services log JSON to stdout (logback-spring.xml + logstash encoder); locally read the
  console/IntelliJ, in cluster `kubectl logs -n web-grading deploy/<name>` or Loki.

## 11. General conventions

- All updates use `@PutMapping` — NEVER `@PatchMapping` (project-wide convention, keep it uniform).
- Uniqueness: ALWAYS pre-check before insert and fail with a descriptive
  `BadRequestException` (e.g. `"Class 'X' already exists in semester Y"`), even though DB
  unique partial indexes exist. The index is the race-condition backstop only;
  `DataIntegrityViolationException` → 409 CONFLICT is handled in every GlobalExceptionHandler.
  New write endpoints must follow this pattern (pre-check → descriptive error; upsert via
  find-or-create where updates are intended).

- DTO naming: `*Request` / `*Response` in `dto/request`, `dto/response`.
- Thin controllers; business logic in `@Service`; `@Transactional` on writes.
- Validation with jakarta annotations on request DTOs (`@NotBlank`, `@DecimalMin`, ...),
  activated with `@Valid` in the controller.
- List bodies: validate elements via the type argument — `@RequestBody List<@Valid Item>`
  (container-level `@Valid` on a List is deprecated, HV000271). Requires the
  HandlerMethodValidationException handler above.
- Every business service carries `spring-boot-starter-validation`; api-gateway does not
  (no request bodies).
- Identity: `X-User-Id` header (until Keycloak integration injects it at the gateway);
   no endpoint trusts client-sent identity beyond that header today.
- Student-facing read endpoints live under `/api/v1/student/**` (gateway routes them to
   course-service). They are enrollment + `published` gated via `class_students.student_user_id`
   and sanitize `test_steps.config` (strip `connection`/`extract`/`expected`, drop
   `DELAY`/`EXTRACT` steps) so grading internals/credentials never reach students.
- `test_steps.description` = nullable lecturer-authored problem-set note. FE prefers it
   verbatim over auto-generated text derived from `config` (fallback only when empty).
- Per-plan submission: `submissions.planId` optional; `null` ⇒ executor grades all plans,
   set ⇒ only that plan. `results.is_latest` is unique per `(student_id, assignment_id, plan_id)`
   and `results.plan_weight` carries `test_plans.weight` so the assignment exercise score
   is the weight-weighted average of per-plan scores (`ResultService.weightedScoreByPlan`).
- Internal service-to-service APIs under `/api/v1/internal/**`: plain DTOs, no envelope,
  called via OpenFeign (`@EnableFeignClients` already on every application class).
  Gateway never routes internal paths.
- Feign target URLs NEVER carry env defaults inline in `@FeignClient`. The URL lives in
  `application.yaml` under a `feign:` block that references the env var, and the annotation
  references only the property:
  ```yaml
  feign:
    result-service:
      url: ${RESULT_SERVICE_URI:http://grading-result-service:8084}
  ```
  ```java
  @FeignClient(name = "result-service", url = "${feign.result-service.url}")
  ```
  For local runs add the env var (e.g. `RESULT_SERVICE_URI=http://localhost:8084`) to the
  service's `.env` file.
- Health/version/webhook endpoints stay raw (probe and CI contracts).
- Tests: small plain-JUnit tests next to the logic they cover (static helpers tested directly,
  pure logic with Mockito mocks); no heavyweight test infra. Run:
  `./mvnw test -Dtest='ClassName'` inside the service directory.
- Compile check per service: `./mvnw -q compile` from `src-services/<service>/`.

## 12. Definition of done — test before reporting

MANDATORY before telling the user a task is done:

1. **Unit tests**: cover every new/changed logic branch — boundaries, error paths,
   and edge cases (empty / null / invalid input / duplicates), not just the happy path.
   Style per §11: plain JUnit + Mockito, static helpers tested directly.
2. **Integration tests (when needed)**: if the change touches component wiring —
   controllers, repositories, Feign clients, config binding, file upload, messaging —
   verify real behavior by booting the service and exercising the actual endpoint
   (curl/Postman, check HTTP status + ApiResponse envelope), or a @SpringBootTest
   when a DB is reachable. Compile success is NOT verification.
3. **Regression**: re-run all existing tests for every touched service
   (`./mvnw test -Dtest='…'`) and fix or explain any failure — never ship with
   silently broken pre-existing tests.
4. **Report honestly**: state what was tested, how, and the result counts in the
   completion message ("verified live: 200 …", "7/7 tests pass"). If something could
   NOT be verified (e.g. no local DB), say so explicitly instead of claiming done.

5. **Postman collection is part of done**: every new public endpoint (and every
    changed endpoint's new param/behavior) gets a request in
    `src-services/docs/api/postman/Web grading service.postman_collection.json` under
    its service folder, with a saved **real** `response` for the happy path (200/201)
    **and** at least one error case (e.g. 404 Not Found, 400). Capture the bodies from
    a live boot of the service — never hand-write or guess response JSON. Internal
    `/api/v1/internal/**` endpoints are included when they have a caller contract worth
    exercising (e.g. `POST /api/v1/internal/results/weighted`). If the service cannot
    be booted in the environment, add the request definition (method/URL/headers/body)
    but leave `response` empty and say so — do not fabricate responses.
6. **No all-args positional constructors**: every record constructor call with more
    than 2 positional arguments must use a builder (`X.builder().field(val)...build()`)
    or a named static factory method. This applies at all call sites AND inside helper
    methods. Use `@Builder` on the record (already configured project-wide via Lombok).
    See §§12.6–12.7 for the full rule and examples.

## 12.6. No all-args positional constructors (mandatory)

Every record/POJO constructor call with more than 2 positional arguments must
use Lombok `@Builder` and the builder pattern. Do NOT write:
```java
new MyDto(a.getId(), a.getName(), a.getType(), a.getConfig(), a.getWeight())
```
Do write one of:
```java
// builder inline
MyDto.builder().id(a.getId()).name(a.getName()).type(a.getType())
      .config(a.getConfig()).weight(a.getWeight()).build();
```

## 12.7. Named factory method (recommended)

When the same construction pattern is reused in a stream or helper, extract a
`static X of(Entity e)` method on the DTO (if it does not import the entity,
which would cause a circular dependency):
```java
public static MyDto of(Entity e) {
    return builder().id(e.getId()).name(e.getName())...build();
}
```
Then call sites read `.map(MyDto::of)` instead of a long lambda.
Factories go on the DTO when no entity import is needed; otherwise put the
builder chain directly at the call site in the service.
The rule triggers at >2 positional args — 1-2 arg constructors are fine as-is.

## 13. Verification

- Compile success is NOT verification. Tests must pass (`./mvnw test`).
- If the local Postgres container is not running, tests will fail with
  `FATAL: database does not exist` — start it and re-run.
- Pre-existing broken services (e.g. `submission-service`'s missing
  `KafkaTemplate<String, WgsEvent<?>>` bean) are known blockers; document
  them, do not fabricate responses.

## 14. Typed KafkaTemplate for generic event types (mandatory)

When a service uses `KafkaTemplate<String, CustomEvent<?>>` (typed generic),
Spring Kafka auto-config only creates `KafkaTemplate<String, Object>`.
This causes `No qualifying bean of type 'KafkaTemplate<String, CustomEvent<?>>'`.

Fix: create a `KafkaConfig` class in the service's `config/` package that
provides a typed `ProducerFactory` and `KafkaTemplate` bean.
The `application.yaml` already has `spring.kafka.*` properties — read them
with `@Value` and reuse:

```java
@Configuration
public class KafkaConfig {
    @Bean
    public ProducerFactory<String, MyEvent<?>> producerFactory() {
        Map<String, Object> props = new HashMap<>();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put("security.protocol", securityProtocol);
        props.put("sasl.mechanism", saslMechanism);
        props.put("sasl.jaas.config", saslJaasConfig);
        props.put("ssl.truststore.location", sslTruststoreLocation);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, JsonSerializer.class);
        return new DefaultKafkaProducerFactory<>(props);
    }
    @Bean
    public KafkaTemplate<String, MyEvent<?>> kafkaTemplate() {
        return new KafkaTemplate<>(producerFactory());
    }
}
```

Properties come from `application.yaml` (`spring.kafka.bootstrap-servers`,
`spring.kafka.properties.*`, `spring.kafka.producer.*`).
Use `org.apache.kafka.common.serialization.StringSerializer` for keys.
The `JsonSerializer` handles the custom event type via Jackson.

See `src-services/submission-service/src/main/java/.../config/KafkaConfig.java` for a working example.
