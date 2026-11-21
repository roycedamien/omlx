#!/usr/bin/env bash
#
# update_and_rebuild.sh — single script to update oMLX from upstream and rebuild
# for Apple Silicon (M4) with native custom kernels.
#
# Subcommands:
#   update        (default) git fetch + rebase (auto-stashing uncommitted changes),
#                 make dev (editable install + dev tools + custom kernels),
#                 make web, make app (auto-rebuilding stale donor layers),
#                 create custom config/models/cache dirs.
#   cleanup|uninstall  remove settings, cache, logs, usage DB, build artifacts,
#                 and custom kernels — but NEVER the Model dir.
#
# Flags:
#   --rebuild-donor     force venvstacks donor rebuild when building the macOS .app
#   --no-rebuild-donor  reuse existing donor layers even if stale
#
# Environment:
#   TOOLCHAINS=Metal        required for Metal kernel builds on Apple Silicon
#   PYTHON_BIN              python used for venvstacks driver (default: .venv/bin/python)
#   OMLX_BASE_PATH          base path override (default: ~/.omlx)
#   OMLX_MODEL_DIR          models dir override
#   OMLX_SSD_CACHE_DIR      SSD cache dir override
#   OMLX_LOG_DIR            log dir override

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENVPY="${PYTHON_BIN:-$REPO_ROOT/.venv/bin/python}"
export TOOLCHAINS="${TOOLCHAINS:-Metal}"

# --- Default paths (match omlx/settings.py) ---
DEFAULT_BASE_PATH="$HOME/.omlx"
DEFAULT_MODELS_DIR="$DEFAULT_BASE_PATH/models"
DEFAULT_CACHE_DIR="$DEFAULT_BASE_PATH/cache"
DEFAULT_LOG_DIR="$DEFAULT_BASE_PATH/logs"

# Expand leading ~ and canonicalize existing directories
expand_path() {
    local p="$1"
    case "$p" in
        "~")
            p="$HOME"
            ;;
        "~/"*)
            p="$HOME/${p#??}"
            ;;
    esac
    if [ -d "$p" ]; then
        (cd "$p" && pwd)
    else
        printf '%s\n' "$p"
    fi
}

resolve_base_path() {
    if [ -n "$BASE_PATH" ]; then
        echo "$BASE_PATH"
    elif [ -n "${OMLX_BASE_PATH:-}" ]; then
        echo "$OMLX_BASE_PATH"
    else
        echo "$DEFAULT_BASE_PATH"
    fi
}

