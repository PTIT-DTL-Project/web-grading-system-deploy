# Plan: Add Keycloak to Cloudflare Zero Trust Tunnel

## Goal
Deploy Keycloak in the k3s cluster and make it accessible via `web-dev1-keycloak.vucongtuanduong.dpdns.org` through the existing Cloudflare Zero Trust tunnel.

## Context
- Project uses **k3s + ArgoCD + Cloudflare Zero Trust tunnels** (not local cloudflared).
- Infrastructure components (RustFS, Kafka UI) are deployed via direct k8s manifests in `deploy/`.
- Microservices are deployed via ArgoCD from `config-services/` (remote GitHub repo).
- `deploy/ingress/keycloak.yaml` already exists but points to a non-existent `keycloak` service.
- The api-gateway already has JWT validation wired; it just needs `KEYCLOAK_ISSUER_URI`.

## Changes

### 1. Update `.env`
Add Keycloak configuration:
```bash
# ---- Keycloak ----------------------------------------------------------------
KEYCLOAK_DB_URL=jdbc:postgresql://<db-host>:5432/keycloak?sslmode=require
KEYCLOAK_DB_USERNAME=<db_username>
KEYCLOAK_DB_PASSWORD=<db_password>
KEYCLOAK_ISSUER_URI=https://web-dev1-keycloak.vucongtuanduong.dpdns.org/realms/ptit-wgs
KEYCLOAK_ADMIN_USERNAME=<admin_username>
KEYCLOAK_ADMIN_PASSWORD=<admin_password>
```

### 2. Update `.env.example`
Mirror the new Keycloak variables with placeholder defaults.

### 3. Create `deploy/keycloak/deployment.yaml`
Keycloak Deployment matching the user's Docker Compose:
- Image: `quay.io/keycloak/keycloak:26.0`
- Command: `start-dev`
- Port: `8080`
- Env: `KC_DB`, `KC_DB_URL`, `KC_DB_USERNAME`, `KC_DB_PASSWORD`, `KC_BOOTSTRAP_ADMIN_USERNAME`, `KC_BOOTSTRAP_ADMIN_PASSWORD`, `KC_HTTP_PORT`, `KC_HOSTNAME_STRICT`, `KC_HTTP_ENABLED`
- Reference secrets for DB credentials
- Healthcheck: HTTP GET `/health/ready` on port `8080`

### 4. Create `deploy/keycloak/service.yaml`
ClusterIP Service:
- Name: `keycloak`
- Port: `8080`
- Target port: `8080`
- Namespace: `web-grading`

### 5. Update `deploy/setup-namespace.sh`
Create `keycloak-db` secret from `.env`:
```bash
kubectl create secret generic keycloak-db \
  --namespace "${NAMESPACE}" \
  --from-literal=KEYCLOAK_DB_URL="${KEYCLOAK_DB_URL:-}" \
  --from-literal=KEYCLOAK_DB_USERNAME="${KEYCLOAK_DB_USERNAME:-}" \
  --from-literal=KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-}" \
  --from-literal=KEYCLOAK_ADMIN_USERNAME="${KEYCLOAK_ADMIN_USERNAME:-admin}" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 6. Update `setup_without_cloudflared.sh`
Add Keycloak deployment step after Kafka UI:
```bash
print_step "7. Deploy Keycloak"
bash "$SCRIPT_DIR/deploy/keycloak/deploy-keycloak.sh" || echo "  Keycloak deploy script missing, skipping"
kubectl apply -n "$NAMESPACE" -f "$SCRIPT_DIR/deploy/keycloak/deployment.yaml"
kubectl apply -n "$NAMESPACE" -f "$SCRIPT_DIR/deploy/keycloak/service.yaml"
kubectl wait -n "$NAMESPACE" --for=condition=ready pod -l app=keycloak --timeout=120s || true
print_success "Keycloak deployed"
```
Also add Keycloak to the printed summary and port-forward hint.

### 7. Update `setup.sh`
Same Keycloak deployment step as above. Note: `setup.sh` still references `deploy/cloudflared/` which no longer exists — those lines will fail but are unrelated to this task.

### 8. Update `config-services/api-gateway/values-stg.yaml` (local reference)
Add:
```yaml
keycloak:
  issuerUri: https://web-dev1-keycloak.vucongtuanduong.dpdns.org/realms/ptit-wgs
```

### 9. Update `config-services/api-gateway/templates/deployment.yaml` (local reference)
Add env var:
```yaml
- name: KEYCLOAK_ISSUER_URI
  value: {{ .Values.keycloak.issuerUri | quote }}
```

## Manual Follow-ups (outside repo)
1. **Cloudflare Zero Trust Dashboard**: Add public hostname `web-dev1-keycloak.vucongtuanduong.dpdns.org` → Service `http://localhost:30195` (Traefik NodePort).
2. **Remote config repo**: Commit + push the `config-services/api-gateway` changes to `web-grading-system-services-config` so ArgoCD syncs the api-gateway with the new `KEYCLOAK_ISSUER_URI`.
3. **Keycloak admin**: After first boot, create the `ptit-wgs` realm and configure clients/roles. Default admin is `admin`/`admin` on port `8080`.

## Validation
```bash
# After setup.sh or setup_without_cloudflared.sh:
kubectl get pods -n web-grading -l app=keycloak
kubectl logs -n web-grading -l app=keycloak
curl -k https://web-dev1-keycloak.vucongtuanduong.dpdns.org/health/ready
```
