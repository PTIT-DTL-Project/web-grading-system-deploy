# Fix Trace Service Names Through API Gateway

**Date:** 2026-11-08  
**Issue:** All traces show `api-gateway: http get` instead of downstream service names  
**Impact:** Cannot distinguish which internal service handled the request in Grafana  

---

## Problem

Traces through API Gateway show:
```
✗ api-gateway: http get (generic)
  └─ HTTP GET
     └─ course-service: http get /api/v1/student/assignments/{id}/plans
```

**Want:**
```
✓ api-gateway: GET /api/v1/student/assignments/... → course-service
  └─ course-service: GET /api/v1/student/assignments/{id}/plans
```

---

## Root Cause

Spring Cloud Gateway + Micrometer creates spans with:
- **Service name:** Always `api-gateway` (from `spring.application.name`)
- **Operation name:** Generic `http get` (doesn't include route info)

Downstream services ARE traced correctly (visible in span tree), but:
- Gateway span name is too generic
- No indication which service it routed to at the gateway level

---

## Solutions

### Solution 1: Add Route Metadata to Span Tags (RECOMMENDED)

**In api-gateway service:**

Add a custom filter to tag spans with route destination:

```java
@Configuration
public class TracingConfiguration {
    
    @Bean
    public GlobalFilter routeTracingFilter() {
        return (exchange, chain) -> {
            Route route = exchange.getAttribute(ServerWebExchangeUtils.GATEWAY_ROUTE_ATTR);
            if (route != null) {
                Span currentSpan = Span.current();
                if (currentSpan != null) {
                    // Tag span with target service
                    URI uri = route.getUri();
                    String targetService = uri.getHost(); // e.g., "course-service"
                    currentSpan.setAttribute("gateway.route.id", route.getId());
                    currentSpan.setAttribute("gateway.target.service", targetService);
                    
                    // Update span name to include target service
                    currentSpan.updateName("gateway → " + targetService);
                }
            }
            return chain.filter(exchange);
        };
    }
}
```

**Result in Grafana:**
```
gateway → course-service (1.65s)
  └─ course-service: GET /api/v1/student/assignments/{id}/plans (1.61s)
```

---

### Solution 2: Use Spring Cloud Gateway Observability

**In api-gateway `application.yaml`:**

```yaml
spring:
  cloud:
    gateway:
      observability:
        enabled: true
      # Define routes with meaningful IDs
      routes:
        - id: course-service-student-assignments
          uri: lb://course-service
          predicates:
            - Path=/api/v1/student/assignments/**
          metadata:
            # This appears in span tags
            response-timeout: 5000
            connect-timeout: 3000
```

**Add to `build.gradle` or `pom.xml`:**

```gradle
implementation 'io.micrometer:micrometer-tracing-bridge-otel'
implementation 'io.opentelemetry:opentelemetry-exporter-otlp'
```

**Configure Micrometer observation:**

```yaml
management:
  tracing:
    sampling:
      probability: 1.0
  otlp:
    tracing:
      endpoint: http://tempo.observability.svc.cluster.local:4318/v1/traces
```

---

### Solution 3: Custom Span Name with Path

**Use Spring Cloud Gateway's built-in span customization:**

```java
@Configuration
public class ObservationConfiguration {
    
    @Bean
    public ObservationHandler<ServerRequestObservationContext> customSpanNameHandler() {
        return new ObservationHandler<>() {
            @Override
            public void onStart(ServerRequestObservationContext context) {
                ServerHttpRequest request = context.getCarrier();
                String method = request.getMethod().name();
                String path = request.getPath().value();
                
                // Shorten path for readability
                String shortPath = path.length() > 50 
                    ? path.substring(0, 47) + "..." 
                    : path;
                
                // Update observation name
                context.setContextualName(method + " " + shortPath);
            }

            @Override
            public boolean supportsContext(Observation.Context context) {
                return context instanceof ServerRequestObservationContext;
            }
        };
    }
}
```

**Result:**
```
api-gateway: GET /api/v1/student/assignments/...
```

---

### Solution 4: Add Custom Span Tags (Easiest)

**In api-gateway, add a filter:**

```java
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class RouteTaggingFilter implements GlobalFilter {
    
    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        Route route = exchange.getAttribute(ServerWebExchangeUtils.GATEWAY_ROUTE_ATTR);
        
        return chain.filter(exchange).contextWrite(context -> {
            if (route != null) {
                Span span = Span.current();
                span.setAttribute("http.route", route.getId());
                span.setAttribute("gateway.target", route.getUri().toString());
            }
            return context;
        });
    }
}
```

**Then in Grafana Tempo, you can:**
- Filter by `http.route` attribute
- See target service in span details
- Create service map based on `gateway.target`

---

## Quick Fix (No Code Change)

**Use TraceQL queries to filter:**

```traceql
# Find all gateway requests to course-service
{ 
  resource.service.name = "api-gateway" && 
  span.http.url =~ ".*course-service.*"
}

# Find by path pattern
{
  resource.service.name = "api-gateway" &&
  span.http.target =~ ".*assignments.*"
}
```

**In Grafana, group by:**
- `span.http.target` (path)
- `span.http.route` (if tagged)

---

## Verification

After implementing Solution 1 or 2:

1. **Make a request through gateway:**
   ```bash
   curl https://web-dev1-gateway.../api/v1/student/assignments/xxx/plans
   ```

2. **Check trace in Grafana:**
   - Span name should show target service
   - Span attributes should include `gateway.target.service`
   - Service map should show `api-gateway → course-service`

3. **Verify span structure:**
   ```
   ✓ gateway → course-service (parent span, 1.65s)
     └─ course-service: GET /assignments/{id}/plans (child, 1.61s)
   ```

---

## Why This Happens

**Spring Cloud Gateway architecture:**
```
Client → Gateway (span: "api-gateway: http get")
           ↓ WebClient call
         Internal Service (span: "course-service: http get /path")
```

**Problem:**
- Gateway span uses generic operation name
- Doesn't include routing metadata by default
- Spring Cloud Gateway observability is opt-in

**Solution:** Add custom logic to enrich gateway spans with route/target info.

---

## Alternative: Use Service Mesh

If you have **Istio/Linkerd** service mesh:
- Service mesh injects sidecars that create detailed spans
- Automatic service-to-service tracing
- No application code changes needed

**Example with Istio:**
```yaml
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: tracing
spec:
  tracing:
    - providers:
      - name: tempo
      customTags:
        destination_service:
          literal:
            value: "{{ .Destination.Service }}"
```

---

## References

- [Spring Cloud Gateway Observability](https://docs.spring.io/spring-cloud-gateway/reference/spring-cloud-gateway/observability.html)
- [Micrometer Tracing](https://micrometer.io/docs/tracing)
- [OpenTelemetry Span Attributes](https://opentelemetry.io/docs/specs/semconv/http/http-spans/)

---

**Prepared by:** AI Agent  
**Review date:** 2026-11-08  
**Status:** Solutions documented, requires api-gateway code change  
**Recommendation:** Solution 1 (custom filter) for minimal code change and clear results
