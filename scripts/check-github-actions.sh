#!/bin/bash

set -e

echo "=== GitHub Actions Health Check ==="
echo ""

# Check 1: Repository configuration
echo "1. Checking repository configuration..."
cd src-services
REMOTE=$(git remote get-url origin)
echo "   Remote: $REMOTE"
echo "   Branch: $(git branch --show-current)"
echo ""

# Check 2: Workflow files exist
echo "2. Checking workflow files..."
if [ -f ".github/workflows/build-services.yml" ]; then
    echo "   ✓ build-services.yml exists"
else
    echo "   ✗ build-services.yml missing"
fi

if [ -f ".github/workflows/publish.yml" ]; then
    echo "   ✓ publish.yml exists"
else
    echo "   ✗ publish.yml missing"
fi
echo ""

# Check 3: Check recent commits
echo "3. Recent commits:"
git log --oneline -3
echo ""

# Check 4: Check tags
echo "4. Checking existing tags..."
TAGS=$(git tag -l | wc -l)
echo "   Total tags: $TAGS"
if [ $TAGS -eq 0 ]; then
    echo "   ⚠ No tags found - first run will create v1.0.0"
else
    echo "   Latest tags:"
    git tag -l | sort -V | tail -5
fi
echo ""

# Check 5: Check Docker Hub connectivity
echo "5. Checking Docker Hub..."
if command -v docker &> /dev/null; then
    echo "   ✓ Docker installed"
    DOCKERHUB_USER="vucongtuanduong"
    echo "   Testing DockerHub access for user: $DOCKERHUB_USER"
    # Try to pull a public image to test connectivity
    if docker pull alpine:latest &> /dev/null; then
        echo "   ✓ Docker Hub accessible"
    else
        echo "   ⚠ Cannot reach Docker Hub"
    fi
else
    echo "   ⚠ Docker not installed"
fi
echo ""

# Check 6: Config repo
echo "6. Checking config repository..."
CONFIG_REPO="Duong-Vu-practice-workspace/web-grading-system-deploy-test"
echo "   Config repo: $CONFIG_REPO"
cd ..
if [ -d "config-services/submission-service" ]; then
    echo "   ✓ Config structure exists"
    if [ -f "config-services/submission-service/values-stg.yaml" ]; then
        echo "   ✓ values-stg.yaml exists"
        CURRENT_TAG=$(grep "tag:" config-services/submission-service/values-stg.yaml | awk '{print $2}' | tr -d '"')
        echo "   Current tag in config: $CURRENT_TAG"
    fi
fi
echo ""

echo "=== Recommendations ==="
echo ""
echo "To trigger a build, you need to:"
echo "1. Make a change to a service (e.g., submission-service)"
echo "2. Commit and push to main branch"
echo "3. Check workflow logs at:"
echo "   https://github.com/Duong-Vu-practice-workspace/web-grading-system-services-test/actions"
echo ""
echo "Required GitHub Secrets (set in repo settings):"
echo "  - DOCKERHUB_USERNAME"
echo "  - DOCKERHUB_TOKEN"
echo "  - CONFIG_REPO_TOKEN (with repo write permissions)"
echo ""
