# generate-charts.sh port bug fix

## Problem

`config-services/generate-charts.sh` line 19 mapped `course-service` to port `8085` and `assignment_db`, but the actual `course-service/values-stg.yaml` has port `8081` and `assignment_db`. Running the script overwrote the correct manually-created values files with wrong port numbers.

Additionally, the script's `SERVICES` map was missing `submission-service` entirely — the generator silently skipped it when run.

## Fix

```diff
     ["course-service"]="8085:assignment_db"
+    ["submission-service"]="8082:submission_db"
```

Changed to:

```bash
    ["course-service"]="8081:assignment_db"
    ["submission-service"]="8082:submission_db"
```

## Verified

Sandbox run confirmed all 5 generated `values-stg.yaml` files now match the real ones:

| Service | Port | DB |
|---|---|---|
| api-gateway | 8080 | api_gateway_db |
| course-service | 8081 | assignment_db |
| executor-service | 8083 | executor_db |
| result-service | 8084 | result_db |
| submission-service | 8082 | submission_db |

## Date

2026-09-12
