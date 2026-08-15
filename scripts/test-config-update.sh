#!/bin/bash

set -e

echo "=== Test Config Repo Update (simulating GitHub Actions workflow) ==="
echo ""

# Configuration
SERVICE="submission-service"
NEW_VERSION="v1.0.1"
CONFIG_DIR="config-services"

echo "📦 Service: $SERVICE"
echo "🏷️  New Version: $NEW_VERSION"
echo ""

# Navigate to config directory
cd "$CONFIG_DIR"

# Check if service config exists
if [ ! -d "$SERVICE" ]; then
    echo "❌ Service directory not found: $SERVICE"
    exit 1
fi

VALUES_FILE="$SERVICE/values-stg.yaml"

if [ ! -f "$VALUES_FILE" ]; then
    echo "❌ Values file not found: $VALUES_FILE"
    exit 1
fi

echo "📄 Found values file: $VALUES_FILE"
echo ""

# Show current tag
echo "📌 Current tag:"
grep "tag:" "$VALUES_FILE"
echo ""

# Update tag
echo "🔄 Updating to version: $NEW_VERSION"
sed -i "s|tag: .*|tag: \"$NEW_VERSION\"|" "$VALUES_FILE"

# Show updated tag
echo "✅ Updated tag:"
grep "tag:" "$VALUES_FILE"
echo ""

# Git operations
echo "📝 Git diff:"
git diff "$VALUES_FILE"
echo ""

# Commit and push
git add "$VALUES_FILE"
git commit -m "test: update $SERVICE image tag to $NEW_VERSION

This demonstrates the automatic config update that will be done by GitHub Actions.
Once secrets are configured, this will happen automatically on every build."

echo ""
echo "✅ Committed. Pushing to GitHub..."
git push origin main

echo ""
echo "✅ Successfully updated config repo!"
echo ""
echo "🔗 Verify at: https://github.com/Duong-Vu-practice-workspace/web-grading-system-config-test/commits/main"
echo ""
echo "=== Test completed ==="
