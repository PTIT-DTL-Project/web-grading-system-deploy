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
- Feign `Client`-wrapping @Bean (e.g. audit-logging decorator) must NEVER take an
  injected `Client delegate` parameter: a `@FeignClient(configuration=...)` class runs
  in each client's child context where the wrapper is the SOLE `Client` candidate, so
  the parameter self-resolves -> `BeanCurrentlyInCreationException` at startup.
  Construct the delegate inline instead: `new Client.Default(null, null)` (exactly what
  the framework supplies here — no hc5/okhttp/loadbalancer Client customizations).

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

## 11.5. Inbound http_log via HttpLoggingFilter (mandatory pattern)

- Every business service persists one INBOUND `http_log` row per request via
  `config/HttpLoggingFilter.java` (`@Component extends OncePerRequestFilter`,
  auto-registered; no HandlerInterceptor — interceptors cannot capture bodies).
- Shape: wrap in `ContentCachingRequestWrapper(request, 32*1024)` +
  `ContentCachingResponseWrapper`; `chain.doFilter`; build with `HttpLog.builder()`
  (`direction=INBOUND`, url via `sanitizeUrl()`, headers via `headersToJson()`,
  bodies via `truncate()`, `port=getLocalPort()`); `saveLog` guarded so logging
  never breaks the request; `copyBodyToResponse()` in `finally`.
- Spring 7 requires the `(request, contentCacheLimit)` constructor (no no-arg ctor);
  32KB cap bounds memory while `truncate()` enforces the 20KB stored cap.
- Skip request wrapping when `isFileContentType(request.getContentType())`
  (multipart/uploads would be buffered in memory); store null bodies.
- `shouldNotFilter`: `/actuator/*`, `/v3/api-docs*`, `/swagger-ui*`,
  `/swagger-ui.html`, `*/health`, `*/version`. Internal + webhook paths ARE logged.
- Outbound symmetry: every `@FeignClient` gets
  `configuration = FeignLoggingConfiguration.class`; `LoggingFeignClient.saveLog`
  stores `responseHeaders` too; Feign config constructs `new Client.Default(null, null)`
  inline, never injects `Client delegate` (startup cycle — see §10).
- Test per filter with `MockHttpServletRequest/Response` + lambda `FilterChain`
  (cast `res` to `HttpServletResponse`): INBOUND row content, exclusions skipped,
  multipart unwrapped + null body, `save()` throw still returns response.

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
The `application.yaml` already has `spring.kafka.*` properties — inject them via a
`@ConfigurationProperties` record instead of `@Value`:

