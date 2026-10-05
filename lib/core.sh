# Shared logging, GitHub API, serialization, and UI helpers.

log () 
{ 
    printf '[%s] %s\n' "$PROGRAM" "$*" 1>&2
}

vlog ()
{
    (( ${VERBOSE:-0} )) && log "$*"
    return 0
}

warn () 
{ 
    printf '[%s] WARNING: %s\n' "$PROGRAM" "$*" 1>&2
}

vwarn ()
{
    (( ${VERBOSE:-0} )) && warn "$*"
    return 0
}

die () 
{ 
    printf '[%s] ERROR: %s\n' "$PROGRAM" "$*" 1>&2;
    exit 1
}

usage () 
{ 
    cat <<'USAGE_EOF'
gh-repo-reset — recreate a GitHub repository as one fresh initial commit

Usage:
  gh-repo-reset [OWNER/REPO] [options]

Options:
  --yes                    Skip typed OWNER/REPO confirmation.
  --allow-metadata-loss    Accept GitHub-only history/credentials that cannot be round-tripped.
  --backup-dir DIR         Root directory for timestamped safety backups.
  --secrets-dir DIR        Explicit local secret values to reapply after recreation.
  --no-open                Do not open manual follow-up pages with xdg-open.
  --dry-run                Snapshot/report only; do not delete or recreate anything.
  --verbose                Show detailed detection, snapshot, and restore diagnostics.
  --resume-from DIR         Resume an interrupted reset from a persistent safety backup.
  --self-test              Run internal local tests.
  -h, --help               Show help.
  --version                Print the pinned version.

If OWNER/REPO is omitted, it is inferred with `gh repo view`.

A real run:
  1. Makes a full local mirror backup of the old Git repository.
  2. Snapshots readable repository configuration and secret *metadata*.
  3. Creates a new root commit from the old default branch's exact tree.
  4. Deletes and recreates OWNER/REPO.
  5. Pushes ONLY that one root commit.
  6. Best-effort restores readable repository configuration.
  7. Opens GitHub pages for credentials/integrations that require re-authorization.

The recreated remote does NOT get old commit history, branches, or tags. The local
backup keeps them for emergency recovery. GitHub never returns stored secret values,
webhook signing secrets, private deploy keys, or ephemeral tokens to this tool.
USAGE_EOF

}

need () 
{ 
    command -v "$1" > /dev/null 2>&1 || die "missing dependency: $1"
}

api () 
{ 
    gh api -H "X-GitHub-Api-Version: $API_VERSION" "$@"
}

record_restore_failure ()
{
    local label="$*";
    if [[ -n "${BACKUP_DIR:-}" ]]; then
        printf '%s\n' "$label" >> "$BACKUP_DIR/restore-failures.txt" 2>/dev/null || true;
    fi
}

record_snapshot_failure ()
{
    local label="$1" errfile="${2:-}";
    [[ -n "${BACKUP_DIR:-}" ]] || return 0;
    printf '%s\n' "$label" >> "$BACKUP_DIR/snapshot-failures.txt" 2>/dev/null || true;
    if [[ -n "$errfile" && -s "$errfile" ]]; then
        {
            printf '[%s]\n' "$label";
            cat "$errfile";
            printf '\n';
        } >> "$BACKUP_DIR/snapshot-errors.log" 2>/dev/null || true;
    fi
}

snapshot_error_is_404 ()
{
    local file="$1";
    [[ -s "$file" ]] || return 1;
    grep -Eqi '(^|[^0-9])404([^0-9]|$)|not found' "$file"
}

snapshot_stream ()
{
    local label="$1" err;
    shift;
    err="$(mktemp)";
    if "$@" 2> "$err"; then
        rm -f "$err";
        return 0;
    fi;
    record_snapshot_failure "$label" "$err";
    rm -f "$err";
    return 0
}

snapshot_stream_optional_404 ()
{
    local label="$1" err;
    shift;
    err="$(mktemp)";
    if "$@" 2> "$err"; then
        rm -f "$err";
        return 0;
    fi;
    if snapshot_error_is_404 "$err"; then
        rm -f "$err";
        return 0;
    fi;
    record_snapshot_failure "$label" "$err";
    rm -f "$err";
    return 0
}

snapshot_value ()
{
    local label="$1" fallback="$2" err;
    shift 2;
    err="$(mktemp)";
    if "$@" 2> "$err"; then
        rm -f "$err";
        return 0;
    fi;
    record_snapshot_failure "$label" "$err";
    rm -f "$err";
    printf '%s' "$fallback";
    return 0
}

