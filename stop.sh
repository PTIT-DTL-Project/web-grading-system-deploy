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

echo -e "${YELLOW}➜ Cloudflare Zero Trust tunnel:${NC}"
# Tunnel no longer runs via deploy/cloudflared docker-compose (removed with the
# Zero Trust migration). It runs as a foreground process when started manually.
echo "  If running (cloudflare_tunnel_run.sh), stop it with: pkill -f 'cloudflared tunnel run'"

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