```java
@Configuration
public class KafkaConfig {
    private final KafkaProperties props;

    public KafkaConfig(KafkaProperties props) { this.props = props; }

    @Bean
    public ProducerFactory<String, MyEvent<?>> producerFactory() {
        Map<String, Object> propsMap = new HashMap<>();
        propsMap.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, props.bootstrapServers());
        String jaasConfig = props.properties().sasl().jaas().config();
        if (jaasConfig != null && !jaasConfig.isBlank()) {
            propsMap.put("sasl.jaas.config", jaasConfig);
        }
        propsMap.put("security.protocol", props.properties().security().protocol());
        propsMap.put("sasl.mechanism", props.properties().sasl().mechanism());
        propsMap.put("ssl.endpoint.identification.algorithm",
                props.properties().ssl().endpoint().identification().algorithm());
        propsMap.put("ssl.truststore.type", props.properties().ssl().truststore().type());
        propsMap.put("ssl.truststore.location",
                props.properties().ssl().truststore().location());
        propsMap.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class);
        propsMap.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, JsonSerializer.class);
        return new DefaultKafkaProducerFactory<>(propsMap);
    }
    @Bean
    public KafkaTemplate<String, MyEvent<?>> kafkaTemplate() {
        return new KafkaTemplate<>(producerFactory());
    }
}

// Binds spring.kafka.properties.* / spring.kafka.producer.* — keep the record
// shape aligned with application.yaml or keys silently bind null. Compact
// constructors supply per-node defaults so a dropped yaml subtree degrades
// to defaults instead of NPEing on the next deref.
@ConfigurationProperties(prefix = "spring.kafka")
public record KafkaProperties(
    String bootstrapServers,
    Properties properties,
    Producer producer
) {
    public KafkaProperties {
        if (bootstrapServers == null) bootstrapServers = "localhost:9092";
        if (properties == null) properties = new Properties(null, null, null);
        if (producer == null) producer = new Producer(null, null);
    }
    public record Properties(Security security, Sasl sasl, Ssl ssl) {
        public Properties {
            if (security == null) security = new Security(null);
            if (sasl == null) sasl = new Sasl(null, null);
            if (ssl == null) ssl = new Ssl(null, null);
        }
    }
    public record Security(String protocol) {
        public Security {
            if (protocol == null) protocol = "SASL_SSL";
        }
    }
    public record Sasl(String mechanism, Jaas jaas) {
        public Sasl {
            if (mechanism == null) mechanism = "SCRAM-SHA-256";
            if (jaas == null) jaas = new Jaas(null);
        }
    }
    public record Jaas(String config) {
        public Jaas {
            if (config == null) config = "";
        }
    }
    public record Ssl(Endpoint endpoint, Truststore truststore) {
        public Ssl {
            if (endpoint == null) endpoint = new Endpoint(null);
            if (truststore == null) truststore = new Truststore(null, null);
        }
    }
    public record Endpoint(Identification identification) {
        public Endpoint {
            if (identification == null) identification = new Identification(null);
        }
    }
    public record Identification(String algorithm) {
        public Identification {
            if (algorithm == null) algorithm = "https";
        }
    }
    public record Truststore(String type, String location) {
        public Truststore {
            if (type == null) type = "PEM";
            if (location == null) location = "docker/kafka-ca.pem";
        }
    }
    public record Producer(String acks, Integer retries) {
        public Producer {
            if (acks == null) acks = "all";
            if (retries == null) retries = 3;
        }
    }
}
```

Properties come from `application.yaml` (`spring.kafka.bootstrap-servers`,
`spring.kafka.properties.*`, `spring.kafka.producer.*`).
Use `org.apache.kafka.common.serialization.StringSerializer` for keys.
The `JsonSerializer` handles the custom event type via Jackson.
Cover the binding with a test (`ApplicationContextRunner` + property values
mirroring `application.yaml`, asserting the producer config map — notably
`sasl.jaas.config`, `acks`, `retries`) so a record/yaml shape drift fails
fast instead of silently publishing with nulls.

See `src-services/submission-service/src/main/java/.../config/KafkaConfig.java` for a working example.

## 15. Kafka consumers need @EnableKafka + manual factory (mandatory)

Boot 4 ships NO Kafka auto-configuration (`spring-boot-autoconfigure` contains
zero Kafka classes) and spring-kafka 4.x provides none either — its
`KafkaBootstrapConfiguration` registers ONLY the annotation processor + endpoint
registry, and only when `@EnableKafka` is present. Without it, `@KafkaListener`
methods are silently ignored: context boots fine, no container, no consumer,
zero log output (not even at DEBUG). Verified via jar inspection + bytecode.

Every consuming service therefore needs BOTH (see executor-service
`config/KafkaConfig.java`):

1. `@EnableKafka` on the application class.
2. A `config/KafkaConfig.java` with `ConsumerFactory<String, String>` and a
   `ConcurrentKafkaListenerContainerFactory<String, String>` bean named exactly
   `kafkaListenerContainerFactory` (the default name the post-processor looks up).
   Read props from a `@ConfigurationProperties(prefix = "spring.kafka")` record
   (see §14 for the pattern), never `@Value`. Use
   kafka-clients config constants (`ConsumerConfig.*`, `SslConfigs.*`,
   `SaslConfigs.*`, `CommonClientConfigs.*`), never raw strings. Omit blank
   `sasl.jaas.config` (local runs leave `KAFKA_USERNAME`/`KAFKA_PASSWORD` empty).
   Ack mode via `ContainerProperties.AckMode.valueOf(ackMode)` so yaml stays
   the single source of truth.

