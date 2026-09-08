# DinD + Aiven Kafka Plan v1.0

> **Version:** v1.0
> **Date:** 2026-08-27
> **Status:** Current — implemented in this pass
> **Decisions:** SASL **SCRAM-SHA-256** (option 2) over SSL · single generalized
> topic `wgs-events` with `action` envelope · DinD sidecar per executor pod ·
> Kafbat Kafka UI exposed publicly via Cloudflare Zero Trust
> **Related:** system-design-v1.0.md §5 (topics) · execute-plan-v1.0.md §7

---

## 1. Aiven Kafka connection (SASL over TLS)

Service URI: `wc-test-truonggiang.g.aivencloud.com:23886` (public, free tier =
5 topics max, which drove the topic generalization below).

| Piece | Where it lives |
|---|---|
| `ca.pem` | Docker build context only: `src-services/<svc>/docker/kafka-ca.pem` (gitignored); copied by Dockerfile to `/etc/kafka/secrets/kafka-ca.pem`; also mounted as `kafka-aiven-credentials` secret file in k8s |
| username/password | each service `.env` (gitignored) + root `.env.example` placeholders → k8s `kafka-aiven-credentials` secret keys `username`/`password` |
| bootstrap servers | `KAFKA_BOOTSTRAP_SERVERS` env → `spring.kafka.bootstrap-servers` |

**Spring config (both submission-service & executor-service):**

```yaml
spring:
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS:localhost:9092}
    properties:
      security.protocol: SASL_SSL
      sasl.mechanism: SCRAM-SHA-256
      sasl.jaas.config: >
        org.apache.kafka.common.security.scram.ScramLoginModule
        required username="${KAFKA_USERNAME:}" password="${KAFKA_PASSWORD:}";
      ssl.endpoint.identification.algorithm: https
      ssl.truststore.type: PEM
      ssl.truststore.location: file:${KAFKA_CA_PATH:docker/kafka-ca.pem}
```

* Never commit the real `test.txt` or `ca.pem` under resources (deleted,
  `.gitignore` updated: `**/test.txt`, `**/docker/kafka-ca.pem`).

## 2. One topic, action-routed (scalable within free tier)

Topic: **`wgs-events`** (3 partitions, executor-group consumer).

**Envelope:**

```json
{
  "action": "GRADE_SUBMISSION",
  "version": 1,
  "timestamp": "2026-08-27T02:00:00Z",
  "traceId": "...",
  "payload": { "submissionId": "...", "assignmentId": "...", "studentId": "...",
               "planId": null, "rustfsPath": "submissions/...zip" }
}
```

*   `WgsEventAction` enum (producer + consumer copies): `GRADE_SUBMISSION` (default
    for legacy messages missing `action`), `UNKNOWN`.
*   New action = one new `EventHandler` implementing class — **no new topic**.
*   Producer: `WgsEventsProducer.publishGradeSubmission(payload)`, key =
    `submissionId` (per-submission ordering + executor dedupe).
*   Consumer: `WgsEventsConsumer` parses envelope → `Map<WgsEventAction, EventHandler>`
    → dispatch. Unknown actions: WARN + ack (never redeliver-loop).
*   **Idempotency backstop:** `grading_jobs.submission_id` unique index
    (`V2__grading_jobs_submission_unique.sql`). Duplicate redelivery →
    `DataIntegrityViolationException` → handler logs skip.

## 3. DinD sidecar for executor

`config-services/executor-service/templates/deployment.yaml` gets a second
container:

```yaml
- name: dind
  image: docker:27-dind
  securityContext:
    privileged: true
  env:
    - name: DOCKER_TLS_CERTDIR
      value: ""
  volumeMounts:
    - name: dind-storage
      mountPath: /var/lib/docker
```

Main container: `DOCKER_HOST=tcp://localhost:2375`, shared `emptyDir` `dind-storage`.
Resource ceiling per pod ≈ 256Mi main + 256Mi sidecar + student containers.

## 4. Kafbat Kafka UI (public, via Cloudflare Zero Trust)

*   `deploy/kafka-ui/{deployment,service,ingress}.yaml` — image
    `ghcr.io/kafbat/kafka-ui:latest`, ClusterIP `kafka-ui:8080`, reads the same
    `kafka-aiven-credentials` secret (env expansion `$(username)`/`$(password)`),
    mounts `ca.pem` at `/etc/kafka/secrets/ca.pem`.
*   Traefik ingress host `web-dev1-kafka-ui.vucongtuanduong.dpdns.org` →
    namespace `web-grading`.
*   **Manual step (Cloudflare Dash):** Zero Trust → Networks → Tunnels → your
    tunnel → Public Hostname → add `web-dev1-kafka-ui.vucongtuanduong.dpdns.org`
    → service `http://localhost:30195` (Traefik NodePort).
    Not automatable from the repo post-local-cloudflared-removal.

## 5. Verification

1. `kubectl rollout status deploy/grading-executor-service -n web-grading`
   → DinD sidecar active: `kubectl exec ... -c dind -- docker version`
2. Produce message: `POST /api/v1/submissions/{id}/confirm` (after zip upload)
   → message on `wgs-events` with `action=GRADE_SUBMISSION`
3. `kubectl logs deploy/grading-executor-service -n web-grading` → consumer
   dispatch log; `grading_jobs` row PENDING
4. Kafka UI loads at `https://web-dev1-kafka-ui.vucongtuanduong.dpdns.org`,
   topic `wgs-events` visible with messages

## 6. Changelog

| v1.0 | 2026-08-27 | SASL wiring, generalized topic, DinD sidecar, Kafka UI deploy |