snapshot_value_optional_404 ()
{
    local label="$1" fallback="$2" err;
    shift 2;
    err="$(mktemp)";
    if "$@" 2> "$err"; then
        rm -f "$err";
        return 0;
    fi;
    if ! snapshot_error_is_404 "$err"; then
        record_snapshot_failure "$label" "$err";
    fi;
    rm -f "$err";
    printf '%s' "$fallback";
    return 0
}
snapshot_capture ()
{
    local outfile="$1" label="$2";
    shift 2;
    if "$@" > "$outfile" 2> "$outfile.err"; then
        rm -f "$outfile.err";
        return 0;
    fi;
    rm -f "$outfile";
    record_snapshot_failure "$label" "$outfile.err";
    rm -f "$outfile.err";
    return 0
}

snapshot_capture_optional_404 ()
{
    local outfile="$1" label="$2";
    shift 2;
    if "$@" > "$outfile" 2> "$outfile.err"; then
        rm -f "$outfile.err";
        return 0;
    fi;
    rm -f "$outfile";
    if snapshot_error_is_404 "$outfile.err"; then
        rm -f "$outfile.err";
        return 2;
    fi;
    record_snapshot_failure "$label" "$outfile.err";
    rm -f "$outfile.err";
    return 1
}

snapshot_json_required ()
{
    local outfile="$1" endpoint="$2" jqexpr="$3";
    snapshot_capture "$outfile" "$endpoint" api "$endpoint" --jq "$jqexpr"
}

snapshot_json_optional_404 ()
{
    local outfile="$1" endpoint="$2" jqexpr="$3" rc=0;
    snapshot_capture_optional_404 "$outfile" "$endpoint" api "$endpoint" --jq "$jqexpr" || rc=$?;
    (( rc == 0 || rc == 2 )) || return 0;
    return 0
}
best_effort () 
{ 
    local label="$1" err;
    shift;

    if (( ${VERBOSE:-0} )); then
        if ! "$@"; then
            record_restore_failure "$label";
            warn "$label failed; continuing.";
        fi;
        return 0;
    fi;

    err="$(mktemp)";
    if "$@" > /dev/null 2> "$err"; then
        rm -f "$err";
        return 0;
    fi;

    record_restore_failure "$label";
    if [[ -n "${BACKUP_DIR:-}" ]]; then
        {
            printf '[%s]\n' "$label";
            cat "$err";
            printf '\n';
        } >> "$BACKUP_DIR/restore-errors.log" 2>/dev/null || true;
    fi;
    warn "$label failed; continuing.";
    rm -f "$err";
    return 0
}

urlencode () 
{ 
    local s="$1" out="" c i;
    LC_ALL=C;
    for ((i=0; i<${#s}; i++))
    do
        c=${s:i:1};
        case "$c" in 
            [a-zA-Z0-9.~_-])
                out+="$c"
            ;;
            *)
                printf -v c '%%%02X' "'$c";
                out+="$c"
            ;;
        esac;
    done;
    printf '%s' "$out"
}

write_assignment () 
{ 
    local file="$1" key="$2" value="$3";
    printf '%s=%q\n' "$key" "$value" >> "$file"
}

tsv_decode ()
{
    printf '%b' "$1"
}

run_snapshot_jobs ()
{
    local dir="$1";
    shift;
    local limit="${GH_REPO_RESET_JOBS:-4}" fn pid status=0;
    local -a pids=();

    [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=4;

    for fn in "$@"; do
        "$fn" "$dir" &
        pids+=("$!");
        if (( ${#pids[@]} >= limit )); then
            for pid in "${pids[@]}"; do
                wait "$pid" || status=1;
            done;
            pids=();
        fi;
    done;

    for pid in "${pids[@]}"; do
        wait "$pid" || status=1;
    done;

    (( status == 0 )) || die "one or more snapshot jobs failed"
}

bool () 
{ 
    case "${1:-false}" in 
        true | TRUE | 1 | yes | enabled)
            printf 'true'
        ;;
        *)
            printf 'false'
        ;;
    esac
}

snapshot_api () 
{ 
    local outfile="$1" endpoint="$2";
    shift 2;
    snapshot_capture "$outfile" "$endpoint" api --paginate --slurp "$endpoint" "$@"
}

snapshot_json () 
{ 
    local outfile="$1" endpoint="$2" jqexpr="$3";
    if ! api "$endpoint" --jq "$jqexpr" > "$outfile" 2> "$outfile.err"; then
        rm -f "$outfile" "$outfile.err";
        return 1;
    fi;
    rm -f "$outfile.err";
    return 0
}

restore_json () 
{ 
    local label="$1" method="$2" endpoint="$3" file="$4";
    [[ -s "$file" ]] || return 0;
    best_effort "$label" api --method "$method" "$endpoint" --input "$file" > /dev/null
}

open_url () 
{ 
    local url="$1";
    (( NO_OPEN )) && return 0;
    if command -v xdg-open > /dev/null 2>&1; then
        xdg-open "$url" > /dev/null 2>&1 &
    else
        warn "xdg-open not found; review manually: $url";
    fi
}

repo_field () 
{ 
    local expr="$1";
    api "repos/$REPO" --jq "$expr"
}
