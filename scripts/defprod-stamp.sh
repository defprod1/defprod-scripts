#!/usr/bin/env bash
#
# defprod-stamp.sh — stamp a DefProd change-pipeline stage from a CI/CD hook.
#
# Calls finishChangeStage (or startChangeStage with --start) for the change(s)
# correlated with the current git state. Designed to sit at the tail (or head)
# of build/package/deploy steps:
#
#   ./defprod-stamp.sh --stage build                 # finish 'build' for the current change
#   ./defprod-stamp.sh --stage build --start          # mark 'build' in progress (pipeline head)
#   ./defprod-stamp.sh --stage ship --range "$BEFORE..$AFTER"   # batched deploy: stamp every change in the range
#
# Correlation (in order):
#   1. --key CHG-NN                        explicit
#   2. branch name matching chg/CHG-NN-*   (current branch, or --branch)
#   3. 'Change: CHG-NN' commit trailers    on HEAD, or across --range
#
# Usage:
#   ./defprod-stamp.sh --stage <stage> [options]
#
#   --stage             Pipeline stage: merge|push|build|package|staging|ship (required)
#   --start             Call startChangeStage instead of finishChangeStage
#   --key               Explicit change key (e.g. CHG-07) — skips git correlation
#   --branch            Branch name to parse instead of the current branch
#   --range             Git rev range (e.g. abc123..def456) — stamps EVERY distinct
#                       change key found in the range's commit trailers
#   --note              Optional note for the change's event trail
#   --product-id        Product ID (or DEFPROD_PRODUCT_ID env var)
#   --api-url           API base URL, e.g. https://app.defprod.com/api/v1/rpc (or DEFPROD_API_URL)
#   --api-key           API key with read-write product scope (or DEFPROD_API_KEY)
#   --env-file          Path to env file (default: .defprod.env or DEFPROD_ENV_FILE)
#   --init              Interactively write the env file and exit
#
# Exit code: ALWAYS 0 unless invoked with bad arguments. A missed stamp is a
# visibility bug, not a deploy blocker — failures are logged to stderr and the
# pipeline continues.

set -u

# ---------------------------------------------------------------------------
# Env file loading (exported env vars take precedence) — house convention
# ---------------------------------------------------------------------------
load_env_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        local key="${line%%=*}"
        local val="${line#*=}"
        if [[ -z "${!key:-}" ]]; then
            export "$key=$val"
        fi
    done < "$file"
}

init_env_file() {
    read -rp "Config file location [.defprod.env]: " input_env_file
    local env_file="${input_env_file:-.defprod.env}"
    if [[ -f "$env_file" ]]; then
        read -rp "$env_file already exists. Overwrite? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    fi
    read -rp "API URL [https://app.defprod.com/api/v1/rpc]: " input_api_url
    input_api_url="${input_api_url:-https://app.defprod.com/api/v1/rpc}"
    read -rp "Product ID: " input_product_id
    read -rp "API key: " input_api_key
    cat > "$env_file" <<EOF
DEFPROD_API_URL=$input_api_url
DEFPROD_PRODUCT_ID=$input_product_id
DEFPROD_API_KEY=$input_api_key
EOF
    echo "Wrote $env_file"
    exit 0
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
STAGE=""
ACTION="finishChangeStage"
EXPLICIT_KEY=""
BRANCH=""
RANGE=""
NOTE=""
ENV_FILE="${DEFPROD_ENV_FILE:-.defprod.env}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) STAGE="$2"; shift 2 ;;
        --start) ACTION="startChangeStage"; shift ;;
        --key) EXPLICIT_KEY="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --range) RANGE="$2"; shift 2 ;;
        --note) NOTE="$2"; shift 2 ;;
        --product-id) export DEFPROD_PRODUCT_ID="$2"; shift 2 ;;
        --api-url) export DEFPROD_API_URL="$2"; shift 2 ;;
        --api-key) export DEFPROD_API_KEY="$2"; shift 2 ;;
        --env-file) ENV_FILE="$2"; shift 2 ;;
        --init) init_env_file ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$STAGE" ]]; then
    echo "defprod-stamp: --stage is required (merge|push|build|package|staging|ship)" >&2
    exit 2
fi

load_env_file "$ENV_FILE"
API_URL="${DEFPROD_API_URL:-}"
API_KEY="${DEFPROD_API_KEY:-}"
PRODUCT_ID="${DEFPROD_PRODUCT_ID:-}"

if [[ -z "$API_URL" || -z "$API_KEY" || -z "$PRODUCT_ID" ]]; then
    echo "defprod-stamp: missing DEFPROD_API_URL / DEFPROD_API_KEY / DEFPROD_PRODUCT_ID — skipping stamp" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Correlation: resolve the change key(s) for this stamp
# ---------------------------------------------------------------------------
resolve_keys() {
    if [[ -n "$EXPLICIT_KEY" ]]; then
        echo "$EXPLICIT_KEY"
        return
    fi
    if [[ -n "$RANGE" ]]; then
        # Batched deploys: every distinct change in the range gets stamped.
        git log --format=%B "$RANGE" 2>/dev/null \
            | grep -oE '^Change: CHG-[0-9]+' | awk '{print $2}' | sort -u
        return
    fi
    local branch="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
    if [[ "$branch" =~ ^chg/(CHG-[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    git log -1 --format=%B 2>/dev/null \
        | grep -oE '^Change: CHG-[0-9]+' | awk '{print $2}' | sort -u
}

KEYS=$(resolve_keys)
if [[ -z "$KEYS" ]]; then
    echo "defprod-stamp: no change key found (branch/trailers) — nothing to stamp" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Stamp each change (never fail the pipeline)
# ---------------------------------------------------------------------------
for KEY in $KEYS; do
    CHANGE_JSON=$(curl -sk -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $API_KEY" \
        -d "{\"name\":\"getChange\",\"input\":{\"productId\":\"$PRODUCT_ID\",\"key\":\"$KEY\"}}" 2>/dev/null)
    CHANGE_ID=$(echo "$CHANGE_JSON" | jq -r '.data._id // empty' 2>/dev/null)
    if [[ -z "$CHANGE_ID" ]]; then
        echo "defprod-stamp: change $KEY not found in product $PRODUCT_ID — skipping" >&2
        continue
    fi

    NOTE_FIELD=""
    if [[ -n "$NOTE" ]]; then
        NOTE_FIELD=",\"note\":$(jq -Rn --arg n "$NOTE" '$n')"
    fi
    RESPONSE=$(curl -sk -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $API_KEY" \
        -d "{\"name\":\"$ACTION\",\"input\":{\"changeId\":\"$CHANGE_ID\",\"stage\":\"$STAGE\"$NOTE_FIELD}}" 2>/dev/null)
    ERROR=$(echo "$RESPONSE" | jq -r '.meta.error // false' 2>/dev/null)
    if [[ "$ERROR" == "true" ]]; then
        DETAIL=$(echo "$RESPONSE" | jq -r '.error.detail // .error.title // "unknown"' 2>/dev/null)
        echo "defprod-stamp: $ACTION $STAGE rejected for $KEY: $DETAIL" >&2
    else
        echo "defprod-stamp: $ACTION $STAGE stamped for $KEY"
    fi
done

exit 0
