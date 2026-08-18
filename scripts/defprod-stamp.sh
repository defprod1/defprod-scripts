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
#   2. branch matching chg/<slug>/CHG-NN-* (or legacy chg/CHG-NN-*) (current, or --branch)
#   3. 'Change: <slug>/CHG-NN' trailers    on HEAD, or across --range
#      'Change: <slug>/CHG-NN:<stage>'    optional stage ceiling on any trailer
#
# The commit trailer is product-scoped by slug (a bare CHG-NN key is only unique
# WITHIN a product). Each resolved key carries its owning product slug; the slug
# is resolved to a productId via getProductBySlug, so one push range spanning
# several products in a monorepo stamps each against the correct product. A
# legacy bare 'Change: CHG-NN' trailer (or a branch/--key correlation, which
# carry no slug) falls back to the configured DEFPROD_PRODUCT_ID.
#
# --- usage:begin ---
# Usage:
#   ./defprod-stamp.sh --stage <stage> [options]
#
#   --stage             Pipeline stage: merge|push|build|package|staging|ship
#                       (required for --start and finish; ignored by --cancel/--fail)
#
#   Trailer stage ceiling: a commit may declare the furthest stage it delivers as
#   'Change: <slug>/CHG-NN:<stage>'. A stamp beyond every declared ceiling is sent
#   as a no-op rather than advancing the change. Tooling that WRITES the suffix must
#   confirm this support marker is present first, because an older copy of this
#   script silently truncates the suffix and treats the commit as delivering the
#   change in full. Support marker: supports-trailer-stage-ceiling
#   --start             Call startChangeStage (mark the stage in progress)
#   --cancel            Call cancelChangeStage — cancel the in-progress stage
#                       work, returning it to not started (ignores --stage)
#   --fail              Call failChangeStage — report the in-progress stage as
#                       FAILED (ignores --stage). Use when the stage was attempted
#                       and did not succeed, e.g. from a CI EXIT trap: the stage is
#                       recorded as failed rather than reverted to not started, so
#                       an aborted run is not mistaken for one that never began.
#                       Pair it with --note carrying the reason (stage, exit code).
#   --key               Explicit change key (e.g. CHG-07) — skips git correlation
#   --branch            Branch name to parse instead of the current branch
#   --range             Git rev range (e.g. abc123..def456) — stamps EVERY distinct
#                       change key found in the range's commit trailers
#   --list-changes      Correlation-only mode: print the change(s) the correlation
#                       resolves, one JSON object per line on stdout, and stamp
#                       NOTHING. Use it when something downstream must act on the
#                       set of changes a git range carries — recording a deployment
#                       run, generating release notes or a changelog — rather than
#                       reimplementing trailer parsing, slug→productId resolution
#                       and the change lookup in a second script that will drift.
#                       Each line: {"key","slug","productId","changeId"}; slug is
#                       null for a slug-less correlation. stdout carries data only,
#                       every diagnostic goes to stderr, so a caller can read the
#                       list without filtering. Cannot be combined with
#                       --stage/--start/--cancel/--fail/--note. Needs only read
#                       access — it calls no mutating use case.
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
# Exit codes:
#   0  Success. For --list-changes, the correlation COMPLETED — the list may
#      still be legitimately empty (the range carried no tracked change).
#   2  Bad arguments.
#   3  --list-changes only: the correlation could NOT be completed (unreadable
#      rev range, missing API config, or a key that did not resolve to a change).
#      stdout is an incomplete answer and must not be treated as the answer.
#
# Stamping NEVER returns 3: a missed stamp is a visibility bug, not a deploy
# blocker, so every stamp path logs to stderr and exits 0. Listing is held to a
# stricter contract because its output IS the result — a caller that recorded an
# empty list as fact would assert the deploy carried nothing, which is worse than
# a missing stamp.
# --- usage:end ---

set -u

