#!/usr/bin/env bash
# Update local branch from upstream (falling back to origin) with rebase --autostash.
# Wrapped in main() so bash reads the whole script before git rebase touches disk.

set -euo pipefail

main() {
    local script_dir repo_root remote target_branch target_ref git_dir behind

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "$script_dir/.." && pwd)"
    cd "$repo_root"

    target_branch="${1:-main}"

    if git remote get-url upstream >/dev/null 2>&1; then
        remote="upstream"
    elif git remote get-url origin >/dev/null 2>&1; then
        remote="origin"
    else
        echo "❌ Neither 'upstream' nor 'origin' git remote is configured." >&2
        exit 1
    fi

    git_dir="$(git rev-parse --git-dir)"
    if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
        echo "❌ A git rebase is already in progress. Finish or abort it first ('git rebase --continue' or 'git rebase --abort')." >&2
        exit 1
    fi

    echo "🔄 Fetching latest changes from ${remote}..."
    git fetch "$remote"

    target_ref="${remote}/${target_branch}"
    if ! git rev-parse --verify --quiet "$target_ref" >/dev/null; then
        echo "❌ Remote branch '${target_ref}' not found after fetch." >&2
        exit 1
    fi

    echo "📊 Checking for differences against ${target_ref}..."
    behind="$(git rev-list --count "HEAD..${target_ref}")"
    if [ "$behind" -eq 0 ]; then
        echo "✅ Already up to date with ${target_ref}"
        exit 0
    fi

    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "📦 Uncommitted changes detected — auto-stashing during rebase..."
    fi

    echo "🔄 Rebasing local changes onto ${target_ref}..."
    if ! git rebase --autostash "$target_ref"; then
        echo "" >&2
        echo "❌ Rebase failed (likely due to conflicts). Git has preserved your autostash." >&2
        echo "   Resolve conflicts and run 'git rebase --continue', or run 'git rebase --abort' to restore your state." >&2
        exit 1
    fi

    echo "✅ Successfully updated from ${target_ref}"
    echo ""
    git status
}

main "$@"
