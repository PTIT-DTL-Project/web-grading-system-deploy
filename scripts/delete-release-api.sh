#!/bin/bash

# Script to delete GitHub Release via API
# Requires: curl, jq (optional)

REPO="Duong-Vu-practice-workspace/web-grading-system-services-test"
RELEASE_TAG="submission-service-v1.0.1"

echo "================================================"
echo "  Delete GitHub Release: $RELEASE_TAG"
echo "================================================"
echo ""

# Check if GitHub token is available
if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ ERROR: GITHUB_TOKEN not set!"
    echo ""
    echo "Please set your GitHub Personal Access Token:"
    echo ""
    echo "  export GITHUB_TOKEN='your_token_here'"
    echo ""
    echo "Create token at: https://github.com/settings/tokens"
    echo "Permissions needed: repo (Full control)"
    echo ""
    echo "OR manually delete at:"
    echo "  https://github.com/$REPO/releases"
    echo ""
    exit 1
fi

echo "🔍 Finding release ID for tag: $RELEASE_TAG"
echo ""

# Get release ID
RELEASE_ID=$(curl -s \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$REPO/releases/tags/$RELEASE_TAG" \
    | grep -o '"id": [0-9]*' | head -1 | grep -o '[0-9]*')

if [ -z "$RELEASE_ID" ]; then
    echo "⚠️  Release not found or already deleted!"
    echo ""
    echo "Checking all releases..."
    curl -s \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$REPO/releases" \
        | grep "tag_name"
    echo ""
    exit 0
fi

echo "✅ Found release ID: $RELEASE_ID"
echo ""
echo "🗑️  Deleting release..."

# Delete release
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X DELETE \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$REPO/releases/$RELEASE_ID")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

if [ "$HTTP_CODE" = "204" ]; then
    echo "✅ Release deleted successfully!"
    echo ""
    echo "📝 Note: The git tag has already been deleted."
    echo ""
    echo "🚀 Next step: Push code to trigger new workflow"
    echo "  cd src-services"
    echo "  git push origin main"
    echo ""
else
    echo "❌ Failed to delete release!"
    echo "HTTP Code: $HTTP_CODE"
    echo "Response: $RESPONSE"
    echo ""
    echo "Please delete manually at:"
    echo "  https://github.com/$REPO/releases"
    echo ""
fi