# ---------------------------------------------------------------------------
# Help — prints the usage block above, verbatim, from this file's own header.
#
# Also the capability-probe surface: a CI caller that wants to use a flag this
# script may be too old to know (`--fail`, say) can grep `--help` for it rather
# than discovering the gap as an "Unknown argument" exit 2 mid-pipeline. Keep
# every supported flag named in the header block for that to keep working.
#
# The block is delimited by sentinel comments rather than an absolute line range.
# It used to be `sed -n '25,58p'`, whose bounds sat exactly on the first and last
# lines with no slack: documenting a new flag pushed the tail off the end (or,
# for a line added above, started the help mid-sentence) and silently truncated
# --help. That is precisely the surface a CI caller probes for flag support, so
# the failure mode was a caller not finding a flag we do ship and downgrading.
# ---------------------------------------------------------------------------
print_usage() {
    sed -n '/^# --- usage:begin ---$/,/^# --- usage:end ---$/p' "$0" \
        | sed -e '1d;$d' -e 's/^# \{0,1\}//' -e 's/^#$//'
}

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
LIST_CHANGES=0
ENV_FILE_EXPLICIT="${DEFPROD_ENV_FILE:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) STAGE="$2"; shift 2 ;;
        --start) ACTION="startChangeStage"; shift ;;
        --cancel) ACTION="cancelChangeStage"; shift ;;
        --fail) ACTION="failChangeStage"; shift ;;
        --key) EXPLICIT_KEY="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --range) RANGE="$2"; shift 2 ;;
        --list-changes) LIST_CHANGES=1; shift ;;
        --note) NOTE="$2"; shift 2 ;;
        --product-id) export DEFPROD_PRODUCT_ID="$2"; shift 2 ;;
        --api-url) export DEFPROD_API_URL="$2"; shift 2 ;;
        --api-key) export DEFPROD_API_KEY="$2"; shift 2 ;;
        --env-file) ENV_FILE_EXPLICIT="$2"; shift 2 ;;
        --init) init_env_file ;;
        -h|--help) print_usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; echo >&2; print_usage >&2; exit 2 ;;
    esac
done

# --list-changes stamps nothing, so every stamping argument is meaningless with
# it. Reject the combination rather than silently ignoring it: a caller that
# believed it was stamping would otherwise get a listing and no stamp, and find
# out only when the change record turned out to have no stage times.
if [[ "$LIST_CHANGES" -eq 1 ]]; then
    if [[ "$ACTION" != "finishChangeStage" || -n "$STAGE" || -n "$NOTE" ]]; then
        echo "defprod-stamp: --list-changes cannot be combined with --stage/--start/--cancel/--fail/--note" >&2
        exit 2
    fi
fi

# cancel and fail both act on whatever stage is in progress — the server resolves
# it — so neither needs (or uses) --stage. --list-changes performs the same
# correlation but takes no action, so it needs no stage either.
if [[ -z "$STAGE" && "$ACTION" != "cancelChangeStage" && "$ACTION" != "failChangeStage" \
      && "$LIST_CHANGES" -eq 0 ]]; then
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
# slug-less correlations (bare trailer / legacy branch / --key); slug-prefixed
# trailers and slug-prefixed (`chg/<slug>/CHG-NN`) branches resolve their own
# productId, so a multi-product monorepo CI need not set it.
if [[ -z "$API_URL" || -z "$API_KEY" ]]; then
    if [[ "$LIST_CHANGES" -eq 1 ]]; then
        # Not "no changes" — no answer. Emitting an empty list here would let a
        # caller record a misconfigured run as one that carried nothing.
        echo "defprod-stamp: missing DEFPROD_API_URL / DEFPROD_API_KEY — cannot list changes" >&2
        exit 3
    fi
    echo "defprod-stamp: missing DEFPROD_API_URL / DEFPROD_API_KEY — skipping stamp" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Correlation: resolve the change key(s) for this stamp
# ---------------------------------------------------------------------------
# Emit one `slug|key|ceilings|sha` token per correlated change (fields empty when
# the carrier has none). Parses the product-scoped `Change: <slug>/CHG-NN`
# trailer, the legacy bare `Change: CHG-NN`, and the optional stage suffix
# `Change: <slug>/CHG-NN:<stage>`.
#
# The suffix declares the furthest stage that COMMIT is entitled to advance its
# change to. A commit without one delivers the change in full, which is the
# default and the majority case, so the format stays backward compatible.
#
# Note the regex previously ended at the key, and `grep -oE` matches a prefix: a
# suffixed trailer read by an older copy of this script silently truncates to
# `<slug>/CHG-NN` and is treated as delivering the change in full. That is the
# dangerous direction of version skew, which is why the tooling that WRITES the
# suffix must check this script supports it first.