log()   { printf "\033[1;34m[update_and_rebuild]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[update_and_rebuild]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[update_and_rebuild]\033[0m %s\n" "$*"; }
die()   { printf "\033[1;31m[update_and_rebuild ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

# --- Prerequisite checks ---
require_xcode_metal() {
    if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
        warn "xcrun metal check failed; refreshing xcrun lookup cache and retrying…"
        xcrun --kill-cache -sdk macosx metal --version >/dev/null 2>&1 \
            || die "Metal toolchain not found or not usable. Install full Xcode and run: xcodebuild -downloadComponent MetalToolchain"
    fi
}

require_venv() {
    local py_ver=""
    if [ -x "$VENVPY" ]; then
        py_ver="$("$VENVPY" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
    fi
    if [ "$py_ver" != "3.11" ]; then
        warn "Virtual environment missing or not Python 3.11 (got '${py_ver:-none}'); creating Python 3.11 .venv…"
        rm -rf "$REPO_ROOT/.venv"
        if [ -x "/opt/homebrew/opt/python@3.11/bin/python3.11" ]; then
            /opt/homebrew/opt/python@3.11/bin/python3.11 -m venv "$REPO_ROOT/.venv"
        elif command -v python3.11 >/dev/null 2>&1; then
            "$(command -v python3.11)" -m venv "$REPO_ROOT/.venv"
        elif command -v uv >/dev/null 2>&1; then
            uv venv --python 3.11 "$REPO_ROOT/.venv"
        else
            die "Python 3.11 not found. Install python@3.11 (e.g. brew install python@3.11) first."
        fi
        VENVPY="$REPO_ROOT/.venv/bin/python"
        "$VENVPY" -m pip install --upgrade pip setuptools wheel
    fi
    export VIRTUAL_ENV="$REPO_ROOT/.venv"
    export PATH="$REPO_ROOT/.venv/bin:$PATH"
    export PYTHON_BIN="$VENVPY"
}

# ============================================================
# Subcommand: update
# ============================================================
cmd_update() {
    log "Base path:        $BASE_PATH"
    log "Models dir:       $MODELS_DIR"
    log "Cache dir:        $CACHE_DIR"
    log "Log dir:          $LOG_DIR"

    # 1. Git update from upstream
    cd "$REPO_ROOT"
    local UPSTREAM_REMOTE=""
    if git remote get-url upstream >/dev/null 2>&1; then
        UPSTREAM_REMOTE="upstream"
    elif git remote get-url origin >/dev/null 2>&1; then
        UPSTREAM_REMOTE="origin"
    else
        die "Neither 'upstream' nor 'origin' git remote is configured."
    fi

    local git_dir
    git_dir="$(git rev-parse --git-dir)"
    if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
        die "A git rebase is already in progress. Finish or abort it first ('git rebase --continue' or 'git rebase --abort')."
    fi

    log "Fetching latest changes from ${UPSTREAM_REMOTE}…"
    git fetch "$UPSTREAM_REMOTE"

    local target_ref="${UPSTREAM_REMOTE}/main"
    if ! git rev-parse --verify --quiet "$target_ref" >/dev/null; then
        die "Remote branch '${target_ref}' not found after fetch."
    fi

    local behind
    behind="$(git rev-list --count "HEAD..${target_ref}")"
    if [ "$behind" -eq 0 ]; then
        ok "Already up to date with ${target_ref}."
    else
        if ! git diff --quiet || ! git diff --cached --quiet; then
            warn "Uncommitted changes detected — auto-stashing during rebase…"
        fi
        log "Rebasing onto ${target_ref}…"
        if ! git rebase --autostash "$target_ref"; then
            die "Rebase failed (likely due to conflicts). Git has preserved your autostash; resolve conflicts and run 'git rebase --continue', or run 'git rebase --abort' to restore your state."
        fi
        ok "Repository rebased onto ${target_ref}."
    fi

    # 2. Editable dev install + native custom kernels (includes everything in make install)
    require_xcode_metal
    require_venv
    log "Python:           $VENVPY"
    log "Installing editable dev environment and rebuilding native custom kernels (make dev, TOOLCHAINS=Metal)…"
    TOOLCHAINS=Metal make dev PYTHON="$VENVPY"
    ok "Editable dev install and custom kernels complete."

    # 3. Rebuild web UI CSS and normalize i18n files
    log "Rebuilding web UI assets (make web)…"
    make web PYTHON="$VENVPY"
    ok "Web UI assets rebuilt."

    # 4. Build macOS .app bundle with custom kernels
    case "$REBUILD_DONOR" in
        auto)
            log "Building macOS app (make app, auto-rebuilding stale donor if needed)…"
            TOOLCHAINS=Metal make app PYTHON="$VENVPY"
            ;;
        force)
            log "Building macOS app (release, with custom kernel, --rebuild-donor)…"
            TOOLCHAINS=Metal PYTHON_BIN="$VENVPY" \
                apps/omlx-mac/Scripts/build.sh release --with-custom-kernel --rebuild-donor
            ;;
        never)
            if [ ! -d "$REPO_ROOT/packaging/_export" ] && [ ! -d "${OMLX_DONOR_APP:-/Applications/oMLX.app}" ]; then
                warn "No existing donor layers found at packaging/_export or ${OMLX_DONOR_APP:-/Applications/oMLX.app}; running make app to auto-build donor."
                TOOLCHAINS=Metal make app PYTHON="$VENVPY"
            else
                log "Building macOS app (release, with custom kernel, --no-rebuild-donor)…"
                TOOLCHAINS=Metal PYTHON_BIN="$VENVPY" \
                    apps/omlx-mac/Scripts/build.sh release --with-custom-kernel --no-rebuild-donor
            fi
            ;;
        *)
            die "Invalid REBUILD_DONOR mode: $REBUILD_DONOR"
            ;;
    esac
    ok "macOS app staged at apps/omlx-mac/build/Stage/oMLX.app"

    # 5. Create custom directories
    log "Ensuring directories exist…"
    mkdir -p "$BASE_PATH"
    mkdir -p "$MODELS_DIR"
    mkdir -p "$CACHE_DIR"
    mkdir -p "$LOG_DIR"
    ok "Directories ready."

    # 6. Print config path summary
    echo ""
    echo "============================================================"
    echo "  oMLX config path summary"
    echo "============================================================"
    echo "  Base path:   $BASE_PATH"
    echo "  Settings:    $BASE_PATH/settings.json"
    echo "  Models dir:  $MODELS_DIR   <-- preserved by cleanup"
    echo "  Cache dir:   $CACHE_DIR"
    echo "  Log dir:     $LOG_DIR"
    echo "  Usage DB:    $BASE_PATH/usage.sqlite3"
    echo ""
    echo "  Env overrides:"
    echo "    OMLX_BASE_PATH=$BASE_PATH"
    echo "    OMLX_MODEL_DIR=$MODELS_DIR"
    echo "    OMLX_SSD_CACHE_DIR=$CACHE_DIR"
    echo "    OMLX_LOG_DIR=$LOG_DIR"
    echo ""
    echo "  To run the server with these custom paths:"
    echo "    OMLX_BASE_PATH=$BASE_PATH omlx serve --model-dir $MODELS_DIR"
    echo "============================================================"
    ok "Update + rebuild complete."
}

