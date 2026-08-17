#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-vucongtuanduong.dpdns.org}"
TUNNEL_NAME="${2:-web-dev1-web-grading}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load .env để lấy GATEWAY_PORT nếu không truyền argument
if [ -f "${SCRIPT_DIR}/../../.env" ]; then
  set -o allexport
  source "${SCRIPT_DIR}/../../.env"
  set +o allexport
fi

GATEWAY_PORT="${3:-${GATEWAY_PORT:-31242}}"

echo "=== Creating cloudflared tunnel: ${TUNNEL_NAME} ==="
if cloudflared tunnel info "${TUNNEL_NAME}" &>/dev/null; then
  echo "Tunnel ${TUNNEL_NAME} already exists, skipping creation"
else
  cloudflared tunnel create "${TUNNEL_NAME}"
fi

TUNNEL_ID=$(cloudflared tunnel info "${TUNNEL_NAME}" 2>&1 | grep -oP 'tunnel \K[a-f0-9-]+')
echo "Tunnel ID: ${TUNNEL_ID}"

echo ""
echo "=== Generate config.yml from template ==="
sed -e "s|CREDENTIALS_FILE_PLACEHOLDER|${TUNNEL_ID}|g" \
    -e "s|GATEWAY_PORT|${GATEWAY_PORT}|g" \
    "${SCRIPT_DIR}/config.yml.tmpl" > ~/.cloudflared/config.yml
chmod 755 ~/.cloudflared
chmod 644 ~/.cloudflared/config.yml
chmod 644 ~/.cloudflared/${TUNNEL_ID}.json 2>/dev/null || true

echo ""
echo "=== Route DNS ==="
for sub in api assignment submission grading result notification argocd keycloak rustfs grafana otlp pyroscope; do
  cloudflared tunnel route dns "${TUNNEL_NAME}" "web-dev1-${sub}.${DOMAIN}" || true
done

echo ""
echo "If DNS routing fails, add CNAME records at your DNS provider:"
echo "  web-dev1-* CNAME -> ${TUNNEL_ID}.cfargotunnel.com"