# Extract the raw trailers from one commit message on stdin, as `slug|key|ceiling`.
parse_trailers_raw() {
    grep -oE '^Change:[[:space:]]+([a-z0-9][a-z0-9-]*/)?CHG-[0-9]+(:[A-Za-z][A-Za-z0-9]*)?' 2>/dev/null \
        | sed -E 's/^Change:[[:space:]]+//' \
        | awk -F'[/:]' '{
              if (NF == 3)      { print $1 "|" $2 "|" $3 }
              else if (NF == 2) { if ($0 ~ /\//) print $1 "|" $2 "|"; else print "|" $1 "|" $2 }
              else              { print "|" $1 "|" }
          }' \
        | sort -u
}

# Aggregate the trailers across a set of commits, newest first on stdin (one sha
# per line), into one `slug|key|ceilings|sha` token per change.
#
# Aggregation matters because a deploy range routinely carries SEVERAL commits for
# one change — a design commit and the landing commit often ship in the same
# deploy — and the landing is what entitles the ship. So:
#
#   * if ANY commit for the change carried no suffix, the change is unbounded and
#     the ceilings field is emitted empty;
#   * otherwise every declared ceiling is passed through, comma separated, and the
#     server decides using the one stage order there is. Ordering deliberately
#     does NOT live in this script: a second copy of it here would drift from the
#     first, which has happened before in this pipeline.
#
# `sha` is the NEWEST commit carrying the change in the range — the landing, in
# the usual case — and is what makes the stamp idempotent: the server refuses a
# second advance of the same stage from the same commit, however many times a
# range re-includes it.
aggregate_trailers() {
    awk -F'|' '
        {
            sha = $4; slug = $1; key = $2; ceiling = $3;
            id = slug "|" key;
            if ( !(id in firstsha) ) { firstsha[id] = sha; order[++n] = id; }
            if ( ceiling == "" ) { unbounded[id] = 1; }
            else if ( !(id in unbounded) ) {
                if ( ceilings[id] == "" ) ceilings[id] = ceiling;
                else if ( index("," ceilings[id] ",", "," ceiling ",") == 0 ) ceilings[id] = ceilings[id] "," ceiling;
            }
        }
        END {
            for ( i = 1; i <= n; i++ ) {
                id = order[i];
                c = (id in unbounded) ? "" : ceilings[id];
                print id "|" c "|" firstsha[id];
            }
        }
    '
}

resolve_keys() {
    if [[ -n "$EXPLICIT_KEY" ]]; then
        # Accept either a bare key or a <slug>/CHG-NN form.
        if [[ "$EXPLICIT_KEY" == */* ]]; then
            echo "${EXPLICIT_KEY%%/*}|${EXPLICIT_KEY##*/}||"
        else
            echo "|$EXPLICIT_KEY||"
        fi
        return
    fi
    if [[ -n "$RANGE" ]]; then
        # Batched deploys: every distinct change in the range gets stamped.
        # Capture git's own status before the pipe — an unreadable range (typo,
        # unfetched sha, shallow clone) otherwise looks exactly like a range that
        # genuinely carried no trailers. Returns 4 so the caller can tell them
        # apart; harmless for stamping, load-bearing for --list-changes.
        local shas
        if ! shas=$(git log --format=%H "$RANGE" 2>/dev/null); then
            return 4
        fi
        # Per-commit rather than one concatenated blob: the sha has to stay
        # attached to the trailer it came from, which a single `git log --format=%B`
        # over the whole range throws away. Newest first, as git emits them.
        local sha body
        while IFS= read -r sha; do
            [[ -n "$sha" ]] || continue
            body=$(git log -1 --format=%B "$sha" 2>/dev/null)
            printf '%s\n' "$body" | parse_trailers_raw | sed -e "s|\$|\|${sha}|"
        done <<< "$shas" | aggregate_trailers
        return 0
    fi
    local branch="${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
    # New form carries the product slug: chg/<slug>/CHG-NN-... The slug pattern is
    # lowercase/url-safe, so it never matches an uppercase `CHG-` — a legacy
    # chg/CHG-NN-... branch correctly falls through to the slug-less case below.
    if [[ "$branch" =~ ^chg/([a-z0-9][a-z0-9-]*)/(CHG-[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}||"
        return
    fi
    if [[ "$branch" =~ ^chg/(CHG-[0-9]+) ]]; then
        # Legacy branch names carry no slug — fall back to the configured productId.
        echo "|${BASH_REMATCH[1]}||"
        return
    fi
    # HEAD's own trailer, carrying HEAD's sha so this path is de-duplicated too.
    local head_sha
    head_sha=$(git rev-parse HEAD 2>/dev/null || printf '')
    git log -1 --format=%B 2>/dev/null \
        | parse_trailers_raw \
        | sed -e "s|\$|\|${head_sha}|" \
        | aggregate_trailers
}

KEYS=$(resolve_keys)
RESOLVE_RC=$?
if [[ "$RESOLVE_RC" -ne 0 ]]; then
    echo "defprod-stamp: could not read git rev range '$RANGE'" >&2
    [[ "$LIST_CHANGES" -eq 1 ]] && exit 3
    exit 0
fi
if [[ -z "$KEYS" ]]; then
    # A genuinely empty result. For --list-changes this is a complete answer
    # (exit 0, no output), not a failure.
    echo "defprod-stamp: no change key found (branch/trailers) — nothing to stamp" >&2
    exit 0
fi

# Set when any change could not be resolved, so --list-changes can report that
# its output is partial instead of passing an under-count off as the answer.
INCOMPLETE=0

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
    IFS='|' read -r SLUG KEY CEILINGS COMMIT_SHA <<< "$TOKEN"

    # Product resolution: a slug in the trailer names its own product; otherwise
    # fall back to the configured DEFPROD_PRODUCT_ID.
    PID="$PRODUCT_ID"
    if [[ -n "$SLUG" ]]; then
        RESOLVED=$(resolve_product_id_from_slug "$SLUG")
        if [[ -n "$RESOLVED" ]]; then
            PID="$RESOLVED"
        elif [[ "$LIST_CHANGES" -eq 1 ]]; then
            # No fallback when listing. A CHG-NN key is unique only WITHIN a
            # product, so resolving another product's key against the configured
            # productId can return a real change that this range never carried —
            # a confidently wrong id, not a miss. That trade is acceptable for a
            # stamp (worst case: one stage time on the wrong change, visible in
            # the change's own event trail) and not for a list, whose output is
            # the answer. Drop it and mark the answer partial.
            echo "defprod-stamp: slug '$SLUG' (for $KEY) did not resolve to a product — omitting from the list" >&2
            INCOMPLETE=1
            continue
        else
            echo "defprod-stamp: slug '$SLUG' (for $KEY) did not resolve to a product — falling back to configured productId" >&2
        fi
    fi
    if [[ -z "$PID" ]]; then
        echo "defprod-stamp: no productId for $KEY (no slug resolved and DEFPROD_PRODUCT_ID unset) — skipping" >&2
        INCOMPLETE=1
        continue
    fi

    CHANGE_JSON=$(curl -sk -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $API_KEY" \
        -d "{\"name\":\"getChange\",\"input\":{\"productId\":\"$PID\",\"key\":\"$KEY\"}}" 2>/dev/null)
    CHANGE_ID=$(echo "$CHANGE_JSON" | jq -r '.data._id // empty' 2>/dev/null)
    if [[ -z "$CHANGE_ID" ]]; then
        echo "defprod-stamp: change $KEY not found in product $PID — skipping" >&2
        INCOMPLETE=1
        continue
    fi

    # --list-changes stops here: the correlation is the whole product of this
    # mode. One JSON object per line on stdout — line-oriented so a caller can
    # stream it, and self-describing so adding a field later does not silently
    # shift a column out from under anyone. `jq -r .changeId` for bare ids,
    # `jq -s 'map(.changeId)'` to build the array a deployment run wants.
    if [[ "$LIST_CHANGES" -eq 1 ]]; then
        jq -cn --arg key "$KEY" --arg slug "$SLUG" --arg pid "$PID" --arg cid "$CHANGE_ID" \
            '{key:$key, slug:(if $slug == "" then null else $slug end), productId:$pid, changeId:$cid}'
        continue
    fi

    NOTE_FIELD=""
    if [[ -n "$NOTE" ]]; then
        NOTE_FIELD=",\"note\":$(jq -Rn --arg n "$NOTE" '$n')"
    fi
    # cancelChangeStage and failChangeStage both act on whatever stage is in
    # progress — they take no `stage` (the server resolves it); start/finish
    # carry the explicit stage.
    if [[ "$ACTION" == "cancelChangeStage" || "$ACTION" == "failChangeStage" ]]; then
        INPUT="{\"changeId\":\"$CHANGE_ID\"$NOTE_FIELD}"
    else
        # Commit provenance rides only on start/finish, the two actions that move
        # the change. An empty CEILINGS field means at least one correlated commit
        # delivers the change in full, so the field is omitted entirely rather than
        # sent empty — an empty array would read as "entitled to nothing".
        PROVENANCE_FIELDS=""
        if [[ -n "$CEILINGS" ]]; then
            CEILINGS_JSON=$(printf '%s' "$CEILINGS" | jq -Rc 'split(",")' 2>/dev/null)
            [[ -n "$CEILINGS_JSON" ]] && PROVENANCE_FIELDS=",\"stageCeilings\":$CEILINGS_JSON"
        fi
        if [[ -n "$COMMIT_SHA" ]]; then
            PROVENANCE_FIELDS="$PROVENANCE_FIELDS,\"commitSha\":$(jq -Rn --arg v "$COMMIT_SHA" '$v')"
        fi
        INPUT="{\"changeId\":\"$CHANGE_ID\",\"stage\":\"$STAGE\"$NOTE_FIELD$PROVENANCE_FIELDS}"
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
        # stderr, not stdout: stdout is the data channel (--list-changes), and a
        # progress line on it would corrupt any caller reading the script's
        # output. Every message this script prints is a diagnostic.
        echo "defprod-stamp: $ACTION $STAGE stamped for $KEY" >&2
    fi
done

# Listing is the only mode that reports partial failure. Stamping stays exit-0
# by design — see the Exit codes note in the header.
if [[ "$LIST_CHANGES" -eq 1 && "$INCOMPLETE" -eq 1 ]]; then
    echo "defprod-stamp: --list-changes output is INCOMPLETE — one or more changes did not resolve" >&2
    exit 3
fi

exit 0
