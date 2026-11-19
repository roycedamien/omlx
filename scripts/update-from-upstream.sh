#!/bin/bash
# Update local main branch from upstream with rebase
# This is the primary workflow for keeping your local copy in sync

set -e

echo "🔄 Fetching latest changes from upstream..."
git fetch upstream

echo "📊 Checking for differences..."
if [ "$(git rev-list --count HEAD..upstream/main)" -eq 0 ]; then
    echo "✅ Already up to date with upstream/main"
    exit 0
fi

echo "🔄 Rebasing local changes onto upstream/main..."
git rebase upstream/main

echo "✅ Successfully updated from upstream/main"
echo ""
git status
