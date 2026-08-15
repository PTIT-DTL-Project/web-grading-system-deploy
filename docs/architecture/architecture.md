# Kiến trúc Microservice — Hệ thống chấm bài môn Lập trình Web

> **Phiên bản:** 1.0  
> **Tác giả:** [Your Name]  
> **Mục đích:** Tài liệu thiết kế kiến trúc chi tiết cho đồ án tốt nghiệp

---

## Mục lục

1. [Tổng quan & mục tiêu](#1-tổng-quan--mục-tiêu)
2. [Phân tích hệ thống hiện tại & vấn đề scale](#2-phân-tích-hệ-thống-hiện-tại--vấn-đề-scale)
3. [Kiến trúc target — Microservice phân tán](#3-kiến-trúc-target--microservice-phân-tán)
4. [Danh sách service & module](#4-danh-sách-service--module)
5. [Chi tiết từng service](#5-chi-tiết-từng-service)
   - 5.1 Eureka Server
   - 5.2 Config Server
   - 5.3 API Gateway
   - 5.4 Assignment Service
   - 5.5 Submission Service
   - 5.6 Grading Service
   - 5.7 Result Service
   - 5.8 Notification Service
6. [Cơ sở dữ liệu (DB-per-Service)](#6-cơ-sở-dữ-liệu-db-per-service)
7. [Kafka Topics & Message Contracts](#7-kafka-topics--message-contracts)
8. [API Contracts đầy đủ](#8-api-contracts-đầy-đủ)
9. [Security & Keycloak](#9-security--keycloak)
10. [Deployment (Docker Compose toàn hệ thống)](#10-deployment-docker-compose-toàn-hệ-thống)
11. [Cách khắc phục bottleneck & scale lên](#11-cách-khắc-phục-bottleneck--scale-lên)
12. [Implementation Roadmap](#12-implementation-roadmap)
13. [Kế thừa code hiện tại](#13-kế-thừa-code-hiện-tại)

---

## 1. Tổng quan & mục tiêu

### 1.1 Bài toán

Xây dựng hệ thống chấm bài tự động cho môn Lập trình Web. Giảng viên tạo bài tập với các kịch bản test (HTTP request/response). Sinh viên nộp bài dưới dạng Docker Compose project. Hệ thống chạy container của sinh viên, thực thi các test scenario, và chấm điểm tự động.

### 1.2 Yêu cầu

| Yêu cầu | Mô tả |
|---|---|
| Đa ngôn ngữ | Sinh viên nộp bài bằng bất kỳ ngôn ngữ nào (Java, Python, Go, Node.js...) |
| Bất đồng bộ | Nộp bài xong → chấm sau → nhận kết quả |
| Scale ngang | Hỗ trợ nhiều sinh viên cùng nộp, có thể thêm worker |
| Microservice | 7+ service, DB-per-service, service discovery |
| Auth | Keycloak (OAuth2 / OIDC) |
| Real-time | WebSocket notification khi chấm xong |

### 1.3 Công nghệ

| Layer | Công nghệ |
|---|---|
| **Service framework** | Spring Boot 4.x + Java 25 |
| **Service discovery** | Eureka (Spring Cloud Netflix) |
| **Config** | Spring Cloud Config Server |
| **Gateway** | Spring Cloud Gateway |
| **Message queue** | Kafka (KRaft mode, không cần Zookeeper) |
| **Database** | PostgreSQL 16 (1 DB per service) |
| **File storage** | MinIO (S3-compatible) |
| **Auth** | Keycloak 26 |
| **Frontend** | React + TypeScript |
| **Container runtime** | Docker (Docker Compose) |
| **Build** | Maven + Docker |

---

## 2. Phân tích hệ thống hiện tại & vấn đề scale

### 2.1 Hiện trạng codebase

Code hiện tại là một **monolith Spring Boot** với:

- `controllers/`: ExerciseController.java, FileController.java
- `services/`: ExerciseService, DockerService, EvaluationService, MinioService
- `models/`: Exercise, ExerciseRequirement, PathVariable, DockerImageBase
- `feign/`: Dynamic Feign client (SubmissionClient, FeignClientFactory)
- `config/`: MinIO, Gson config
- Flyway migrations + PostgreSQL
- MinIO cho file storage

**Luồng hoạt động hiện tại (synchronous):**
```
POST /api/files/upload + exerciseId
  → MinIO lưu file
  → DockerService: docker compose up (chờ)
  → EvaluationService: chạy từng test scenario (chờ)
  → return kết quả text/plain
```

### 2.2 Các vấn đề cần giải quyết

| # | Vấn đề | Mô tả | Mức độ |
|---|---|---|---|
| 1 | **Monolith bottleneck** | Một service làm hết: upload, docker, test, trả kết quả. Không scale được | 🔴 |
| 2 | **Synchronous blocking** | Upload xong phải chờ grading xong mới có response. Timeout với bài lâu | 🔴 |
| 3 | **Không có queue** | Nếu 100 SV cùng nộp, server xử lý 1 bài 1 lần, còn lại bị từ chối | 🔴 |
| 4 | **Port conflict** | Port tìm random, không quản lý tập trung → dễ conflict | 🟡 |
| 5 | **Không resource limits** | Student container có thể dùng hết RAM/CPU host | 🔴 |
| 6 | **Không auth** | User/password luôn "unset", không phân quyền | 🔴 |
| 7 | **Kết quả dạng text** | Không structured, không query được, không thống kê | 🟡 |
| 8 | **Không có service discovery** | URL hardcode, không scale ngang được | 🟡 |
| 9 | **Image pull trên mỗi bài** | docker compose pull/ build mất thời gian | 🟡 |
| 10 | **Không real-time notification** | Student phải refresh thủ công | 🟢 |

### 2.3 Phân tích bottleneck image downloading (bạn lo nhất)

**Vấn đề đặt ra:** Một service tải image về rồi chạy `docker compose up` cho mỗi bài nộp → không scale được.

**Phân tích thực tế:**

| Yếu tố | Thực tế | Tác động |
|---|---|---|
| **Docker image cache** | Docker daemon cache layer trên disk. Pull `node:20` lần đầu mất 30s, lần sau < 1s | ✅ Không phải vấn đề |
| **Build time** | `docker compose build` từ source của SV mất 5-30s tùy ngôn ngữ | ⚠️ Cần worker pool |
| **Container startup** | `docker compose up -d` mất 2-5s | ✅ Chấp nhận được |

**Kết luận:** Image downloading **không phải bottleneck thực sự**. Bottleneck thật là:

1. **RAM/CPU:** Mỗi student container cần 256-512MB RAM. 50 containers cùng chạy = 12-25GB RAM.
2. **Build + Startup time:** Xếp hàng chờ build. Giải pháp: worker pool + concurrent processing.
3. **Disk I/O:** Giải nén zip, build image, ghi log. Giải pháp: ramdisk cho temp, dọn ngay sau chấm.
4. **Port allocation:** Nếu không quản lý tập trung → conflict. Giải pháp: port pool synchronized.

---

## 3. Kiến trúc target — Microservice phân tán

### 3.1 Tổng quan

```
                           ┌──────────────────────────────────────────────────────┐
                           │                     API Gateway                      │
                           │    (Spring Cloud Gateway + OAuth2 Resource Server)   │
                           └──┬─────────┬──────────┬─────────┬──────────┬────────┘
                              │         │          │         │          │
              ┌───────────────┘         │          │         │          └───────────────┐
              ▼                         ▼          │         ▼                          ▼
   ┌──────────────────┐     ┌────────────────┐     │    ┌────────────────┐   ┌─────────────────────┐
   │ Assignment Service│    │Submission Service│    │    │  Result Service │   │ Notification Service │
   │ Port: 8081        │    │ Port: 8082      │    │    │  Port: 8084     │   │  Port: 8085          │
   │ DB: assignment_db │    │ DB: submission_db│   │    │  DB: result_db  │   │  DB: notification_db │
   └────────┬──────────┘    └────────┬───────┘    │    └────────┬─────────┘   └──────────┬──────────┘
            │                        │            │             │                        │
            ▼                        ▼            │             ▼                        ▼
     ┌──────────────┐         ┌────────────┐      │      ┌──────────────┐          ┌──────────────┐
     │  PostgreSQL  │         │   MinIO    │      │      │  PostgreSQL  │          │  PostgreSQL  │
     │(assignment_db│         │(zip files) │      │      │ (result_db)  │          │(notification │
     │ users,       │         └────────────┘      │      └──────────────┘          │    _db)      │
     │ assignments, │                            │                                 └──────────────┘
     │ scenarios)   │                            │ Kafka
     └──────────────┘                            ▼
                                        ┌──────────────────┐
                                        │  Grading Service  │
                                        │  Port: 8083       │
                                        │  DB: grading_db   │
                                        │  (Kafka consumer) │
                                        └────────┬─────────┘
                                                 │ Docker socket
                                                 ▼
                                        ┌──────────────────┐
                                        │  Student App      │
                                        │  Containers       │
                                        └──────────────────┘

   ┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
   │   Eureka Server   │◄────►│   Config Server   │      │    Keycloak      │
   │   Port: 8761      │      │   Port: 8888      │      │    Port: 8088    │
   └──────────────────┘      └──────────────────┘      └──────────────────┘
```

### 3.2 Service Communication Matrix

| From | To | Protocol | Purpose |
|---|---|---|---|
| API Gateway | All services | HTTP (load-balanced via Eureka) | Route + forward auth headers |
| Submission Service | Assignment Service | Feign / HTTP | Validate assignmentId exists |
| Grading Service | Assignment Service | Feign / HTTP | Fetch test scenarios |
| Grading Service | Result Service | Feign / HTTP | Write grading results |
| Grading Service | Notification Service | Feign / HTTP (or Kafka) | Send notification |
| Submission Service | MinIO | MinIO SDK | Upload zip files |
| Grading Service | MinIO | MinIO SDK | Download zip files |
| Submission Service | Kafka | Kafka producer | Submit grading job |
| Grading Service | Kafka | Kafka consumer | Receive grading job |
| Grading Service → Grading Service | Kafka topic `grading-results` | Kafka producer/consumer | Track completion |
| Notification Service | Kafka | Kafka consumer | Receive notification events |
| Grading Service | Docker | Docker SDK (unix socket) | Run student containers |
| All services | Eureka | HTTP | Register + discover |
| All services | Config Server | HTTP | Fetch config at startup |

### 3.3 Nguyên lý thiết kế

1. **Single Responsibility** — Mỗi service chỉ làm 1 việc
2. **Database per Service** — Mỗi service có DB riêng, không share trực tiếp
3. **Async communication** — Grading pipeline dùng Kafka, không blocking REST
4. **Stateless** — Tất cả service đều stateless (trạng thái lưu trong DB/kafka offset)
5. **API Gateway as entry point** — Tất cả request từ client đều qua Gateway
6. **Internal endpoints** — Service gọi nhau qua internal endpoints (Feign), không public

---

## 4. Danh sách service & module

### 4.1 Project structure

```
testing-playground/
├── services/
│   ├── common-lib/                    # [Optional] Shared library
│   ├── eureka-server/                 # Service Discovery
│   ├── config-server/                 # Centralized Configuration
│   ├── gateway/                       # API Gateway (Spring Cloud Gateway)
│   ├── assignment-service/            # Exercises & test scenarios
│   ├── submission-service/            # File upload & Kafka producer
│   ├── grading-service/               # Kafka consumer + Docker + tests
│   ├── result-service/                # Results & statistics
│   └── notification-service/          # WebSocket + Kafka consumer
├── frontend/                          # React + TypeScript
├── infra/
│   ├── docker-compose.yml             # Full system
│   ├── docker-compose.infra.yml       # Infra only (DB, Kafka, MinIO, Keycloak)
│   ├── config-repo/                   # Spring Cloud Config files
│   │   ├── application.yml
│   │   ├── gateway.yml
│   │   ├── assignment-service.yml
│   │   ├── submission-service.yml
│   │   ├── grading-service.yml
│   │   ├── result-service.yml
│   │   └── notification-service.yml
│   ├── keycloak/
│   │   └── realm-export.json
│   └── postgres/
│       └── init-dbs.sh
└── docs/
    ├── architecture.md                # THIS FILE
    └── api-spec.md
```

### 4.2 Service overview

| # | Service | Port | DB | Language | Dependencies |
|---|---|---|---|---|---|
| 1 | Eureka Server | 8761 | — | Java 25 | spring-cloud-starter-netflix-eureka-server |
| 2 | Config Server | 8888 | — | Java 25 | spring-cloud-config-server |
| 3 | API Gateway | 8080 | — | Java 25 | gateway, eureka-client, oauth2-resource-server |
| 4 | Assignment Service | 8081 | assignment_db | Java 25 | jpa, flyway, eureka-client, config-client |
| 5 | Submission Service | 8082 | submission_db | Java 25 | jpa, flyway, kafka, minio, eureka-client |
| 6 | Grading Service | 8083 | grading_db | Java 25 | kafka, minio, feign, docker-java, eureka-client |
| 7 | Result Service | 8084 | result_db | Java 25 | jpa, flyway, eureka-client |
| 8 | Notification Service | 8085 | notification_db | Java 25 | kafka, websocket, eureka-client |

---

## 5. Chi tiết từng service

### 5.1 Eureka Server

**Mục đích:** Service registry — tất cả service đăng ký vào đây, Gateway và các service khác discovery bằng service name.

**pom.xml:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
         https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>4.0.2</version>
        <relativePath/>
    </parent>

    <groupId>com.ptit.grading</groupId>
    <artifactId>eureka-server</artifactId>
    <version>1.0.0</version>
    <name>eureka-server</name>

    <properties>
        <java.version>25</java.version>
        <spring-cloud.version>2025.1.0</spring-cloud.version>
    </properties>

    <dependencies>
        <dependency>
            <groupId>org.springframework.cloud</groupId>
            <artifactId>spring-cloud-starter-netflix-eureka-server</artifactId>
        </dependency>
    </dependencies>

    <dependencyManagement>
        <dependencies>
            <dependency>
                <groupId>org.springframework.cloud</groupId>
                <artifactId>spring-cloud-dependencies</artifactId>
                <version>${spring-cloud.version}</version>
                <type>pom</type>
                <scope>import</scope>
            </dependency>
        </dependencies>
    </dependencyManagement>

    <build>
        <plugins>
            <plugin>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-maven-plugin</artifactId>
            </plugin>
        </plugins>
    </build>
</project>
```

**EurekaServerApplication.java:**
```java
package com.ptit.grading.eureka;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.netflix.eureka.server.EnableEurekaServer;

@SpringBootApplication
@EnableEurekaServer
public class EurekaServerApplication {
    public static void main(String[] args) {
        SpringApplication.run(EurekaServerApplication.class, args);
    }
}
```

**application.yml:**
```yaml
server:
  port: 8761

spring:
  application:
    name: eureka-server

eureka:
  client:
    register-with-eureka: false
    fetch-registry: false
  server:
    eviction-interval-timer-in-ms: 5000
    enable-self-preservation: false
```

**Dockerfile:**
```dockerfile
FROM eclipse-temurin:25-jre-alpine
WORKDIR /app
COPY target/eureka-server-*.jar app.jar
EXPOSE 8761
ENTRYPOINT ["java", "-jar", "app.jar"]
```

---

### 5.2 Config Server

**Mục đích:** Centralized configuration cho tất cả service. Mỗi service lấy config từ config server lúc startup thay vì config cứng.

**pom.xml:**
```xml
<dependencies>
    <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-config-server</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-starter-netflix-eureka-client</artifactId>
    </dependency>
</dependencies>
```

**application.yml:**
```yaml
server:
  port: 8888

spring:
  application:
    name: config-server
  profiles:
    active: native
  cloud:
    config:
      server:
        native:
          search-locations: file:/config-repo/

eureka:
  client:
    service-url:
      defaultZone: http://eureka-server:8761/eureka/
```

**Contents of `infra/config-repo/` — từng service có file config riêng:**

**application.yml** (global config — shared across all services):
```yaml
spring:
  jpa:
    properties:
      hibernate:
        jdbc:
          batch_size: 20
        order_inserts: true
        order_updates: true
  servlet:
    multipart:
      max-file-size: 1GB
      max-request-size: 1GB

eureka:
  client:
    service-url:
      defaultZone: http://eureka-server:8761/eureka/
  instance:
    prefer-ip-address: true

management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics
```

**assignment-service.yml:**
```yaml
server:
  port: 8081

spring:
  datasource:
    url: jdbc:postgresql://postgres:5432/assignment_db
    username: ${DB_USERNAME:postgres}
    password: ${DB_PASSWORD:postgres}
    hikari:
      maximum-pool-size: 10
  flyway:
    enabled: true
    locations: classpath:db/migration
  jpa:
    hibernate:
      ddl-auto: validate
    show-sql: false
```

**submission-service.yml:**
```yaml
server:
  port: 8082

spring:
  datasource:
    url: jdbc:postgresql://postgres:5432/submission_db
    username: ${DB_USERNAME:postgres}
    password: ${DB_PASSWORD:postgres}
    hikari:
      maximum-pool-size: 10
  flyway:
    enabled: true
    locations: classpath:db/migration

minio:
  endpoint: http://minio:9000
  accessKey: minioadmin
  secretKey: minioadmin
  bucket-name: submission-files

kafka:
  bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS:kafka:9092}
  topic:
    grading-jobs: grading-jobs
```

**grading-service.yml:**
```yaml
server:
  port: 8083

spring:
  datasource:
    url: jdbc:postgresql://postgres:5432/grading_db
    username: ${DB_USERNAME:postgres}
    password: ${DB_PASSWORD:postgres}
  flyway:
    enabled: true
    locations: classpath:db/migration

minio:
  endpoint: http://minio:9000
  accessKey: minioadmin
  secretKey: minioadmin
  bucket-name: submission-files

kafka:
  bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS:kafka:9092}
  consumer:
    group-id: grading-group
    concurrency: 5
  topic:
    grading-jobs: grading-jobs
    notifications: notifications

grading:
  container:
    max-memory: 256m
    max-cpu: 0.5
    startup-timeout-ms: 60000
    max-execution-time-ms: 300000
  temp-dir: /tmp/grading
```

**result-service.yml:**
```yaml
server:
  port: 8084

spring:
  datasource:
    url: jdbc:postgresql://postgres:5432/result_db
    username: ${DB_USERNAME:postgres}
    password: ${DB_PASSWORD:postgres}
  flyway:
    enabled: true
    locations: classpath:db/migration
```

**notification-service.yml:**
```yaml
server:
  port: 8085

spring:
  datasource:
    url: jdbc:postgresql://postgres:5432/notification_db
    username: ${DB_USERNAME:postgres}
    password: ${DB_PASSWORD:postgres}
  flyway:
    enabled: true
    locations: classpath:db/migration

kafka:
  bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS:kafka:9092}
  consumer:
    group-id: notification-group
  topic:
    notifications: notifications
```

**gateway.yml:**
```yaml
server:
  port: 8080

spring:
  cloud:
    gateway:
      routes:
        - id: assignment-service
          uri: lb://assignment-service
          predicates:
            - Path=/api/v1/assignments/**,/api/v1/docker-images/**
          filters:
            - name: JwtHeaderFilter
        - id: submission-service
          uri: lb://submission-service
          predicates:
            - Path=/api/v1/submissions/**
          filters:
            - name: JwtHeaderFilter
        - id: result-service
          uri: lb://result-service
          predicates:
            - Path=/api/v1/results/**
          filters:
            - name: JwtHeaderFilter
        - id: notification-service-ws
          uri: lb:ws://notification-service
          predicates:
            - Path=/ws/**
        - id: notification-service
          uri: lb://notification-service
          predicates:
            - Path=/api/v1/notifications/**
          filters:
            - name: JwtHeaderFilter
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: http://keycloak:8088/realms/grading-platform

jwt:
  header-names:
    user-id: X-User-Id
    user-role: X-User-Role
```

---

### 5.3 API Gateway

**Mục đích:** Entry point duy nhất cho tất cả client request. Validate JWT, route tới service phù hợp, inject user info headers.

**GatewayApplication.java:**
```java
package com.ptit.grading.gateway;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;

@SpringBootApplication
@EnableDiscoveryClient
public class GatewayApplication {
    public static void main(String[] args) {
        SpringApplication.run(GatewayApplication.class, args);
    }
}
```

**JwtHeaderFilter.java** — Chuyển JWT claims thành HTTP headers cho downstream services:
```java
package com.ptit.grading.gateway.filter;

import org.springframework.cloud.gateway.filter.GatewayFilter;
import org.springframework.cloud.gateway.filter.factory.AbstractGatewayFilterFactory;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Component;
import reactor.core.publisher.Mono;

@Component
public class JwtHeaderFilter extends AbstractGatewayFilterFactory<Object> {

    public JwtHeaderFilter() {
        super(Object.class);
    }

    @Override
    public GatewayFilter apply(Object config) {
        return (exchange, chain) -> exchange.getPrincipal()
            .cast(JwtAuthenticationToken.class)
            .map(JwtAuthenticationToken::getToken)
            .map(jwt -> {
                String userId = jwt.getSubject();
                String role = jwt.getClaimAsString("role");

                ServerHttpRequest request = exchange.getRequest().mutate()
                    .header("X-User-Id", userId != null ? userId : "")
                    .header("X-User-Role", role != null ? role : "")
                    .build();
                return exchange.mutate().request(request).build();
            })
            .defaultIfEmpty(exchange)
            .flatMap(chain::filter);
    }
}
```

**SecurityConfig.java:**
```java
package com.ptit.grading.gateway.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.reactive.EnableWebFluxSecurity;
import org.springframework.security.config.web.server.ServerHttpSecurity;
import org.springframework.security.web.server.SecurityWebFilterChain;

@Configuration
@EnableWebFluxSecurity
public class SecurityConfig {

    @Bean
    public SecurityWebFilterChain filterChain(ServerHttpSecurity http) {
        http
            .authorizeExchange(exchanges -> exchanges
                .pathMatchers("/actuator/health", "/actuator/info").permitAll()
                .anyExchange().authenticated()
            )
            .oauth2ResourceServer(oauth2 -> oauth2.jwt());
        return http.build();
    }
}
```

**Route table chi tiết:**

| Path | Target Service | HTTP Methods | Roles |
|---|---|---|---|
| `/api/v1/assignments/**` | assignment-service | ALL | lecturer, student |
| `/api/v1/docker-images/**` | assignment-service | ALL | lecturer, student |
| `/api/v1/submissions/**` | submission-service | ALL | lecturer, student |
| `/api/v1/results/**` | result-service | ALL | lecturer, student |
| `/api/v1/notifications/**` | notification-service | GET | lecturer, student |
| `/ws/**` | notification-service | WS | lecturer, student |

---

### 5.4 Assignment Service

**Package structure:**
```
com.ptit.grading.assignment/
├── AssignmentServiceApplication.java
├── config/
│   ├── SecurityConfig.java
│   └── FeignConfig.java
├── controller/
│   ├── AssignmentController.java          # Public: CRUD assignments
│   ├── DockerImageController.java         # Public: CRUD docker images
│   └── InternalAssignmentController.java  # Internal: Feign-only (grading service gọi)
├── service/
│   ├── AssignmentService.java
│   ├── ScenarioService.java
│   └── DockerImageService.java
├── repository/
│   ├── AssignmentRepository.java
│   ├── ScenarioRepository.java
│   ├── PathVariableRepository.java
│   ├── DockerImageBaseRepository.java
│   └── AssignmentDockerImageRepository.java
├── model/
│   ├── BaseEntity.java
│   ├── Assignment.java
│   ├── TestScenario.java
│   ├── PathVariable.java
│   ├── DockerImageBase.java
│   └── AssignmentDockerImage.java
└── dto/
    ├── request/
    │   ├── CreateAssignmentRequest.java
    │   ├── UpdateAssignmentRequest.java
    │   └── CreateScenarioRequest.java
    └── response/
        ├── AssignmentResponse.java
        ├── ScenarioResponse.java
        └── DockerImageResponse.java
```

**Models:**

```java
// BaseEntity.java
@MappedSuperclass
@Getter @Setter @SuperBuilder @NoArgsConstructor @AllArgsConstructor
public abstract class BaseEntity {
    @Id
    @GeneratedValue(generator = "UUID")
    @Column(updatable = false, nullable = false)
    private UUID id;

    @CreationTimestamp
    @Column(updatable = false, nullable = false)
    private OffsetDateTime createdAt;

    @UpdateTimestamp
    @Column(nullable = false)
    private OffsetDateTime updatedAt;

    private OffsetDateTime deletedAt;
}

// Assignment.java
@Entity
@Table(name = "assignments")
@SQLDelete(sql = "UPDATE assignments SET deleted_at = now() WHERE id = ?")
@Where(clause = "deleted_at IS NULL")
@Getter @Setter @SuperBuilder @NoArgsConstructor @AllArgsConstructor
public class Assignment extends BaseEntity {
    @Column(nullable = false)
    private UUID ownerId;

    @Column(nullable = false)
    private String title;

    private String description;

    @Column(nullable = false)
    private boolean published = false;
}

// TestScenario.java
@Entity
@Table(name = "test_scenarios")
@SQLDelete(sql = "UPDATE test_scenarios SET deleted_at = now() WHERE id = ?")
@Where(clause = "deleted_at IS NULL")
@Getter @Setter @SuperBuilder @NoArgsConstructor @AllArgsConstructor
public class TestScenario extends BaseEntity {
    @Column(nullable = false)
    private UUID assignmentId;

    @Column(name = "sequence_order", nullable = false)
    private Integer sequenceOrder;

    @Column(nullable = false)
    private String name;

    @Column(nullable = false, length = 10)
    private String httpMethod;  // GET, POST, PUT, DELETE, PATCH

    @Column(nullable = false)
    private String endpoint;    // e.g. /api/v1/book/{bookID}

    @Column(columnDefinition = "jsonb")
    @JdbcTypeCode(SqlTypes.JSON)
    private String queryParams;  // JSON string

    @Column(columnDefinition = "jsonb")
    @JdbcTypeCode(SqlTypes.JSON)
    private String requestBody;  // JSON string

    @Column(columnDefinition = "jsonb")
    @JdbcTypeCode(SqlTypes.JSON)
    private String expectedResponseBody;

    private Integer expectedStatus = 200;

    private Integer weight = 1;
}

// PathVariable.java
@Entity
@Table(name = "path_variables")
@Getter @Setter @SuperBuilder @NoArgsConstructor @AllArgsConstructor
public class PathVariable extends BaseEntity {
    @Column(nullable = false)
    private UUID scenarioId;

    @Column(nullable = false)
    private String name;

    @Column(name = "variable_order", nullable = false)
    private Integer order;

    private String type;  // "UUID", "Integer", "String"
}
```

**Endpoints:**

```
=== Public API ===

POST   /api/v1/assignments                          — Lecturer tạo bài tập
GET    /api/v1/assignments                          — DS bài tập (phân trang)
GET    /api/v1/assignments/{id}                     — Chi tiết bài tập
PUT    /api/v1/assignments/{id}                     — Sửa bài tập
DELETE /api/v1/assignments/{id}                     — Xoá bài tập (soft delete)
POST   /api/v1/assignments/{id}/publish             — Publish bài tập
GET    /api/v1/assignments/published                — DS bài tập đã publish (cho SV)

POST   /api/v1/assignments/{id}/scenarios           — Thêm test scenario
GET    /api/v1/assignments/{id}/scenarios           — DS scenarios
PUT    /api/v1/assignments/{id}/scenarios/{sid}     — Sửa scenario
DELETE /api/v1/assignments/{id}/scenarios/{sid}     — Xoá scenario
PATCH  /api/v1/assignments/{id}/scenarios/reorder   — Sắp xếp lại thứ tự

POST   /api/v1/docker-images                        — Thêm base image
GET    /api/v1/docker-images                        — DS base image
DELETE /api/v1/docker-images/{id}                   — Xoá base image

=== Internal API (chỉ cho service khác gọi Feign) ===

GET    /api/v1/internal/assignments/{id}             — Grading Service: validate assignment tồn tại
GET    /api/v1/internal/assignments/{id}/scenarios   — Grading Service: lấy scenarios + path variables
GET    /api/v1/internal/docker-images/{id}           — Grading Service: lấy image info
```

**AssignmentService.java (core):**
```java
@Service
@RequiredArgsConstructor
@Transactional
public class AssignmentService {
    private final AssignmentRepository assignmentRepository;
    private final ScenarioRepository scenarioRepository;
    private final PathVariableRepository pathVariableRepository;
    private final DockerImageBaseRepository dockerImageBaseRepository;
    private final AssignmentDockerImageRepository assignmentDockerImageRepository;

    public AssignmentResponse create(CreateAssignmentRequest request, UUID ownerId) {
        Assignment assignment = Assignment.builder()
            .ownerId(ownerId)
            .title(request.getTitle())
            .description(request.getDescription())
            .published(false)
            .build();
        assignment = assignmentRepository.save(assignment);
        return AssignmentResponse.from(assignment);
    }

    @Transactional(readOnly = true)
    public Page<AssignmentResponse> listPublished(Pageable pageable) {
        return assignmentRepository.findByPublishedTrue(pageable)
            .map(AssignmentResponse::from);
    }

    @Transactional(readOnly = true)
    public List<ScenarioDetailResponse> getScenariosWithVariables(UUID assignmentId) {
        List<TestScenario> scenarios = scenarioRepository
            .findByAssignmentIdOrderBySequenceOrder(assignmentId);
        return scenarios.stream().map(scenario -> {
            List<PathVariable> variables = pathVariableRepository
                .findByScenarioId(scenario.getId());
            return ScenarioDetailResponse.from(scenario, variables);
        }).toList();
    }
}
```

---

### 5.5 Submission Service

**Package structure:**
```
com.ptit.grading.submission/
├── SubmissionServiceApplication.java
├── config/
│   ├── SecurityConfig.java
│   ├── MinioConfig.java
│   └── KafkaConfig.java
├── controller/
│   └── SubmissionController.java
├── service/
│   ├── SubmissionService.java
│   └── MinioService.java
├── repository/
│   └── SubmissionRepository.java
├── model/
│   ├── BaseEntity.java
│   ├── Submission.java
│   └── SubmissionStatus.java
├── dto/
│   ├── SubmissionResponse.java
│   └── SubmissionListResponse.java
├── client/
│   └── AssignmentServiceClient.java       # Feign
└── kafka/
    └── GradingJobProducer.java
```

**Model:**
```java
public enum SubmissionStatus {
    PENDING,    // Đã nộp, chưa chấm
    GRADING,    // Đang chấm
    DONE,       // Đã chấm xong
    FAILED      // Lỗi (container die, timeout, ...)
}

@Entity
@Table(name = "submissions")
@Getter @Setter @SuperBuilder @NoArgsConstructor @AllArgsConstructor
public class Submission extends BaseEntity {
    @Column(nullable = false)
    private UUID assignmentId;

    @Column(nullable = false)
    private UUID studentId;

    @Column(nullable = false)
    private String minioPath;

    private String zipFileName;  // Tên gốc file zip

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private SubmissionStatus status = SubmissionStatus.PENDING;

    @Column(nullable = false)
    private boolean latest = true;  // Nhiều lần nộp, chỉ 1 cái latest
}
```

**Kafka Producer:**
```java
@Slf4j
@Component
@RequiredArgsConstructor
public class GradingJobProducer {

    private final KafkaTemplate<String, String> kafkaTemplate;
    private final Gson gson;

    @Value("${kafka.topic.grading-jobs}")
    private String topic;

    public void send(UUID submissionId, UUID assignmentId, UUID studentId, String minioPath) {
        GradingJob job = GradingJob.builder()
            .submissionId(submissionId)
            .assignmentId(assignmentId)
            .studentId(studentId)
            .minioPath(minioPath)
            .timestamp(Instant.now())
            .build();

        String key = submissionId.toString();

        kafkaTemplate.send(topic, key, gson.toJson(job))
            .whenComplete((result, ex) -> {
                if (ex != null) {
                    log.error("Failed to send grading job: {}", submissionId, ex);
                } else {
                    log.info("Grading job sent: {} to partition {}", submissionId,
                        result.getRecordMetadata().partition());
                }
            });
    }
}
```

**Endpoints:**

```
POST   /api/v1/submissions                       — Nộp bài (multipart: file + assignmentId)
GET    /api/v1/submissions                        — Bài nộp của tôi
GET    /api/v1/submissions/{id}                   — Chi tiết bài nộp
GET    /api/v1/submissions/assignment/{id}        — DS bài nộp của 1 bài tập (lecturer)
GET    /api/v1/submissions/{id}/download          — Download file zip
PATCH  /api/v1/submissions/{id}/status            — Internal: update status (grading service gọi)
```

---
### 5.6 Grading Service

Đây là service phức tạp nhất. Nó **KHÔNG có REST API public**, chỉ hoạt động như Kafka consumer.

**Package structure:**
```
com.ptit.grading.executor/
├── GradingServiceApplication.java
├── config/
│   ├── SecurityConfig.java
│   ├── KafkaConfig.java
│   ├── MinioConfig.java
│   └── DockerConfig.java
├── consumer/
│   └── GradingJobConsumer.java                # @KafkaListener
├── service/
│   ├── GradingOrchestrator.java               # Điều phối luồng chấm
│   ├── DockerService.java                     # Docker compose operations
│   ├── DockerComposePatcher.java              # Patch docker-compose.yml
│   ├── TestExecutor.java                      # Chạy từng test scenario
│   ├── ResponseComparator.java                # So sánh JSON response
│   └── PortAllocator.java                     # Quản lý port tập trung
├── repository/
│   └── GradingLogRepository.java
├── model/
│   ├── BaseEntity.java
│   └── GradingLog.java
├── client/
│   ├── AssignmentServiceClient.java           # Feign → Assignment Service
│   ├── ResultServiceClient.java               # Feign → Result Service
│   └── NotificationServiceClient.java         # Feign → Notification Service
└── dto/
    ├── GradingJob.java
    ├── ScenarioDetailResponse.java
    ├── ScenarioResult.java
    └── GradingResultRequest.java
```

#### 5.6.1 GradingJobConsumer.java

```java
@Slf4j
@Component
@RequiredArgsConstructor
public class GradingJobConsumer {

    private final GradingOrchestrator orchestrator;
    private final Gson gson;

    @KafkaListener(
        topics = "${kafka.topic.grading-jobs}",
        groupId = "${kafka.consumer.group-id}",
        concurrency = "${kafka.consumer.concurrency}"
    )
    public void consume(String message,
                        @Header(KafkaHeaders.RECEIVED_KEY) String key,
                        @Header(KafkaHeaders.RECEIVED_PARTITION) int partition) {
        GradingJob job = gson.fromJson(message, GradingJob.class);
        log.info("Received grading job: submissionId={}, assignmentId={}, partition={}",
            job.getSubmissionId(), job.getAssignmentId(), partition);

        try {
            orchestrator.execute(job);
        } catch (Exception e) {
            log.error("Grading failed for submission {}", job.getSubmissionId(), e);
            // Ghi result FAILED (gọi Result Service)
        }
    }
}
```

#### 5.6.2 GradingOrchestrator.java — Luồng chấm bài chi tiết

```java
@Slf4j
@Service
@RequiredArgsConstructor
public class GradingOrchestrator {

    private final DockerService dockerService;
    private final TestExecutor testExecutor;
    private final AssignmentServiceClient assignmentClient;
    private final ResultServiceClient resultClient;
    private final MinioClient minioClient;
    private final GradingLogRepository logRepository;
    private final Gson gson;

    @Value("${grading.temp-dir}")
    private String tempDir;

    @Value("${grading.container.startup-timeout-ms}")
    private long startupTimeoutMs;

    public void execute(GradingJob job) {
        String submissionId = job.getSubmissionId().toString();
        Path workDir = Paths.get(tempDir, submissionId);
        String projectName = "sub-" + submissionId;

        try {
            // === Bước 1: Tạo thư mục tạm ===
            Files.createDirectories(workDir);
            log("INFO", submissionId, "Created working directory");

            // === Bước 2: Download zip từ MinIO ===
            Path zipPath = workDir.resolve("submission.zip");
            minioClient.download(job.getMinioPath(), zipPath);
            log("INFO", submissionId, "Downloaded zip from MinIO");

            // === Bước 3: Giải nén zip ===
            ZipUtils.extract(zipPath, workDir);
            Files.deleteIfExists(zipPath);
            log("INFO", submissionId, "Extracted zip");

            // === Bước 4: Validate docker-compose.yml tồn tại ===
            Path composeFile = workDir.resolve("docker-compose.yml");
            if (!Files.exists(composeFile)) {
                composeFile = workDir.resolve("docker-compose.yaml");
            }
            if (!Files.exists(composeFile)) {
                fail(job, "docker-compose.yml not found in submission");
                return;
            }

            // === Bước 5: Patch docker-compose.yml (thêm resource limits) ===
            DockerComposePatcher.patchResourceLimits(composeFile);
            log("INFO", submissionId, "Patched docker-compose with resource limits");

            // === Bước 6: Lấy test scenarios từ Assignment Service ===
            List<ScenarioDetailResponse> scenarios = assignmentClient.getScenarios(job.getAssignmentId());
            if (scenarios == null || scenarios.isEmpty()) {
                fail(job, "No test scenarios found for assignment " + job.getAssignmentId());
                return;
            }
            log("INFO", submissionId, "Fetched " + scenarios.size() + " scenarios");

            // === Bước 7: Docker compose up với timeout ===
            int port;
            try {
                port = dockerService.up(workDir, projectName);
            } catch (Exception e) {
                fail(job, "Failed to start Docker: " + e.getMessage());
                return;
            }
            log("INFO", submissionId, "Docker compose started on port " + port);

            // === Bước 8: Đợi container ready (health check) ===
            boolean ready = dockerService.waitForHealth(
                "http://localhost:" + port + "/actuator/health",
                startupTimeoutMs
            );
            if (!ready) {
                // Fallback: thử GET / hoặc GET bất kỳ
                ready = dockerService.waitForAnyResponse(
                    "http://localhost:" + port,
                    30_000
                );
            }
            if (!ready) {
                dockerService.down(projectName);
                fail(job, "Container failed to start within timeout");
                return;
            }
            log("INFO", submissionId, "Container is ready");

            // === Bước 9: Chạy từng test scenario ===
            List<ScenarioResult> results = new ArrayList<>();
            for (ScenarioDetailResponse scenario : scenarios) {
                try {
                    ScenarioResult result = testExecutor.execute(port, scenario);
                    results.add(result);
                    log("INFO", submissionId,
                        "Scenario '{}' : {} (status={})",
                        scenario.getName(),
                        result.isPassed() ? "PASSED" : "FAILED",
                        result.getActualStatus());
                } catch (Exception e) {
                    log.error("Scenario execution failed", e);
                    results.add(ScenarioResult.builder()
                        .scenarioId(scenario.getId())
                        .scenarioName(scenario.getName())
                        .weight(scenario.getWeight())
                        .passed(false)
                        .errorMessage(e.getMessage())
                        .build());
                }
            }

            // === Bước 10: Tính điểm ===
            int totalWeight = scenarios.stream().mapToInt(ScenarioDetailResponse::getWeight).sum();
            int earnedWeight = results.stream()
                .filter(ScenarioResult::isPassed)
                .mapToInt(ScenarioResult::getWeight)
                .sum();

            double score = 0;
            if (totalWeight > 0) {
                score = Math.round((double) earnedWeight / totalWeight * 100.0) / 10.0;
            }

            // === Bước 11: Ghi kết quả qua Result Service ===
            GradingResultRequest resultRequest = GradingResultRequest.builder()
                .submissionId(job.getSubmissionId())
                .studentId(job.getStudentId())
                .assignmentId(job.getAssignmentId())
                .score(score)
                .maxScore(10.0)
                .status("DONE")
                .scenarioResults(results)
                .summaryLog(String.format("Passed %d/%d scenarios, Score: %.1f/10",
                    earnedWeight, totalWeight, score))
                .build();

            try {
                resultClient.saveResult(resultRequest);
                log("INFO", submissionId, "Result saved: " + score + "/10");
            } catch (Exception e) {
                log.error("Failed to save result", e);
            }

            // === Bước 12: Update submission status qua Feign ===
            // (Submission Service internal endpoint)
            try {
                // Nếu có Feign client gọi Submission Service
                // submissionClient.updateStatus(job.getSubmissionId(), "DONE");
            } catch (Exception e) {
                log.warn("Failed to update submission status", e);
            }

            log("INFO", submissionId,
                "Grading completed: {}/{} scenarios, Score: {}/10",
                earnedWeight, totalWeight, score);

        } catch (Exception e) {
            log.error("Grading failed with exception", e);
            fail(job, "Unexpected error: " + e.getMessage());
        } finally {
            // === Bước 13: Cleanup ===
            try {
                dockerService.down(projectName);
            } catch (Exception e) {
                log.warn("Docker compose down failed", e);
            }
            try {
                FileUtils.deleteDirectory(workDir);
            } catch (Exception e) {
                log.warn("Cleanup failed", e);
            }
        }
    }

    private void fail(GradingJob job, String reason) {
        log.error("Grading failed for submission {}: {}", job.getSubmissionId(), reason);
        GradingResultRequest failureResult = GradingResultRequest.builder()
            .submissionId(job.getSubmissionId())
            .studentId(job.getStudentId())
            .assignmentId(job.getAssignmentId())
            .score(0.0)
            .maxScore(10.0)
            .status("FAILED")
            .summaryLog(reason)
            .build();
        try {
            resultClient.saveResult(failureResult);
        } catch (Exception e) {
            log.error("Failed to save failure result", e);
        }
    }

    private void log(String level, String submissionId, String message, Object... args) {
        GradingLog gradingLog = GradingLog.builder()
            .submissionId(UUID.fromString(submissionId))
            .step("orchestrator")
            .message(String.format(message, args))
            .level(level)
            .build();
        logRepository.save(gradingLog);
    }
}
```

#### 5.6.3 DockerService.java — Quản lý container

```java
@Slf4j
@Service
public class DockerService {

    private final PortAllocator portAllocator;

    @Value("${grading.container.max-memory}")
    private String maxMemory;

    @Value("${grading.container.max-cpu}")
    private String maxCpu;

    @Value("${grading.container.max-execution-time-ms}")
    private long maxExecutionTimeMs;

    /**
     * Chạy docker compose up với project name và resource limits
     */
    public int up(Path workDir, String projectName) throws Exception {
        Path composeFile = workDir.resolve("docker-compose.yml");
        if (!Files.exists(composeFile)) {
            composeFile = workDir.resolve("docker-compose.yaml");
        }

        // Tìm port trống
        int port = portAllocator.allocate();

        List<String> command = new ArrayList<>(List.of(
            "docker", "compose",
            "-p", projectName,
            "-f", composeFile.toString(),
            "up", "-d", "--build"
        ));

        ProcessBuilder pb = new ProcessBuilder(command);
        pb.directory(workDir.toFile());

        // Environment variables cho docker-compose
        pb.environment().put("SUBMISSION_PORT", String.valueOf(port));
        pb.environment().put("MEMORY_LIMIT", maxMemory);
        pb.environment().put("CPU_LIMIT", maxCpu);

        pb.redirectErrorStream(true);
        Process process = pb.start();

        StringBuilder output = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(process.getInputStream()))) {
            String line;
            while ((line = reader.readLine()) != null) {
                output.append(line).append("\n");
                log.info("[{}] {}", projectName, line);
            }
        }

        boolean finished = process.waitFor(5, TimeUnit.MINUTES);
        if (!finished) {
            process.destroyForcibly();
            portAllocator.release(port);
            throw new RuntimeException("Docker compose timed out");
        }

        int exitCode = process.exitValue();
        if (exitCode != 0) {
            portAllocator.release(port);
            throw new RuntimeException("Docker compose failed (exit=" + exitCode + "):\n" + output);
        }

        return port;
    }

    /**
     * Đợi container trả về HTTP response (health check hoặc bất kỳ endpoint nào)
     */
    public boolean waitForHealth(String url, long timeoutMs) {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            try {
                HttpClient client = HttpClient.newBuilder()
                    .connectTimeout(Duration.ofSeconds(2))
                    .build();
                HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .timeout(Duration.ofSeconds(5))
                    .GET()
                    .build();
                HttpResponse<Void> response = client.send(request,
                    HttpResponse.BodyHandlers.discarding());
                if (response.statusCode() < 500) {
                    return true;
                }
            } catch (Exception e) {
                // Container chưa ready
            }
            try { Thread.sleep(1000); } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                return false;
            }
        }
        return false;
    }

    public boolean waitForAnyResponse(String baseUrl, long timeoutMs) {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            try {
                HttpClient client = HttpClient.newBuilder()
                    .connectTimeout(Duration.ofSeconds(2))
                    .build();
                // Thử GET nhiều endpoint phổ biến
                String[] paths = {"", "/", "/api", "/health", "/actuator/health",
                    "/api/v1", "/api/v1/health"};
                for (String path : paths) {
                    try {
                        HttpRequest request = HttpRequest.newBuilder()
                            .uri(URI.create(baseUrl + path))
                            .timeout(Duration.ofSeconds(2))
                            .GET()
                            .build();
                        HttpResponse<Void> response = client.send(request,
                            HttpResponse.BodyHandlers.discarding());
                        if (response.statusCode() < 500) {
                            return true;
                        }
                    } catch (Exception ignored) {}
                }
            } catch (Exception ignored) {}
            try { Thread.sleep(2000); } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                return false;
            }
        }
        return false;
    }

    /**
     * Docker compose down với timeout
     */
    public void down(String projectName) throws Exception {
        ProcessBuilder pb = new ProcessBuilder(
            "docker", "compose",
            "-p", projectName,
            "down", "--volumes", "--remove-orphans",
            "--timeout", "10"
        );
        pb.redirectErrorStream(true);
        Process process = pb.start();
        boolean finished = process.waitFor(30, TimeUnit.SECONDS);
        if (!finished) {
            process.destroyForcibly();
            log.warn("docker compose down timed out for {}", projectName);
        }
    }
}
```

#### 5.6.4 PortAllocator.java

```java
@Component
public class PortAllocator {
    private static final int MIN_PORT = 20000;
    private static final int MAX_PORT = 30000;
    private final Set<Integer> usedPorts = ConcurrentHashMap.newKeySet();

    public synchronized int allocate() throws IOException {
        for (int i = 0; i < 100; i++) {
            try (ServerSocket ss = new ServerSocket(0)) {
                int port = ss.getLocalPort();
                if (port >= MIN_PORT && port <= MAX_PORT && usedPorts.add(port)) {
                    return port;
                }
            }
        }
        // Fallback: random port
        int port = ThreadLocalRandom.current().nextInt(MIN_PORT, MAX_PORT);
        while (!usedPorts.add(port)) {
            port = ThreadLocalRandom.current().nextInt(MIN_PORT, MAX_PORT);
        }
        return port;
    }

    public void release(int port) {
        usedPorts.remove(port);
    }
}
```

#### 5.6.5 DockerComposePatcher.java

```java
public class DockerComposePatcher {

    public static void patchResourceLimits(Path composeFile) throws IOException {
        String yaml = Files.readString(composeFile);

        // Thêm resource limits cho mỗi service definition
        // Tìm pattern "  service_name:" (2 spaces + name + colon)
        // Và thêm block "    deploy:" sau "    restart:" nếu có
        String patched = yaml.replaceAll(
            "(?m)^(\\s+)(restart:[^\\n]*)$",
            "$1$2\n" +
            "$1deploy:\n" +
            "$1  resources:\n" +
            "$1    limits:\n" +
            "$1      cpus: '${CPU_LIMIT:-0.5}'\n" +
            "$1      memory: ${MEMORY_LIMIT:-256M}"
        );

        // Nếu không có restart line, thêm deploy vào cuối service block
        if (patched.equals(yaml)) {
            patched = yaml.replaceAll(
                "(?m)^(\\s+)(image:[^\\n]*)$",
                "$1$2\n" +
                "$1deploy:\n" +
                "$1  resources:\n" +
                "$1    limits:\n" +
                "$1      cpus: '${CPU_LIMIT:-0.5}'\n" +
                "$1      memory: ${MEMORY_LIMIT:-256M}"
            );
        }

        // Chỉ ghi nếu có thay đổi
        if (!patched.equals(yaml)) {
            Files.writeString(composeFile, patched);
        }
    }
}
```

#### 5.6.6 TestExecutor.java

```java
@Slf4j
@Service
@RequiredArgsConstructor
public class TestExecutor {

    private final FeignClientFactory feignClientFactory;
    private final ResponseComparator responseComparator;

    public ScenarioResult execute(int port, ScenarioDetailResponse scenario) {
        // Tạo dynamic Feign client
        // Grading Service chạy trên host → dùng localhost
        // Nếu Grading Service chạy trong container → dùng host.docker.internal
        String baseUrl = "http://localhost:" + port;
        SubmissionClient client = feignClientFactory.createClient(
            SubmissionClient.class, baseUrl);

        // Resolve path variables
        String resolvedPath = resolvePath(scenario.getEndpoint(), scenario.getPathVariables());
        if (!resolvedPath.startsWith("/")) {
            resolvedPath = "/" + resolvedPath;
        }

        // Parse query params
        Map<String, Object> queryParams = Map.of();
        if (scenario.getQueryParams() != null && !scenario.getQueryParams().isBlank()) {
            queryParams = new Gson().fromJson(scenario.getQueryParams(),
                new TypeToken<Map<String, Object>>(){}.getType());
        }

        // Parse request body
        Object requestBody = null;
        if (scenario.getRequestBody() != null && !scenario.getRequestBody().isBlank()) {
            requestBody = new Gson().fromJson(scenario.getRequestBody(), Object.class);
        }

        try {
            // Gọi HTTP method tương ứng
            Response response = switch (scenario.getHttpMethod().toUpperCase()) {
                case "GET" -> client.get(resolvedPath, queryParams);
                case "POST" -> client.post(resolvedPath, requestBody);
                case "PUT" -> client.put(resolvedPath, requestBody);
                case "DELETE" -> client.delete(resolvedPath);
                case "PATCH" -> client.patch(resolvedPath, requestBody);
                default -> throw new IllegalArgumentException(
                    "Unsupported method: " + scenario.getHttpMethod());
            };

            int actualStatus = response.status();
            String actualBody = "";
            if (response.body() != null) {
                actualBody = IOUtils.toString(
                    response.body().asInputStream(), StandardCharsets.UTF_8);
            }

            // So sánh status
            boolean statusMatch = actualStatus == scenario.getExpectedStatus();

            // So sánh response body (nếu có expected)
            boolean bodyMatch = responseComparator.matches(
                scenario.getExpectedResponseBody(), actualBody);

            boolean passed = statusMatch && bodyMatch;

            return ScenarioResult.builder()
                .scenarioId(scenario.getId())
                .scenarioName(scenario.getName())
                .weight(scenario.getWeight())
                .passed(passed)
                .actualStatus(actualStatus)
                .actualBody(actualBody)
                .errorMessage(buildErrorMessage(scenario, actualStatus, statusMatch, bodyMatch))
                .build();

        } catch (Exception e) {
            log.error("Failed to execute scenario '{}'", scenario.getName(), e);
            return ScenarioResult.builder()
                .scenarioId(scenario.getId())
                .scenarioName(scenario.getName())
                .weight(scenario.getWeight())
                .passed(false)
                .actualStatus(0)
                .errorMessage("Exception: " + e.getMessage())
                .build();
        }
    }

    private String resolvePath(String endpoint, List<PathVariableDTO> pvs) {
        String path = endpoint;
        for (PathVariableDTO pv : pvs) {
            String placeholder = "{" + pv.getName() + "}";
            if (path.contains(placeholder)) {
                path = path.replace(placeholder, generateValue(pv.getType()));
            }
        }
        // Fallback: thay thế tất cả {xxx} còn lại
        path = path.replaceAll("\\{[^}]+\\}", UUID.randomUUID().toString());
        return path;
    }

    private String generateValue(String type) {
        if (type == null) return "test-value";
        return switch (type.toUpperCase()) {
            case "UUID" -> UUID.randomUUID().toString();
            case "INTEGER", "LONG", "INT" -> "1";
            case "STRING" -> "test";
            default -> "test-value";
        };
    }

    private String buildErrorMessage(ScenarioDetailResponse scenario,
                                      int actualStatus,
                                      boolean statusMatch,
                                      boolean bodyMatch) {
        if (statusMatch && bodyMatch) return null;
        StringBuilder sb = new StringBuilder();
        if (!statusMatch) {
            sb.append("Expected status ")
              .append(scenario.getExpectedStatus())
              .append(", got ")
              .append(actualStatus);
        }
        if (!statusMatch && !bodyMatch) sb.append("; ");
        if (!bodyMatch) {
            sb.append("Response body does not match expected structure");
        }
        return sb.toString();
    }
}
```

#### 5.6.7 ResponseComparator.java — So sánh JSON bằng Gson

```java
@Component
public class ResponseComparator {
    private static final Gson gson = new Gson();

    /**
     * So sánh 2 JSON strings, ignore value differences nhưng check cấu trúc key
     * Nếu expected là null/blank → bỏ qua (không check body)
     */
    public boolean matches(String expectedJson, String actualJson) {
        if (expectedJson == null || expectedJson.isBlank()) return true;
        if (actualJson == null || actualJson.isBlank()) return false;

        try {
            Object expected = gson.fromJson(expectedJson, Object.class);
            Object actual = gson.fromJson(actualJson, Object.class);
            return deepEquals(expected, actual);
        } catch (Exception e) {
            // Nếu expected không parse được → so sánh raw string
            return expectedJson.trim().equals(actualJson.trim());
        }
    }

    @SuppressWarnings("unchecked")
    private boolean deepEquals(Object expected, Object actual) {
        if (expected == null && actual == null) return true;
        if (expected == null || actual == null) return false;

        // Map → so sánh keys (cấu trúc), không so sánh values
        if (expected instanceof Map && actual instanceof Map) {
            Map<String, Object> expMap = (Map<String, Object>) expected;
            Map<String, Object> actMap = (Map<String, Object>) actual;
            return expMap.keySet().equals(actMap.keySet())
                && expMap.keySet().stream()
                    .allMatch(k -> deepEquals(expMap.get(k), actMap.get(k)));
        }

        // List → so sánh từng phần tử
        if (expected instanceof List && actual instanceof List) {
            List<Object> expList = (List<Object>) expected;
            List<Object> actList = (List<Object>) actual;
            if (expList.size() != actList.size()) return false;
            for (int i = 0; i < expList.size(); i++) {
                if (!deepEquals(expList.get(i), actList.get(i))) return false;
            }
            return true;
        }

        // Primitive → so sánh giá trị (hoặc class)
        if (expected instanceof Number && actual instanceof Number) {
            return ((Number) expected).doubleValue() == ((Number) actual).doubleValue();
        }
        if (expected instanceof Boolean && actual instanceof Boolean) {
            return expected.equals(actual);
        }
        // String hoặc khác kiểu → so sánh string representation
        // Nhưng với mục đích test, ta compare class type
        return expected.getClass().equals(actual.getClass());
    }
}
```

---

### 5.7 Result Service

**Package structure:**
```
com.ptit.grading.result/
├── ResultServiceApplication.java
├── controller/
│   ├── ResultController.java          # Public APIs
│   └── InternalResultController.java  # Grading Service gọi
├── service/
│   └── ResultService.java
├── repository/
│   ├── GradingResultRepository.java
│   └── ScenarioResultRepository.java
├── model/
│   ├── GradingResult.java
│   └── ScenarioResultEntity.java
└── dto/
    ├── GradingResultResponse.java
    ├── GradingResultRequest.java      # Request từ Grading Service
    ├── ScenarioResultDTO.java
    └── StatisticsResponse.java
```

**Endpoints:**

```
=== Public API ===
GET    /api/v1/results/{submissionId}                  — Kết quả 1 bài nộp
GET    /api/v1/results/assignment/{assignmentId}        — Điểm toàn bộ bài tập (lecturer)
GET    /api/v1/results/assignment/{assignmentId}/stats  — Thống kê (avg, distribution)
GET    /api/v1/results/my                               — Điểm của tôi (student)

=== Internal API (chỉ cho Grading Service gọi Feign) ===
POST   /api/v1/internal/results                         — Ghi kết quả
```

**Response mẫu:**
```json
{
  "submissionId": "550e8400-e29b-41d4-a716-446655440000",
  "assignmentId": "660e8400-e29b-41d4-a716-446655440001",
  "assignmentTitle": "Bài tập 1 - CRUD Books",
  "studentId": "770e8400-e29b-41d4-a716-446655440002",
  "score": 8.5,
  "maxScore": 10.0,
  "status": "DONE",
  "scenarioResults": [
    {
      "scenarioName": "GET danh sách sách",
      "passed": true,
      "actualStatus": 200,
      "weight": 2
    },
    {
      "scenarioName": "POST tạo sách",
      "passed": false,
      "actualStatus": 500,
      "errorMessage": "Internal Server Error",
      "weight": 3
    }
  ],
  "summaryLog": "Passed 2/4 scenarios, Score: 8.5/10",
  "gradedAt": "2026-05-25T10:05:00Z"
}
```

**Statistics response mẫu:**
```json
{
  "assignmentId": "uuid",
  "totalSubmissions": 45,
  "averageScore": 7.2,
  "medianScore": 7.5,
  "highestScore": 10.0,
  "lowestScore": 0.0,
  "distribution": {
    "0-4": 5,
    "4-6": 8,
    "6-8": 18,
    "8-10": 14
  }
}
```

---

### 5.8 Notification Service

**Package structure:**
```
com.ptit.grading.notification/
├── NotificationServiceApplication.java
├── config/
│   └── WebSocketConfig.java
├── controller/
│   ├── NotificationController.java     # REST: lịch sử, mark read
│   └── WebSocketHandler.java           # WebSocket
├── consumer/
│   └── NotificationConsumer.java       # Kafka consumer
├── service/
│   └── NotificationService.java
├── repository/
│   └── NotificationRepository.java
├── model/
│   ├── BaseEntity.java
│   └── Notification.java
└── dto/
    └── NotificationMessage.java        # Kafka message
```

**WebSocketConfig.java:**
```java
@Configuration
public class WebSocketConfig implements WebSocketConfigurer {

    private final NotificationWebSocketHandler handler;
    private final JwtHandshakeInterceptor jwtInterceptor;

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(handler, "/ws/notifications")
            .addInterceptors(jwtInterceptor)
            .setAllowedOrigins("*");
    }
}
```

**NotificationWebSocketHandler.java:**
```java
@Component
public class NotificationWebSocketHandler extends TextWebSocketHandler {
    // userId → session mapping (ConcurrentHashMap thread-safe)
    private final Map<String, WebSocketSession> sessions = new ConcurrentHashMap<>();
    private final Gson gson = new Gson();

    @Override
    public void afterConnectionEstablished(WebSocketSession session) {
        String userId = extractUserId(session);
        if (userId != null) {
            sessions.put(userId, session);
            log.info("WebSocket connected: userId={}, sessionId={}", userId, session.getId());
        }
    }

    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
        sessions.entrySet().removeIf(e -> e.getValue().getId().equals(session.getId()));
    }

    public void sendToUser(String userId, NotificationMessage message) {
        WebSocketSession session = sessions.get(userId);
        if (session != null && session.isOpen()) {
            try {
                session.sendMessage(new TextMessage(gson.toJson(message)));
            } catch (IOException e) {
                log.error("Failed to send WebSocket message to {}", userId, e);
            }
        }
    }

    private String extractUserId(WebSocketSession session) {
        // Lấy userId từ query param token
        URI uri = session.getUri();
        if (uri != null) {
            String query = uri.getQuery();
            if (query != null) {
                for (String param : query.split("&")) {
                    String[] pair = param.split("=", 2);
                    if (pair.length == 2 && "token".equals(pair[0])) {
                        // Decode JWT → extract sub claim
                        return extractSubFromJwt(pair[1]);
                    }
                }
            }
        }
        return null;
    }

    private String extractSubFromJwt(String token) {
        try {
            String[] parts = token.split("\\.");
            if (parts.length >= 2) {
                byte[] decoded = Base64.getUrlDecoder().decode(parts[1]);
                String json = new String(decoded, StandardCharsets.UTF_8);
                JsonObject claims = gson.fromJson(json, JsonObject.class);
                return claims.get("sub").getAsString();
            }
        } catch (Exception e) {
            log.warn("Failed to extract sub from JWT", e);
        }
        return null;
    }
}
```

---

## 6. Cơ sở dữ liệu (DB-per-service)

### 6.1 Database initialization

```bash
#!/bin/bash
# infra/postgres/init-dbs.sh

set -e

psql -U postgres -c "CREATE DATABASE assignment_db;"
psql -U postgres -c "CREATE DATABASE submission_db;"
psql -U postgres -c "CREATE DATABASE grading_db;"
psql -U postgres -c "CREATE DATABASE result_db;"
psql -U postgres -c "CREATE DATABASE notification_db;"
psql -U postgres -c "CREATE DATABASE keycloak_db;"
```

### 6.2 assignment_db

```sql
-- services/assignment-service/src/main/resources/db/migration/V1__init_schema.sql

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    name VARCHAR(200) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS assignments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES users(id),
    title TEXT NOT NULL,
    description TEXT,
    published BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS test_scenarios (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assignment_id UUID NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
    sequence_order INT NOT NULL DEFAULT 0,
    name TEXT NOT NULL,
    http_method VARCHAR(10) NOT NULL,
    endpoint TEXT NOT NULL,
    query_params JSONB,
    request_body JSONB,
    expected_response_body JSONB,
    expected_status INT DEFAULT 200,
    weight INT DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS path_variables (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    scenario_id UUID NOT NULL REFERENCES test_scenarios(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    variable_order INT NOT NULL,
    type TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS docker_image_bases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    image TEXT NOT NULL UNIQUE,
    platform TEXT NOT NULL,
    runtime_version TEXT,
    os TEXT DEFAULT 'linux',
    default_for_platform BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS assignment_docker_images (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assignment_id UUID NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
    docker_image_base_id UUID NOT NULL REFERENCES docker_image_bases(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_assignments_owner ON assignments(owner_id);
CREATE INDEX IF NOT EXISTS idx_assignments_published ON assignments(published) WHERE published = true;
CREATE INDEX IF NOT EXISTS idx_scenarios_assignment ON test_scenarios(assignment_id);
CREATE INDEX IF NOT EXISTS idx_path_vars_scenario ON path_variables(scenario_id);
CREATE INDEX IF NOT EXISTS idx_dib_platform ON docker_image_bases(platform);
CREATE INDEX IF NOT EXISTS idx_adb_assignment ON assignment_docker_images(assignment_id);
```

```sql
-- V2__seed_data.sql
INSERT INTO docker_image_bases (name, image, platform, runtime_version, default_for_platform)
VALUES
    ('Python 3.11 Slim', 'python:3.11-slim', 'python', '3.11', true),
    ('OpenJDK 21 JRE', 'eclipse-temurin:21-jre', 'java', '21', true),
    ('Node.js 20 Slim', 'node:20-slim', 'node', '20', true),
    ('Golang 1.22 Alpine', 'golang:1.22-alpine', 'golang', '1.22', true);
```

### 6.3 submission_db

```sql
-- services/submission-service/src/main/resources/db/migration/V1__init_schema.sql

CREATE TABLE IF NOT EXISTS submissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assignment_id UUID NOT NULL,
    student_id UUID NOT NULL,
    minio_path TEXT NOT NULL,
    zip_file_name TEXT,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    latest BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_submissions_student ON submissions(student_id);
CREATE INDEX IF NOT EXISTS idx_submissions_assignment ON submissions(assignment_id);
CREATE INDEX IF NOT EXISTS idx_submissions_status ON submissions(status);
```

### 6.4 grading_db

```sql
-- services/grading-service/src/main/resources/db/migration/V1__init_schema.sql

CREATE TABLE IF NOT EXISTS grading_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    submission_id UUID NOT NULL,
    step VARCHAR(100) NOT NULL,
    message TEXT,
    level VARCHAR(10) NOT NULL DEFAULT 'INFO',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_grading_logs_submission ON grading_logs(submission_id);
CREATE INDEX IF NOT EXISTS idx_grading_logs_created ON grading_logs(created_at);
```

### 6.5 result_db

```sql
-- services/result-service/src/main/resources/db/migration/V1__init_schema.sql

CREATE TABLE IF NOT EXISTS grading_results (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    submission_id UUID NOT NULL UNIQUE,
    assignment_id UUID NOT NULL,
    student_id UUID NOT NULL,
    score DOUBLE PRECISION NOT NULL,
    max_score DOUBLE PRECISION NOT NULL DEFAULT 10.0,
    status VARCHAR(20) NOT NULL,
    summary_log TEXT,
    graded_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS scenario_results (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    grading_result_id UUID NOT NULL REFERENCES grading_results(id) ON DELETE CASCADE,
    scenario_id UUID NOT NULL,
    scenario_name TEXT,
    passed BOOLEAN NOT NULL,
    actual_status INT,
    actual_body TEXT,
    error_message TEXT,
    weight INT DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_results_assignment ON grading_results(assignment_id);
CREATE INDEX IF NOT EXISTS idx_results_student ON grading_results(student_id);
CREATE INDEX IF NOT EXISTS idx_scenario_results_result ON scenario_results(grading_result_id);
```

### 6.6 notification_db

```sql
-- services/notification-service/src/main/resources/db/migration/V1__init_schema.sql

CREATE TABLE IF NOT EXISTS notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    type VARCHAR(50) NOT NULL,
    title TEXT NOT NULL,
    body TEXT,
    read BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_unread ON notifications(user_id, read) WHERE read = false;
```

---

## 7. Kafka Topics & Message Contracts

### 7.1 Topic overview

| Topic | Partitions | Replication | Retention | Key | Producer | Consumer |
|---|---|---|---|---|---|---|
| `grading-jobs` | 3 | 1 (dev) / 3 (prod) | 7 days | `submissionId` | Submission Service | Grading Service |
| `notifications` | 1 | 1 (dev) / 3 (prod) | 3 days | `userId` | Grading Service | Notification Service |

### 7.2 grading-jobs

**Producer (Submission Service):**
```java
kafkaTemplate.send("grading-jobs", submissionId.toString(), gson.toJson(job));
```

**Payload:**
```json
{
  "submissionId": "550e8400-e29b-41d4-a716-446655440000",
  "assignmentId": "660e8400-e29b-41d4-a716-446655440001",
  "studentId": "770e8400-e29b-41d4-a716-446655440002",
  "minioPath": "submissions/550e8400-e29b-41d4-a716-446655440000.zip",
  "timestamp": "2026-05-25T10:00:00Z"
}
```

**Java DTO:**
```java
@Data @Builder @NoArgsConstructor @AllArgsConstructor
public class GradingJob {
    private UUID submissionId;
    private UUID assignmentId;
    private UUID studentId;
    private String minioPath;
    private Instant timestamp;
}
```

### 7.3 notifications

**Producer (Grading Service):**
```java
NotificationMessage msg = NotificationMessage.builder()
    .userId(job.getStudentId())
    .type("GRADING_DONE")
    .title("Bài tập đã được chấm")
    .body(String.format("Điểm: %.1f / %.1f", score, maxScore))
    .submissionId(job.getSubmissionId())
    .timestamp(Instant.now())
    .build();

kafkaTemplate.send("notifications", msg.getUserId().toString(), gson.toJson(msg));
```

**Payload:**
```json
{
  "userId": "770e8400-e29b-41d4-a716-446655440002",
  "type": "GRADING_DONE",
  "title": "Bài tập Web - Đã chấm xong",
  "body": "Điểm: 8.5 / 10.0",
  "submissionId": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2026-05-25T10:05:00Z"
}
```

### 7.4 Kafka Config (Grading Service)

```yaml
spring:
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS:kafka:9092}
    consumer:
      group-id: grading-group
      auto-offset-reset: earliest
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      properties:
        max-poll-records: 1  # 1 record per poll → xử lý xong mới nhận tiếp
        session.timeout.ms: 30000
        heartbeat.interval.ms: 10000
    producer:
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.apache.kafka.common.serialization.StringSerializer
```

---

## 8. API Contracts đầy đủ

### 8.1 Assignment Service

**POST /api/v1/assignments** — Tạo bài tập

```http
POST /api/v1/assignments
Content-Type: application/json
Authorization: Bearer <jwt>

{
  "title": "Bài tập 1 - CRUD Books",
  "description": "Xây dựng REST API quản lý sách với Spring Boot",
  "requirements": [
    {
      "name": "GET danh sách sách",
      "sequenceOrder": 1,
      "httpMethod": "GET",
      "endpoint": "/api/v1/books",
      "expectedStatus": 200,
      "expectedResponseBody": "{\"data\":[]}",
      "weight": 2
    },
    {
      "name": "POST tạo sách",
      "sequenceOrder": 2,
      "httpMethod": "POST",
      "endpoint": "/api/v1/books",
      "requestBody": "{\"name\":\"Test Book\",\"author\":\"Author\"}",
      "expectedStatus": 201,
      "weight": 3
    }
  ],
  "dockerImageBaseIds": ["uuid1", "uuid2"]
}
```

Response `201`:
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "ownerId": "660e8400-e29b-41d4-a716-446655440001",
  "title": "Bài tập 1 - CRUD Books",
  "description": "Xây dựng REST API quản lý sách với Spring Boot",
  "published": false,
  "createdAt": "2026-05-25T10:00:00Z"
}
```

**GET /api/v1/assignments?page=0&size=20&search=&published=true** — Danh sách

Response `200`:
```json
{
  "content": [
    {
      "id": "uuid",
      "title": "Bài tập 1",
      "description": "...",
      "published": true,
      "ownerName": "Nguyễn Văn A",
      "scenarioCount": 5,
      "totalWeight": 10,
      "createdAt": "2026-05-25T10:00:00Z"
    }
  ],
  "totalElements": 10,
  "totalPages": 1,
  "number": 0,
  "size": 20
}
```

**POST /api/v1/assignments/{id}/scenarios** — Thêm test scenario

```json
{
  "name": "DELETE sách",
  "sequenceOrder": 3,
  "httpMethod": "DELETE",
  "endpoint": "/api/v1/books/{bookID}",
  "expectedStatus": 204,
  "weight": 1,
  "pathVariables": [
    {"name": "bookID", "order": 1, "type": "UUID"}
  ]
}
```

### 8.2 Submission Service

**POST /api/v1/submissions** — Nộp bài

```http
POST /api/v1/submissions
Content-Type: multipart/form-data
Authorization: Bearer <jwt>

file: @submission.zip
assignmentId: 550e8400-e29b-41d4-a716-446655440000
```

Response `202`:
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440010",
  "assignmentId": "550e8400-e29b-41d4-a716-446655440000",
  "zipFileName": "submission.zip",
  "status": "PENDING",
  "createdAt": "2026-05-25T10:00:00Z"
}
```

**GET /api/v1/submissions** — Bài nộp của tôi

Response `200`:
```json
[
  {
    "id": "uuid",
    "assignmentId": "uuid",
    "assignmentTitle": "Bài tập 1",
    "zipFileName": "submission.zip",
    "status": "DONE",
    "score": 8.5,
    "createdAt": "2026-05-25T10:00:00Z"
  }
]
```

### 8.3 Result Service

**GET /api/v1/results/{submissionId}**

Response `200`:
```json
{
  "submissionId": "550e8400-e29b-41d4-a716-446655440010",
  "assignmentId": "550e8400-e29b-41d4-a716-446655440000",
  "assignmentTitle": "Bài tập 1 - CRUD Books",
  "score": 8.5,
  "maxScore": 10.0,
  "status": "DONE",
  "scenarioResults": [
    {
      "scenarioName": "GET danh sách sách",
      "passed": true,
      "actualStatus": 200,
      "weight": 2
    },
    {
      "scenarioName": "POST tạo sách",
      "passed": false,
      "actualStatus": 500,
      "errorMessage": "Internal Server Error",
      "weight": 3
    },
    {
      "scenarioName": "DELETE sách",
      "passed": true,
      "actualStatus": 204,
      "weight": 1
    }
  ],
  "summaryLog": "Passed 2/3 scenarios, Score: 8.5/10",
  "gradedAt": "2026-05-25T10:05:00Z"
}
```

**GET /api/v1/results/assignment/{assignmentId}/stats**

Response `200`:
```json
{
  "assignmentId": "uuid",
  "totalSubmissions": 45,
  "averageScore": 7.2,
  "medianScore": 7.5,
  "highestScore": 10.0,
  "lowestScore": 0.0,
  "distribution": {
    "0-4": 5,
    "4-6": 8,
    "6-8": 18,
    "8-10": 14
  },
  "gradedCount": 45,
  "pendingCount": 2,
  "failedCount": 3
}
```

### 8.4 Notification Service

**WebSocket — ws://host:8085/ws/notifications?token=<jwt>**

Tin nhắn từ server khi có kết quả chấm:
```json
{
  "type": "GRADING_DONE",
  "title": "Bài tập Web - Đã chấm xong",
  "body": "Điểm: 8.5 / 10.0",
  "submissionId": "550e8400-e29b-41d4-a716-446655440010",
  "timestamp": "2026-05-25T10:05:00Z"
}
```

**GET /api/v1/notifications/history?page=0&size=20**

Response `200`:
```json
{
  "content": [
    {
      "id": "uuid",
      "type": "GRADING_DONE",
      "title": "Bài tập Web - Đã chấm xong",
      "body": "Điểm: 8.5 / 10.0",
      "read": false,
      "createdAt": "2026-05-25T10:05:00Z"
    }
  ],
  "totalElements": 10,
  "totalPages": 1
}
```

---

## 9. Security & Keycloak

### 9.1 Keycloak Setup

**Docker Compose:**
```yaml
keycloak:
  image: quay.io/keycloak/keycloak:26.0
  command: start --http-port 8088
  environment:
    KC_DB: postgres
    KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak_db
    KC_DB_USERNAME: postgres
    KC_DB_PASSWORD: postgres
    KEYCLOAK_ADMIN: admin
    KEYCLOAK_ADMIN_PASSWORD: admin
  ports:
    - "8088:8088"
  depends_on:
    postgres:
      condition: service_healthy
```

**Realm Configuration (thủ công qua Keycloak Admin Console):**

1. Realm: `grading-platform`
2. Clients:
   - `frontend`: public client, redirect URI `http://localhost:3000/*`
   - `gateway`: confidential client, Service Account Roles enabled
3. Roles:
   - `lecturer`
   - `student`
4. Users:
   - Tạo user với role `lecturer`
   - Tạo user với role `student`

**Export realm để persist:**
```bash
docker exec -it keycloak /opt/keycloak/bin/kc.sh export \
  --realm grading-platform --file /tmp/realm-export.json --users realm_file
```

### 9.2 JWT Validation Flow

```
Client                      API Gateway                  Downstream Service
  │                             │                              │
  │── POST /assignments ──────▶ │                              │
  │    Authorization: Bearer JWT│                              │
  │                             │── Validate JWT:              │
  │                             │   signature ✓, exp ✓        │
  │                             │   issuer: keycloak ✓        │
  │                             │                              │
  │                             │── Extract claims:            │
  │                             │   sub → X-User-Id           │
  │                             │   role → X-User-Role        │
  │                             │                              │
  │                             │── Route to assignment-svc ──▶│
  │                             │   X-User-Id: xxx            │
  │                             │   X-User-Role: lecturer     │
  │                             │                              │
  │                             │                              │── Process request
  │                             │◄── Response ───────────────│
  │◄── Response ───────────────│                              │
```

### 9.3 Security trong từng service

**API Gateway:** Validate JWT (OAuth2 Resource Server), chuyển header

**Downstream services:** Trust Gateway (internal network), nhưng vẫn nên validate user id cho sensitive operations:

```java
@Service
public class AssignmentService {
    public AssignmentResponse create(CreateAssignmentRequest request,
                                     @RequestHeader("X-User-Id") UUID userId,
                                     @RequestHeader("X-User-Role") String role) {
        if (!"lecturer".equals(role)) {
            throw new AccessDeniedException("Only lecturers can create assignments");
        }
        // ...
    }
}
```

### 9.4 Container Security (Grading)

```yaml
# Resource limits enforced in DockerService
grading:
  container:
    max-memory: 256m        # Max RAM per student container
    max-cpu: 0.5            # Max CPU cores per student container
    startup-timeout-ms: 60000
    max-execution-time-ms: 300000
```

**Thêm các biện pháp bảo mật:**
- Không cho phép `privileged: true` trong docker-compose của SV
- Không exposed port ra host (dùng internal network + reverse proxy)
- Read-only filesystem cho student container
- Network isolation (cô lập với container khác)
- Timeout kill container sau 5 phút
- Chạy với non-root user bên trong container

---

## 10. Deployment (Docker Compose toàn hệ thống)

### 10.1 docker-compose.yml

```yaml
version: '3.9'

services:
  # ============================================================
  # INFRASTRUCTURE
  # ============================================================

  postgres:
    image: postgres:16-alpine
    container_name: grading-postgres
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports:
      - "5432:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./postgres/init-dbs.sh:/docker-entrypoint-initdb.d/init-dbs.sh
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - grading-network

  kafka:
    image: bitnami/kafka:3.9
    container_name: grading-kafka
    ports:
      - "9092:9092"
    environment:
      KAFKA_CFG_NODE_ID: 0
      KAFKA_CFG_PROCESS_ROLES: controller,broker
      KAFKA_CFG_CONTROLLER_QUORUM_VOTERS: 0@kafka:9093
      KAFKA_CFG_LISTENERS: PLAINTEXT://:9092,CONTROLLER://:9093
      KAFKA_CFG_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092
      KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
      KAFKA_CFG_CONTROLLER_LISTENER_NAMES: CONTROLLER
    volumes:
      - kafka-data:/bitnami/kafka
    networks:
      - grading-network

  minio:
    image: minio/minio:latest
    container_name: grading-minio
    command: server /data --console-address :9001
    ports:
      - "9000:9000"   # API
      - "9001:9001"   # Console
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    volumes:
      - minio-data:/data
    networks:
      - grading-network

  keycloak:
    image: quay.io/keycloak/keycloak:26.0
    container_name: grading-keycloak
    command: start --http-port 8088
    ports:
      - "8088:8088"
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak_db
      KC_DB_USERNAME: postgres
      KC_DB_PASSWORD: postgres
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: admin
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - grading-network

  # ============================================================
  # MICROSERVICES
  # ============================================================

  eureka-server:
    build: ../services/eureka-server
    container_name: grading-eureka
    ports:
      - "8761:8761"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8761/actuator/health"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - grading-network

  config-server:
    build: ../services/config-server
    container_name: grading-config
    ports:
      - "8888:8888"
    depends_on:
      eureka-server:
        condition: service_healthy
    volumes:
      - ../infra/config-repo:/config-repo
    networks:
      - grading-network

  gateway:
    build: ../services/gateway
    container_name: grading-gateway
    ports:
      - "8080:8080"
    depends_on:
      eureka-server:
        condition: service_healthy
      keycloak:
        condition: service_started
    environment:
      SPRING_PROFILES_ACTIVE: docker
    networks:
      - grading-network

  assignment-service:
    build: ../services/assignment-service
    container_name: grading-assignment
    depends_on:
      eureka-server:
        condition: service_healthy
      config-server:
        condition: service_started
      postgres:
        condition: service_healthy
    environment:
      SPRING_PROFILES_ACTIVE: docker
      DB_USERNAME: postgres
      DB_PASSWORD: postgres
    networks:
      - grading-network

  submission-service:
    build: ../services/submission-service
    container_name: grading-submission
    depends_on:
      eureka-server:
        condition: service_healthy
      config-server:
        condition: service_started
      postgres:
        condition: service_healthy
      kafka:
        condition: service_started
    environment:
      SPRING_PROFILES_ACTIVE: docker
      DB_USERNAME: postgres
      DB_PASSWORD: postgres
      KAFKA_BOOTSTRAP_SERVERS: kafka:9092
    networks:
      - grading-network

  grading-service:
    build: ../services/grading-service
    container_name: grading-executor
    depends_on:
      eureka-server:
        condition: service_healthy
      config-server:
        condition: service_started
      postgres:
        condition: service_healthy
      kafka:
        condition: service_started
    environment:
      SPRING_PROFILES_ACTIVE: docker
      DB_USERNAME: postgres
      DB_PASSWORD: postgres
      KAFKA_BOOTSTRAP_SERVERS: kafka:9092
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock   # Cho Docker-in-Docker
      - grading-tmp:/tmp/grading
    networks:
      - grading-network

  result-service:
    build: ../services/result-service
    container_name: grading-result
    depends_on:
      eureka-server:
        condition: service_healthy
      config-server:
        condition: service_started
      postgres:
        condition: service_healthy
    environment:
      SPRING_PROFILES_ACTIVE: docker
      DB_USERNAME: postgres
      DB_PASSWORD: postgres
    networks:
      - grading-network

  notification-service:
    build: ../services/notification-service
    container_name: grading-notification
    depends_on:
      eureka-server:
        condition: service_healthy
      config-server:
        condition: service_started
      postgres:
        condition: service_healthy
      kafka:
        condition: service_started
    environment:
      SPRING_PROFILES_ACTIVE: docker
      DB_USERNAME: postgres
      DB_PASSWORD: postgres
      KAFKA_BOOTSTRAP_SERVERS: kafka:9092
    networks:
      - grading-network

volumes:
  postgres-data:
  kafka-data:
  minio-data:
  grading-tmp:

networks:
  grading-network:
    driver: bridge
```

### 10.2 Dockerfile mẫu cho mỗi service

```dockerfile
# services/assignment-service/Dockerfile
FROM eclipse-temurin:25-jre-alpine AS builder
WORKDIR /build
COPY pom.xml .
RUN mvn dependency:go-offline
COPY src ./src
RUN mvn package -DskipTests

FROM eclipse-temurin:25-jre-alpine
WORKDIR /app
COPY --from=builder /build/target/*.jar app.jar
EXPOSE 8081
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### 10.3 Startup order

```
1. postgres ── health check
2. kafka
3. minio
4. keycloak
5. eureka-server ── health check
6. config-server ── health check
7. assignment-service, submission-service, result-service, notification-service
8. grading-service (needs kafka + db)
9. gateway (needs eureka + keycloak)
```

---

## 11. Cách khắc phục bottleneck & scale lên

### 11.1 Danh sách bottleneck & giải pháp

| # | Bottleneck | Mức | Giải pháp trong architecture này |
|---|---|---|---|
| 1 | **Single service xử lý mọi thứ** | 🔴 | Tách thành 8 microservice, mỗi service 1 việc |
| 2 | **Chờ synchronous grading** | 🔴 | Kafka async: submit → 202 → chấm sau |
| 3 | **Port conflict** | 🟡 | `PortAllocator` synchronized (ConcurrentHashMap) |
| 4 | **Không resource limits** | 🔴 | `DockerComposePatcher` thêm memory/cpu limits |
| 5 | **Không auth** | 🔴 | Keycloak OAuth2 + JWT validation ở Gateway |
| 6 | **Kết quả text/plain** | 🟡 | Result Service với structured JSON + DB |
| 7 | **Hardcode URL** | 🟡 | Eureka service discovery + Config Server |
| 8 | **Image pull time** | 🟢 | Docker layer cache + image warming |
| 9 | **Không concurrent processing** | 🔴 | Kafka partitions + N Grading Service instances |
| 10 | **Không real-time** | 🟢 | WebSocket Notification Service |

### 11.2 Chiến lược scale

#### Horizontal Scaling

```
Grading Service Pool:

ka​fka:9092
topic: grading-jobs
   partition-0 ──▶ Grading Service Instance 1  (submission-1, 2, 3)
   partition-1 ──▶ Grading Service Instance 2  (submission-4, 5, 6)
   partition-2 ──▶ Grading Service Instance 3  (submission-7, 8, 9)
   
   Mỗi instance xử lý 4 concurrent:
   Instance 1: 4 bài × 512MB = 2GB
   Instance 2: 4 bài × 512MB = 2GB
   Instance 3: 4 bài × 512MB = 2GB
   Tổng: 12 bài đồng thời
```

**Cấu hình cho Grading Service instances:**

```yaml
# docker-compose scale
docker compose up -d --scale grading-service=5

# Mỗi instance:
services:
  grading-service:
    environment:
      KAFKA_CONSUMER_CONCURRENCY: 4  # 4 threads per instance
      JAVA_OPTS: "-Xmx512m"
```

#### Image Warming (chạy lúc grading service startup)

```bash
#!/bin/bash
# services/grading-service/warm-images.sh

IMAGES=(
  "python:3.11-slim"
  "node:20-slim"
  "eclipse-temurin:21-jre"
  "golang:1.22-alpine"
  "nginx:alpine"
  "postgres:16-alpine"
  "mysql:8.0"
)

for IMAGE in "${IMAGES[@]}"; do
  echo "Warming image: $IMAGE"
  docker pull "$IMAGE" &
done

wait
echo "All images warmed!"
```

#### Docker Registry Mirror (for production)

```yaml
# Thêm registry mirror vào docker-compose
registry:
  image: registry:2
  ports:
    - "5000:5000"
  volumes:
    - registry-data:/var/lib/registry

# Cấu hình Docker daemon trên host:
# /etc/docker/daemon.json
{
  "registry-mirrors": ["http://registry:5000"],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

### 11.3 Resource sizing

| # Grading Instances | Concurrent/instance | Total concurrent | RAM needed | Có xử lý trong |
|---|---|---|---|---|
| 1 | 2 | 2 | 1 GB | 50 bài ~ 25 phút |
| 2 | 4 | 8 | 2 GB | 50 bài ~ 6 phút |
| 4 | 4 | 16 | 4 GB | 50 bài ~ 3 phút |
| 8 | 4 | 32 | 8 GB | 50 bài ~ 1.5 phút |

Với server 32GB RAM, 16 core: chạy 8 Grading Service instances, mỗi instance 4 concurrent = **32 bài đồng thời**. Hàng trăm bài nộp trong vài phút.

### 11.4 Giới hạn scale (khi nào cần Kubernetes)

- **500-1000 submissions/ngày:** Kiến trúc Docker Compose này đủ
- **5000+ submissions/ngày (MOOC):** Cần Kubernetes
  - Kubernetes Pod per submission (thay vì Docker compose)
  - Horizontal Pod Autoscaler dựa trên queue depth
  - Node pool cho Grading Pods
  - Persistent Volume cho image cache

---

## 12. Implementation Roadmap

### Phase 1 — Foundation (1-2 tuần)

**Mục tiêu:** Infrastructure services chạy, Gateway route được, auth hoạt động

```
[ ] 1.1 Eureka Server setup
[ ] 1.2 Config Server + config-repo
[ ] 1.3 API Gateway + route rules
[ ] 1.4 Keycloak setup (Docker Compose + realm config)
[ ] 1.5 Gateway integrate OAuth2 resource server + JWT validation
[ ] 1.6 Docker Compose infra up and verify all services connect

Files:
  - services/eureka-server/
  - services/config-server/
  - services/gateway/
  - infra/docker-compose.yml
  - infra/docker-compose.infra.yml
  - infra/postgres/init-dbs.sh
  - infra/config-repo/*.yml
```

### Phase 2 — Assignment Service (1 tuần)

**Mục tiêu:** CRUD assignments + scenarios, kế thừa code cũ

```
[ ] 2.1 Port code từ ExerciseController → AssignmentController
[ ] 2.2 Đổi tên entity: Exercise → Assignment, ExerciseRequirement → TestScenario
[ ] 2.3 Flyway migration mới
[ ] 2.4 CRUD endpoints (kèm pagination)
[ ] 2.5 Internal endpoints cho Grading Service
[ ] 2.6 Seed Docker base images

Files:
  - services/assignment-service/
  - services/assignment-service/src/main/resources/db/migration/
```

### Phase 3 — Submission Service + Kafka (1 tuần)

**Mục tiêu:** Upload file + validate + Kafka producer

```
[ ] 3.1 Submission entity + DB
[ ] 3.2 MinIO upload (port từ MinioService.java cũ)
[ ] 3.3 Validate zip chứa docker-compose.yml
[ ] 3.4 Kafka producer (grading-jobs topic)
[ ] 3.5 Submission CRUD endpoints
[ ] 3.6 Feign client gọi Assignment Service để validate

Files:
  - services/submission-service/
```

### Phase 4 — Grading Service (2-3 tuần)

**Mục tiêu:** Kafka consumer + Docker + test execution (phần khó nhất)

```
[ ] 4.1 Kafka consumer (grading-jobs)
[ ] 4.2 Docker compose up/down (port từ DockerService.java cũ)
[ ] 4.3 DockerComposePatcher (thêm resource limits vào YAML)
[ ] 4.4 PortAllocator (quản lý port tập trung)
[ ] 4.5 TestExecutor (dynamic Feign + chạy scenario)
[ ] 4.6 ResponseComparator (Gson compare cấu trúc JSON)
[ ] 4.7 Feign clients gọi Assignment Service + Result Service
[ ] 4.8 Grading log + error handling
[ ] 4.9 Container timeouts + cleanup

Files:
  - services/grading-service/
```

### Phase 5 — Result Service + Notification Service (1 tuần)

**Mục tiêu:** Lưu kết quả, thống kê, WebSocket notification

```
[ ] 5.1 Result entities + DB
[ ] 5.2 ResultController (xem kết quả, thống kê)
[ ] 5.3 Internal endpoint cho Grading Service ghi result
[ ] 5.4 Notification entities + DB
[ ] 5.5 WebSocket handler
[ ] 5.6 Kafka consumer (notifications)
[ ] 5.7 NotificationController (lịch sử)

Files:
  - services/result-service/
  - services/notification-service/
```

### Phase 6 — Frontend (2-3 tuần)

**Mục tiêu:** React + Keycloak + Dashboard

```
[ ] 6.1 Keycloak JS adapter (Login/Logout)
[ ] 6.2 Lecturer: tạo/bài tập, thêm scenarios
[ ] 6.3 Student: nộp bài (multipart upload)
[ ] 6.4 Xem kết quả + điểm số
[ ] 6.5 Thống kê (lecturer)
[ ] 6.6 WebSocket real-time notification
```

### Phase 7 — Polish + Report (1-2 tuần)

```
[ ] 7.1 Error handling toàn hệ thống
[ ] 7.2 Request validation (Bean Validation)
[ ] 7.3 Logging (SLF4j + centralized logs)
[ ] 7.4 Rate limiting trên Gateway
[ ] 7.5 Container timeout enforcement
[ ] 7.6 Security hardening
[ ] 7.7 Viết báo cáo đồ án
```

---

## 13. Kế thừa code hiện tại

### 13.1 Mapping file cũ → service mới

| File/Class cũ (monolith) | Service mới | Ghi chú |
|---|---|---|
| `DemoApplication.java` | → Mỗi service có *Application riêng | Thêm `@EnableDiscoveryClient` |
| `model/BaseUUID.java` | → Copy vào mỗi service | Hoặc `common-lib` module |
| `model/User.java` | → `assignment-service` | Chỉ validate owner |
| `model/Exercise.java` | → `assignment-service` | Đổi tên → `Assignment` |
| `model/ExerciseRequirement.java` | → `assignment-service` | Đổi tên → `TestScenario` |
| `model/PathVariable.java` | → `assignment-service` | Đổi FK: `scenarioId` |
| `model/DockerImageBase.java` | → `assignment-service` | Giữ nguyên |
| `model/ExerciseDockerImageBase.java` | → `assignment-service` | Đổi tên → `AssignmentDockerImage` |
| `repository/ExerciseRepository.java` | → `assignment-service` | Đổi tên → `AssignmentRepository` |
| `repository/ExerciseRequirementRepository.java` | → `assignment-service` | Đổi tên → `ScenarioRepository` |
| `repository/PathVariableRepository.java` | → `assignment-service` | Đổi FK field |
| `repository/DockerImageBaseRepository.java` | → `assignment-service` | Giữ nguyên |
| `repository/ExerciseDockerImageBaseRepository.java` | → `assignment-service` | Đổi tên → `AssignmentDockerImageRepository` |
| `repository/UserRepository.java` | → `assignment-service` | Chỉ `findByEmail` |
| `service/ExerciseService.java` | → `assignment-service` | Tách: `AssignmentService` + `ScenarioService` |
| **`service/DockerService.java`** | → **`grading-service`** | Cải tiến: PortAllocator, timeout, resource limits |
| **`service/EvaluationService.java`** | → **`grading-service`** | Tách → `GradingOrchestrator` + `TestExecutor` |
| `service/MinioService.java` | → `submission-service` + `grading-service` | Upload ở submission, download ở grading |
| `controller/ExerciseController.java` | → `assignment-service` | Thêm CRUD đầy đủ + pagination |
| `controller/FileController.java` | → `submission-service` + `grading-service` | Upload → submission; evaluation → grading |
| `feign/FeignClientFactory.java` | → `grading-service` | Dynamic Feign cho student container |
| **`feign/SubmissionClient.java`** | → **`grading-service`** | Giữ nguyên interface |
| `dto/response/DockerSubmissionResult.java` | → `grading-service` | Có thể giữ hoặc refactor |
| `dto/request/CreateExerciseRequest.java` | → `assignment-service` | Đổi tên → `CreateAssignmentRequest` |
| `dto/request/CreateExerciseRequirementRequest.java` | → `assignment-service` | Đổi tên → `CreateScenarioRequest` |
| `configuration/GsonConfig.java` | → copy vào mỗi service | Hoặc shared `common-lib` |
| `configuration/MinioConfiguration.java` | → `submission-service` + `grading-service` | Copy |
| `mapper/ExerciseMapper.java` | → `assignment-service` | Đổi tên → `AssignmentMapper` |
| `application.yaml` | → `infra/config-repo/` | Tách thành file per service |

### 13.2 Shared Library (common-lib)

Để giảm trùng lặp code (BaseEntity, GsonConfig, Minio config...), có thể tạo module chung:

```
services/common-lib/
├── pom.xml
└── src/main/java/com/ptit/grading/common/
    ├── model/
    │   └── BaseEntity.java
    ├── config/
    │   └── GsonConfig.java
    └── client/
        └── FeignClientFactory.java
```

```xml
<!-- Trong pom.xml của mỗi service -->
<dependency>
    <groupId>com.ptit.grading</groupId>
    <artifactId>common-lib</artifactId>
    <version>1.0.0</version>
</dependency>
```

**Lưu ý:** Với mục đích đồ án, copy code vào mỗi service cũng OK (dễ debug, không phải build common-lib riêng). Nhưng nếu muốn code clean, dùng common-lib.

---

## Phụ lục

### A. Error codes

| Code | HTTP Status | Ý nghĩa |
|---|---|---|
| `ASSIGNMENT_NOT_FOUND` | 404 | Bài tập không tồn tại |
| `SUBMISSION_NOT_FOUND` | 404 | Bài nộp không tồn tại |
| `RESULT_NOT_FOUND` | 404 | Kết quả không tồn tại |
| `INVALID_ZIP_FORMAT` | 400 | File không phải zip hoặc thiếu docker-compose.yml |
| `ASSIGNMENT_NOT_PUBLISHED` | 403 | Bài tập chưa publish |
| `GRADING_TIMEOUT` | 408 | Container không start kịp |
| `DOCKER_COMPOSE_FAILED` | 500 | Docker compose failed |
| `UNAUTHORIZED` | 401 | Token invalid/expired |
| `FORBIDDEN` | 403 | Không có quyền |

### B. Environment variables

| Variable | Default | Mô tả |
|---|---|---|
| `DB_USERNAME` | `postgres` | PostgreSQL username |
| `DB_PASSWORD` | `postgres` | PostgreSQL password |
| `KAFKA_BOOTSTRAP_SERVERS` | `kafka:9092` | Kafka broker |
| `MINIO_ENDPOINT` | `http://minio:9000` | MinIO endpoint |
| `GRADING_MAX_MEMORY` | `256m` | Max RAM per container |
| `GRADING_MAX_CPU` | `0.5` | Max CPU per container |
| `GRADING_STARTUP_TIMEOUT` | `60000` | Container startup timeout (ms) |
| `GRADING_EXEC_TIMEOUT` | `300000` | Execution timeout (ms) |

### C. Monitoring (tương lai)

- Spring Boot Actuator: `/actuator/health`, `/actuator/metrics`, `/actuator/info`
- Kafka Lag Monitoring: `/actuator/kafkalag` (Spring Boot Actuator + Kafka)
- Log aggregation: ELK (Elasticsearch + Logstash + Kibana)
- Metrics: Prometheus + Grafana

---

> **Kết luận:** Kiến trúc này giải quyết tất cả bottleneck của hệ thống cũ. 
> Image downloading không phải vấn đề (Docker layer cache).
> Bottleneck thật (RAM/CPU) được giải quyết bằng Kafka worker pool + concurrent processing.
> Với server 32GB RAM, hệ thống xử lý hàng trăm bài nộp trong vài phút.
> Có thể scale ngang không giới hạn bằng cách thêm Grading Service instances.