Tests must construct `KafkaConfig` via `new KafkaConfig(new KafkaProperties(...))`
— the class has no no-arg constructor. Build a full `KafkaProperties` record
and pass it through the constructor; do NOT use `ReflectionTestUtils.setField()`
on `KafkaConfig` fields (they live on `KafkaProperties`). See
`src-services/executor-service/src/test/java/.../config/KafkaConfigTest.java`.

## 15.5. Executor service production patterns (mandatory)

**Testcontainers must use the containerized constructor.** The
`ComposeContainer(File)` constructor puts testcontainers in Local Compose
mode which requires a host `docker` CLI binary. The runtime image
(`eclipse-temurin:21-jre`) ships no `docker`, so every grading job's boot
step fails. Always use:
```java
new ComposeContainer(new DockerImageName("docker:25.0.5"), composeFile.toFile())
```
Add `import org.testcontainers.utility.DockerImageName`.

**@Async must use a dedicated TaskExecutor with explicit rejection.** Boot's default `applicationTaskExecutor`
has core=8 and unbounded queue, which violates the single-job DinD gate
(§15). Define a bean in the application class:
```java
@Bean(name = "gradingTaskExecutor")
public Executor gradingTaskExecutor() {
    ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
    executor.setCorePoolSize(1);
    executor.setMaxPoolSize(1);
    executor.setQueueCapacity(10);
    executor.setThreadNamePrefix("grading-");
    executor.initialize();
    return executor;
}
```
Then annotate `@Async("gradingTaskExecutor")` on the grading method.
Keep the default `AbortPolicy` — NEVER `CallerRunsPolicy`: it runs a full
grading inline on the caller thread, which blocks the single Kafka listener
thread past `max.poll.interval.ms` (consumer rebalance) and breaks the gate.
Instead catch `org.springframework.core.task.TaskRejectedException` at every
`gradeAsync` call site (consumer handler, reaper, reset controller): log a
warning and leave the job `PENDING` — the 5-min reaper recovers it.

