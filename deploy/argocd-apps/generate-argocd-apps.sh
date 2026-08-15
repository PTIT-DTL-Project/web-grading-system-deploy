#!/bin/bash

# Script to generate ArgoCD Application manifests for all services
# Usage: ./generate-argocd-apps.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/argocd-app-template.yaml"
SERVICES_FILE="$SCRIPT_DIR/services.env"
OUTPUT_DIR="$SCRIPT_DIR/generated"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Generating ArgoCD Application manifests${NC}\n"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Read services from services.env (skip comments and empty lines)
while IFS= read -r service || [ -n "$service" ]; do
    # Skip comments and empty lines
    [[ "$service" =~ ^#.*$ ]] && continue
    [[ -z "$service" ]] && continue
    
    echo -e "${YELLOW}📝 Generating Application for: ${service}${NC}"
    
    # Generate manifest from template
    OUTPUT_FILE="$OUTPUT_DIR/${service}.yaml"
    
    # Replace variables in template
    sed "s/\${SERVICE_NAME}/${service}/g" "$TEMPLATE_FILE" > "$OUTPUT_FILE"
    
    echo -e "${GREEN}✅ Created: ${OUTPUT_FILE}${NC}\n"
done < "$SERVICES_FILE"

echo -e "${GREEN}🎉 All ArgoCD Applications generated successfully!${NC}"
echo -e "${YELLOW}📁 Output directory: ${OUTPUT_DIR}${NC}\n"

echo -e "${YELLOW}To apply to cluster:${NC}"
echo -e "  kubectl apply -f ${OUTPUT_DIR}/"
