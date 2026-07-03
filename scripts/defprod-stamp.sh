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
#   1. --key CHG-NN (or <slug>/CHG-NN)     explicit
#   2. branch name matching chg/CHG-NN-*   (current branch, or --branch)
#   3. 'Change: <slug>/CHG-NN' trailers    on HEAD, or across --range
#
# The commit trailer is product-scoped by slug (a bare CHG-NN key is only unique
# WITHIN a product). Each resolved key carries its owning product slug; the slug
# is resolved to a productId via getProductBySlug, so one push range spanning
# several products in a monorepo stamps each against the correct product. A
# legacy bare 'Change: CHG-NN' trailer (or a branch/--key correlation, which
# carry no slug) falls back to the configured DEFPROD_PRODUCT_ID.
#
# Usage:
#   ./defprod-stamp.sh --stage <stage> [options]
#
#   --stage             Pipeline stage: merge|push|build|package|staging|ship
#                       (required for --start and finish; ignored by --cancel)
#   --start             Call startChangeStage (mark the stage in progress)
#   --cancel            Call cancelChangeStage — cancel the in-progress stage
#                       work, returning it to not started (ignores --stage)
#   --key               Explicit change key (e.g. CHG-07) — skips git correlation
#   --branch            Branch name to parse instead of the current branch
#   --range             Git rev range (e.g. abc123..def456) — stamps EVERY distinct
#                       change key found in the range's commit trailers
#   --note              Optional note for the change's event trail
#   --product-id        Fallback Product ID for slug-less correlations
#                       (or DEFPROD_PRODUCT_ID env var, or .defprod/defprod.json).
#                       Slug-prefixed trailers resolve their own productId.
#   --api-url           API base URL, e.g. https://app.defprod.com/api/v1/rpc (or DEFPROD_API_URL)
#   --api-key           API key with read-write product scope (or DEFPROD_API_KEY)
#   --env-file          Explicit env file to load (else .defprod/defprod.env, legacy .defprod.env)
#   --init              Interactively write the .defprod/ config and exit
#
# Config resolution (first writer wins): CLI flags > exported env vars >
# --env-file/DEFPROD_ENV_FILE > .defprod/defprod.env (git-ignored secrets) >
# .defprod/defprod.json (committed: productId, apiUrl) > legacy .defprod.env.
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

# Load committed, non-secret config (productId, apiUrl) from .defprod/defprod.json.
# Only fills vars that are still unset, so flags / exported env / the env file win.
# jq is already a hard dependency of this script.
load_json_config() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    _json_set() {
        local var="$1" path="$2" v
        [[ -n "${!var:-}" ]] && return 0
        v=$(jq -r "${path} // empty" "$file" 2>/dev/null) || return 0
        [[ -n "$v" ]] && export "$var=$v"
        return 0
    }
    _json_set DEFPROD_PRODUCT_ID '.productId'
    _json_set DEFPROD_API_URL '.apiUrl'
    return 0
}

init_env_file() {
    read -rp "Config directory [.defprod]: " input_dir
    local dir="${input_dir:-.defprod}"
    local json_file="$dir/defprod.json"
    local env_file="$dir/defprod.env"
    mkdir -p "$dir"
    if [[ -f "$env_file" ]]; then
        read -rp "$env_file already exists. Overwrite? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    fi
    read -rp "API URL [https://app.defprod.com/api/v1/rpc]: " input_api_url
    input_api_url="${input_api_url:-https://app.defprod.com/api/v1/rpc}"
    read -rp "Product ID: " input_product_id
    read -rp "API key: " input_api_key
    # Committed, non-secret identity. Merge into any existing defprod.json.
    if [[ -f "$json_file" ]] && command -v jq >/dev/null 2>&1; then
        local tmp
        tmp=$(jq --arg u "$input_api_url" --arg p "$input_product_id" \
            '.apiUrl=$u | .productId=$p' "$json_file") && printf '%s\n' "$tmp" > "$json_file"
    else
        cat > "$json_file" <<EOF
{
  "productId": "$input_product_id",
  "apiUrl": "$input_api_url"
}
EOF
    fi
    # Secret. Never commit this file.
    cat > "$env_file" <<EOF
DEFPROD_API_KEY=$input_api_key
EOF
    echo "Wrote $json_file (commit this) and $env_file (git-ignore this)."
    echo "Add to .gitignore: $env_file"
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
ENV_FILE_EXPLICIT="${DEFPROD_ENV_FILE:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) STAGE="$2"; shift 2 ;;
        --start) ACTION="startChangeStage"; shift ;;
        --cancel) ACTION="cancelChangeStage"; shift ;;
        --key) EXPLICIT_KEY="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --range) RANGE="$2"; shift 2 ;;
        --note) NOTE="$2"; shift 2 ;;
        --product-id) export DEFPROD_PRODUCT_ID="$2"; shift 2 ;;
        --api-url) export DEFPROD_API_URL="$2"; shift 2 ;;
        --api-key) export DEFPROD_API_KEY="$2"; shift 2 ;;
        --env-file) ENV_FILE_EXPLICIT="$2"; shift 2 ;;
        --init) init_env_file ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$STAGE" && "$ACTION" != "cancelChangeStage" ]]; then
    echo "defprod-stamp: --stage is required (merge|push|build|package|staging|ship)" >&2
    exit 2
fi

# Layered config (first writer wins; flags/exported vars already set above).
[[ -n "$ENV_FILE_EXPLICIT" ]] && load_env_file "$ENV_FILE_EXPLICIT"
load_env_file ".defprod/defprod.env"
load_json_config ".defprod/defprod.json"
load_env_file ".defprod.env"   # legacy root location (back-compat)
API_URL="${DEFPROD_API_URL:-}"
API_KEY="${DEFPROD_API_KEY:-}"
PRODUCT_ID="${DEFPROD_PRODUCT_ID:-}"

