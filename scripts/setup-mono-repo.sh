#!/bin/bash

# Setup script for mono-repo migration
# This script helps initialize the two mono-repos from this deploy repo

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   Web Grading System - Mono-Repo Setup Script${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}\n"

# Function to print section header
print_section() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"
}

# Function to print step
print_step() {
    echo -e "${YELLOW}➜ $1${NC}"
}

# Function to print success
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Function to print error
print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Check prerequisites
print_section "Checking Prerequisites"

if ! command -v git &> /dev/null; then
    print_error "git is not installed"
    exit 1
fi
print_success "git is installed"

if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed"
    exit 1
fi
print_success "kubectl is installed"

# Ask user for confirmation
print_section "Configuration"

read -p "GitHub Organization/Username [PTIT-DTL-Project]: " GITHUB_ORG
GITHUB_ORG=${GITHUB_ORG:-PTIT-DTL-Project}

read -p "Source repo name [web-grading-system-services]: " SOURCE_REPO
SOURCE_REPO=${SOURCE_REPO:-web-grading-system-services}

read -p "Config repo name [web-grading-system-config]: " CONFIG_REPO
CONFIG_REPO=${CONFIG_REPO:-web-grading-system-config}

read -p "Parent directory for cloning repos [..]: " PARENT_DIR
PARENT_DIR=${PARENT_DIR:-..}

echo -e "\n${YELLOW}Configuration:${NC}"
echo "  GitHub Org: $GITHUB_ORG"
echo "  Source Repo: $SOURCE_REPO"
echo "  Config Repo: $CONFIG_REPO"
echo "  Parent Directory: $PARENT_DIR"

read -p $'\n'"Continue? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_error "Setup cancelled"
    exit 1
fi

# Create parent directory if not exists
mkdir -p "$PARENT_DIR"

# Setup Source Repo
print_section "Setting up Source Mono-Repo"

SOURCE_PATH="$PARENT_DIR/$SOURCE_REPO"

if [ -d "$SOURCE_PATH" ]; then
    print_error "Directory $SOURCE_PATH already exists"
    read -p "Remove and continue? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$SOURCE_PATH"
        print_success "Removed existing directory"
    else
        print_error "Setup cancelled"
        exit 1
    fi
fi

print_step "Creating source repo directory..."
mkdir -p "$SOURCE_PATH"
cd "$SOURCE_PATH"

print_step "Initializing git repository..."
git init
git branch -M main

print_step "Copying source code..."
cp -r "$SCRIPT_DIR/src-services/"* .
cp -r "$SCRIPT_DIR/src-services/.github" .

print_step "Creating initial commit..."
git add .
git commit -m "Initial commit: Mono-repo structure for all services

- Added 6 microservices (submission, executor, api-gateway, result, assignment)
- Added smart CI/CD workflow with change detection
- Configured Docker build and push
- Configured automatic config repo updates"

print_success "Source repo initialized at $SOURCE_PATH"

# Setup Config Repo
print_section "Setting up Config Mono-Repo"

CONFIG_PATH="$PARENT_DIR/$CONFIG_REPO"

if [ -d "$CONFIG_PATH" ]; then
    print_error "Directory $CONFIG_PATH already exists"
    read -p "Remove and continue? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$CONFIG_PATH"
        print_success "Removed existing directory"
    else
        print_error "Setup cancelled"
        exit 1
    fi
fi

print_step "Creating config repo directory..."
mkdir -p "$CONFIG_PATH"
cd "$CONFIG_PATH"

print_step "Initializing git repository..."
git init
git branch -M main

print_step "Copying Helm charts..."
cp -r "$SCRIPT_DIR/config-services/"* .

print_step "Creating initial commit..."
git add .
git commit -m "Initial commit: Helm charts mono-repo

- Added Helm charts for 6 services
- Each chart includes deployment, service, and helpers templates
- Configured values for staging environment
- Added script to generate new charts"

print_success "Config repo initialized at $CONFIG_PATH"

# Instructions
print_section "Next Steps"

echo -e "${YELLOW}1. Create GitHub repositories:${NC}"
echo "   - Go to https://github.com/organizations/$GITHUB_ORG/repositories/new"
echo "   - Create: $SOURCE_REPO"
echo "   - Create: $CONFIG_REPO"
echo ""

echo -e "${YELLOW}2. Push source repo:${NC}"
echo "   cd $SOURCE_PATH"
echo "   git remote add origin https://github.com/$GITHUB_ORG/$SOURCE_REPO.git"
echo "   git push -u origin main"
echo ""

echo -e "${YELLOW}3. Push config repo:${NC}"
echo "   cd $CONFIG_PATH"
echo "   git remote add origin https://github.com/$GITHUB_ORG/$CONFIG_REPO.git"
echo "   git push -u origin main"
echo ""

echo -e "${YELLOW}4. Configure GitHub Secrets for source repo:${NC}"
echo "   Repository: $GITHUB_ORG/$SOURCE_REPO"
echo "   Secrets needed:"
echo "   - DOCKERHUB_USERNAME: Your DockerHub username"
echo "   - DOCKERHUB_TOKEN: DockerHub access token"
echo "   - CONFIG_REPO_TOKEN: GitHub PAT with repo scope"
echo ""

echo -e "${YELLOW}5. Update ArgoCD Applications:${NC}"
echo "   cd $SCRIPT_DIR/deploy/argocd-apps"
echo "   ./generate-argocd-apps.sh"
echo "   kubectl apply -f generated/"
echo ""

echo -e "${YELLOW}6. Verify setup:${NC}"
echo "   - Make a test change in source repo"
echo "   - Push to trigger CI/CD"
echo "   - Check GitHub Actions workflow"
echo "   - Verify Docker image is built"
echo "   - Check config repo is updated"
echo "   - Verify ArgoCD syncs the change"
echo ""

print_section "Setup Complete!"

echo -e "${GREEN}Local repositories created:${NC}"
echo "  Source: $SOURCE_PATH"
echo "  Config: $CONFIG_PATH"
echo ""
echo -e "${GREEN}For detailed migration guide, see:${NC}"
echo "  $SCRIPT_DIR/MIGRATION_GUIDE.md"
echo ""

print_success "Setup script completed successfully!"