# ============================================================
# Subcommand: cleanup / uninstall
# ============================================================
cmd_cleanup() {
    log "Cleanup mode — removing oMLX artifacts (Model dir is PRESERVED)."
    log "Base path:   $BASE_PATH"
    log "Models dir:  $MODELS_DIR  (will NOT be touched)"
    echo ""

    # Safety: confirm the models dir is distinct from paths we're about to delete
    if [ "$MODELS_DIR" = "$BASE_PATH" ] || [ "$MODELS_DIR" = "$CACHE_DIR" ] || [ "$MODELS_DIR" = "$LOG_DIR" ]; then
        die "Refusing to cleanup: models dir overlaps with base/cache/log dir. Aborting to protect your models."
    fi

    cd "$REPO_ROOT"

    # Remove settings.json (but not the whole base path, since models may live under it)
    if [ -f "$BASE_PATH/settings.json" ]; then
        log "Removing settings.json"
        rm -f "$BASE_PATH/settings.json"
    fi

    # Remove usage history DB
    if [ -f "$BASE_PATH/usage.sqlite3" ]; then
        log "Removing usage.sqlite3"
        rm -f "$BASE_PATH/usage.sqlite3"
    fi

    # Remove cache dir (NOT models)
    if [ -d "$CACHE_DIR" ]; then
        log "Removing cache dir: $CACHE_DIR"
        rm -rf "$CACHE_DIR"
    fi

    # Remove log dir (NOT models)
    if [ -d "$LOG_DIR" ]; then
        log "Removing log dir: $LOG_DIR"
        rm -rf "$LOG_DIR"
    fi

    # Remove build artifacts
    if [ -d "$REPO_ROOT/build" ]; then
        log "Removing build/ directory"
        rm -rf "$REPO_ROOT/build"
    fi

    # Remove macOS app stage output
    APP_STAGE="$REPO_ROOT/apps/omlx-mac/build/Stage"
    if [ -d "$APP_STAGE" ]; then
        log "Removing app stage: $APP_STAGE"
        rm -rf "$APP_STAGE"
    fi

    # Remove compiled custom kernels (.so / .dylib / .metallib)
    log "Removing compiled custom kernels…"
    find "$REPO_ROOT/omlx/custom_kernels" -type f \( -name "*.so" -o -name "*.dylib" -o -name "*.metallib" \) -delete 2>/dev/null || true
    ok "Custom kernel binaries removed."

    # Remove editable install metadata
    if [ -d "$REPO_ROOT/omlx.egg-info" ]; then
        log "Removing omlx.egg-info/"
        rm -rf "$REPO_ROOT/omlx.egg-info"
    fi

    # Remove __pycache__ directories (safe to regenerate)
    log "Removing __pycache__ directories…"
    find "$REPO_ROOT" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true

    echo ""
    echo "============================================================"
    echo "  Cleanup complete"
    echo "============================================================"
    echo "  Preserved:  $MODELS_DIR  (your models are untouched)"
    echo "  Removed:    settings.json, usage.sqlite3, cache, logs,"
    echo "              build/, app Stage/, custom kernel binaries,"
    echo "              omlx.egg-info/, __pycache__/"
    echo ""
    echo "  To fully reinstall later, run: $0 update"
    echo "============================================================"
    ok "Cleanup done."
}