**StaleJobReaper must never reap RUNNING.** Wall-clock alone cannot tell a live
worker from a dead one, so re-enqueueing `RUNNING` double-grades live jobs
(`startedAt` is stamped at FETCHING onset and the true budget lives in
per-assignment config the reaper can't see). Keep `RUNNING` out of `ACTIVE`.
A dead-`RUNNING` job recovers via manual reset: `ResetGradingJobService.reset()`
accepts every non-terminal status (`PENDING/FETCHING/BUILDING/RUNNING/FAILED`)
and refuses only `DONE` (re-grading it would post a duplicate result row).
Enforce the documented invariant instead: `stale-after-minutes` must exceed
startup + execution timeouts. Saturated reaper submits must NOT burn a retry:
increment `retryCount` only after `gradeAsync` accepts the task.

**StepRegistry must throw IllegalArgumentException.** `GradingOrchestrator.runStep`
catches `IllegalArgumentException` around `stepRegistry.of(...)`. If
`StepRegistry.of()` throws `IllegalStateException`, the guard is dead and
unknown step types abort the whole job with a misleading message.

**ResetResult must carry the GradingJob.** Controllers and event handlers
need the stored job fields (assignmentId, studentId, planId, rustfsPath)
to re-grade correctly — they must not come from the caller's request body.
`ResetResult` carries both the `jobId` and the `GradingJob` object so
callers read fields from the stored data.

**Saga cleanup must delete steps for ALL sagas.** `GradingSagaRepository.findByJobId`
returns a `List<GradingSaga>` (a job can have multiple sagas across attempts).
Iterate the list and delete steps for each saga, not just `findFirstByJobId`.

**firstServiceWithPorts must identify the app service.** A typical student
compose has both a DB and an app service publishing ports. Picking the first
with ports often selects the DB. Use a heuristic that excludes database-named
services (name contains "db", "database", "postgres", "mysql", "mongo", "redis", "kafka").

**Zip extraction drops Unix mode bits — restore wrapper +x.** `java.util.zip`
unzipping ignores entry permissions, so `mvnw`/`gradlew` (755 in git) land
644 in the grading work dir and the DinD `docker build` dies at `RUN ./mvnw`
with "Permission denied" (exit 126). `ArtifactService` re-applies `rwxr-xr-x`
to those two names at the workdir root right after unzip, best-effort only
(never fail grading on a chmod error). Fix belongs in the executor, not the
student Dockerfile — submissions bring their own Dockerfiles.

**Wrapper-only distributionUrls are rewritten to a pinned full Maven.**
Published `maven-wrapper-distribution` artifacts (≈65KB, scripts + wrapper
jar only) contain no Maven binaries, so any submission pointing at one fails
its build deterministically. `ArtifactService` rewrites such URLs to
`executor.maven.pinned-distribution-url` (default: full `apache-maven-3.9.9`)
and drops a stale `distributionSha256Sum` alongside; full-Maven URLs, Gradle
and wrapper-less projects pass through untouched; blank pin disables the
rewrite. Bump the pin deliberately via config/env (`EXECUTOR_MAVEN_PINNED_URL`) —
never resolve "latest" at runtime, grading must stay reproducible.

**Result posting must retry with backoff, skipping validation errors.** `postResult` attempts delivery up to 3 times
with a linear backoff (`attempt * 2000L` ms) between attempts, since tight
retries complete in milliseconds and never outlast a transient outage.
Skip retry on deterministic client errors: a `feign.FeignException` with a
4xx status other than 408/429 is logged once and returned (retrying a
validation 400 just re-posts the same rejected body). Interrupt during sleep
restores the flag and stops retrying.

## 16. Internal reset/rerun API for FAILED grading jobs (mandatory)

`GradeSubmissionHandler` catches `DataIntegrityViolationException` on
`uk_grading_jobs_submission` and previously just logged "skipping" —
FAILED jobs were permanently stuck. Now the handler calls
`ResetGradingJobService.reset()` which resets the job + saga + saga steps
+ step results to allow re-execution.

Every consuming service with a unique constraint on a business key
needs a reset mechanism:

1. **`controller/ResetXxxController.java`** — `@RestController` at
   `/api/v1/internal/grading-jobs` (or the relevant domain), one
   `@PostMapping("/{submissionId}/reset")` accepting a request body with
   the original event params.
2. **`service/ResetXxxService.java`** — `@Transactional` method that:
   - Finds the existing row by business key, returns false if not FAILED
   - Deletes all `grading_step_results` for the job
   - Resets the saga (`resetByJobId` to `STARTED`) and deletes saga steps
   - Resets the job to `PENDING`, clears `errorMessage`/`startedAt`/`completedAt`, increments `retryCount`
   - Does NOT call `gradeAsync` inside `@Transactional` (race condition) — returns `ResetResult` to the caller
3. **Caller calls `gradeAsync` separately** after `reset()` returns and
   the `@Transactional` commits (done in controller and handler catch block).
4. **`GradingJob` entity** needs `traceId` column (add V6 migration) to
   track the original wgs-events trace for debugging.

Repositories needed: `findBySubmissionId`, `deleteByJobId`,
`findFirstByJobId`, `resetByJobId`, `deleteBySagaId`.

Also update §15 to note: `@Transactional` methods must not call `@Async`
inside the same call stack — call it after the method returns to avoid
reading uncommitted rows in the async thread.

## 17. Utility constant classes must not be instantiable (mandatory)

A utility class containing only nested static constant groups must declare
exactly one private no-argument constructor. Do not add a second constructor
while reorganizing constants; duplicate constructors cause
`'Constant()' is already defined` compilation errors. Prefer an empty private
constructor unless an explicit defensive exception is required by the project.