# API URL + key are always required. PRODUCT_ID is only the fallback for
# slug-less correlations (bare trailer / branch / --key); slug-prefixed trailers
# resolve their own productId, so a multi-product monorepo CI need not set it.
if [[ -z "$API_URL" || -z "$API_KEY" ]]; then
    echo "defprod-stamp: missing DEFPROD_API_URL / DEFPROD_API_KEY — skipping stamp" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Correlation: resolve the change key(s) for this stamp
# ---------------------------------------------------------------------------
# Emit one `slug|key` token per correlated change (slug empty when the carrier
# has none). Parses both the product-scoped `Change: <slug>/CHG-NN` trailer and
# the legacy bare `Change: CHG-NN`.
parse_trailers() {
    # stdin: commit message bodies. stdout: deduped `slug|key` tokens.
    grep -oE '^Change:[[:space:]]+([a-z0-9][a-z0-9-]*/)?CHG-[0-9]+' 2>/dev/null \
        | sed -E 's/^Change:[[:space:]]+//' \
        | awk -F/ '{ if (NF == 2) print $1 "|" $2; else print "|" $1 }' \
        | sort -u
}

resolve_keys() {
    if [[ -n "$EXPLICIT_KEY" ]]; then
        # Accept either a bare key or a <slug>/CHG-NN form.
        if [[ "$EXPLICIT_KEY" == */* ]]; then
            echo "${EXPLICIT_KEY%%/*}|${EXPLICIT_KEY##*/}"
        else
            echo "|$EXPLICIT_KEY"
        fi
        return
    fi
    if [[ -n "$RANGE" ]]; then
        # Batched deploys: every distinct change in the range gets stamped.
        git log --format=%B "$RANGE" 2>/dev/null | parse_trailers
        return
    fi
    local branch="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
    if [[ "$branch" =~ ^chg/(CHG-[0-9]+) ]]; then
        # Branch names carry no slug — fall back to the configured productId.
        echo "|${BASH_REMATCH[1]}"
        return
    fi
    git log -1 --format=%B 2>/dev/null | parse_trailers
}

KEYS=$(resolve_keys)
if [[ -z "$KEYS" ]]; then
    echo "defprod-stamp: no change key found (branch/trailers) — nothing to stamp" >&2
    exit 0
fi

# Resolve a product slug to its productId via getProductBySlug. Echoes the
# productId on success, nothing on failure.
resolve_product_id_from_slug() {
    local slug="$1"
    local json
    json=$(curl -sk -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $API_KEY" \
        -d "{\"name\":\"getProductBySlug\",\"input\":{\"slug\":\"$slug\"}}" 2>/dev/null)
    echo "$json" | jq -r '.data._id // empty' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Stamp each change (never fail the pipeline)
# ---------------------------------------------------------------------------
for TOKEN in $KEYS; do
    SLUG="${TOKEN%%|*}"
    KEY="${TOKEN#*|}"

    # Product resolution: a slug in the trailer names its own product; otherwise
    # fall back to the configured DEFPROD_PRODUCT_ID.
    PID="$PRODUCT_ID"
    if [[ -n "$SLUG" ]]; then
        RESOLVED=$(resolve_product_id_from_slug "$SLUG")
        if [[ -n "$RESOLVED" ]]; then
            PID="$RESOLVED"
        else
            echo "defprod-stamp: slug '$SLUG' (for $KEY) did not resolve to a product — falling back to configured productId" >&2
        fi
    fi
    if [[ -z "$PID" ]]; then
        echo "defprod-stamp: no productId for $KEY (no slug resolved and DEFPROD_PRODUCT_ID unset) — skipping" >&2
        continue
    fi

    CHANGE_JSON=$(curl -sk -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $API_KEY" \
        -d "{\"name\":\"getChange\",\"input\":{\"productId\":\"$PID\",\"key\":\"$KEY\"}}" 2>/dev/null)
    CHANGE_ID=$(echo "$CHANGE_JSON" | jq -r '.data._id // empty' 2>/dev/null)
    if [[ -z "$CHANGE_ID" ]]; then
        echo "defprod-stamp: change $KEY not found in product $PID — skipping" >&2
        continue
    fi

    NOTE_FIELD=""
    if [[ -n "$NOTE" ]]; then
        NOTE_FIELD=",\"note\":$(jq -Rn --arg n "$NOTE" '$n')"
    fi
    # cancelChangeStage cancels whatever stage is in progress — it takes no
    # `stage` (the server resolves it); start/finish carry the explicit stage.
    if [[ "$ACTION" == "cancelChangeStage" ]]; then
        INPUT="{\"changeId\":\"$CHANGE_ID\"$NOTE_FIELD}"
    else
        INPUT="{\"changeId\":\"$CHANGE_ID\",\"stage\":\"$STAGE\"$NOTE_FIELD}"
    fi
    RESPONSE=$(curl -sk -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $API_KEY" \
        -d "{\"name\":\"$ACTION\",\"input\":$INPUT}" 2>/dev/null)
    ERROR=$(echo "$RESPONSE" | jq -r '.meta.error // false' 2>/dev/null)
    if [[ "$ERROR" == "true" ]]; then
        DETAIL=$(echo "$RESPONSE" | jq -r '.error.detail // .error.title // "unknown"' 2>/dev/null)
        echo "defprod-stamp: $ACTION $STAGE rejected for $KEY: $DETAIL" >&2
    else
        echo "defprod-stamp: $ACTION $STAGE stamped for $KEY"
    fi
done

exit 0
