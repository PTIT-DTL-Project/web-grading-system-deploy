#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  Web Grading System - Stop${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

echo -e "${YELLOW}➜ Stopping Cloudflare Tunnel...${NC}"
docker compose -f "$SCRIPT_DIR/deploy/cloudflared/docker-compose.yml" down 2>/dev/null || true
echo -e "${GREEN}✓ Cloudflare Tunnel stopped${NC}"

echo ""
echo -e "${YELLOW}➜ Stopping k3s...${NC}"
sudo systemctl stop k3s
echo -e "${GREEN}✓ k3s stopped${NC}"

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  System Stopped${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "${YELLOW}💡 To start again:${NC}"
echo "  bash start.sh"
echo ""