# ============================================================
# Main
# ============================================================
main() {
    BASE_PATH=""
    MODELS_DIR=""
    CACHE_DIR=""
    LOG_DIR=""
    SUBCOMMAND="update"
    REBUILD_DONOR="auto"

    while [ $# -gt 0 ]; do
        case "$1" in
            update|cleanup|uninstall)
                SUBCOMMAND="$1"
                shift
                ;;
            --base-path)
                [ $# -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
                BASE_PATH="$2"; shift 2 ;;
            --models-dir)
                [ $# -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
                MODELS_DIR="$2"; shift 2 ;;
            --cache-dir)
                [ $# -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
                CACHE_DIR="$2"; shift 2 ;;
            --log-dir)
                [ $# -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
                LOG_DIR="$2"; shift 2 ;;
            --rebuild-donor)
                REBUILD_DONOR="force"
                shift
                ;;
            --no-rebuild-donor)
                REBUILD_DONOR="never"
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [update|cleanup|uninstall] [--base-path PATH] [--models-dir PATH] [--cache-dir PATH] [--log-dir PATH] [--rebuild-donor|--no-rebuild-donor]"
                echo ""
                echo "Subcommands:"
                echo "  update             (default) git fetch + rebase (auto-stashing uncommitted changes),"
                echo "                     make dev (editable install + dev tools + custom kernels),"
                echo "                     make web, make app (auto-rebuilding stale donor layers), create dirs"
                echo "  cleanup|uninstall  remove settings/cache/logs/build artifacts (preserves Model dir)"
                echo ""
                echo "Flags:"
                echo "  --rebuild-donor     force venvstacks donor rebuild when building the macOS .app"
                echo "  --no-rebuild-donor  reuse existing donor layers even if stale"
                echo ""
                echo "Default paths:"
                echo "  Base path:   $DEFAULT_BASE_PATH"
                echo "  Models dir:  $DEFAULT_MODELS_DIR  (PRESERVED by cleanup)"
                echo "  Cache dir:   $DEFAULT_CACHE_DIR"
                echo "  Log dir:     $DEFAULT_LOG_DIR"
                echo ""
                echo "Env overrides: TOOLCHAINS=Metal, PYTHON_BIN, OMLX_BASE_PATH, OMLX_MODEL_DIR,"
                echo "               OMLX_SSD_CACHE_DIR, OMLX_LOG_DIR"
                exit 0
                ;;
            *)
                echo "error: unknown argument '$1'" >&2
                exit 2
                ;;
        esac
    done

    # Resolve paths (CLI flag > env var > default)
    BASE_PATH="$(resolve_base_path)"
    MODELS_DIR="${MODELS_DIR:-${OMLX_MODEL_DIR:-$DEFAULT_MODELS_DIR}}"
    CACHE_DIR="${CACHE_DIR:-${OMLX_SSD_CACHE_DIR:-$DEFAULT_CACHE_DIR}}"
    LOG_DIR="${LOG_DIR:-${OMLX_LOG_DIR:-$DEFAULT_LOG_DIR}}"

    # Expand ~ and make absolute when directories exist
    BASE_PATH="$(expand_path "$BASE_PATH")"
    MODELS_DIR="$(expand_path "$MODELS_DIR")"
    CACHE_DIR="$(expand_path "$CACHE_DIR")"
    LOG_DIR="$(expand_path "$LOG_DIR")"

    case "$SUBCOMMAND" in
        update)
            cmd_update
            ;;
        cleanup|uninstall)
            cmd_cleanup
            ;;
        *)
            die "Unknown subcommand: $SUBCOMMAND"
            ;;
    esac
}

main "$@"
