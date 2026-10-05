# Shared logging, GitHub API, serialization, and UI helpers.

log () 
{ 
    printf '[%s] %s\n' "$PROGRAM" "$*" 1>&2
}

warn () 
{ 
    printf '[%s] WARNING: %s\n' "$PROGRAM" "$*" 1>&2
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

best_effort () 
{ 
    local label="$1";
    shift;
    if ! "$@"; then
        warn "$label failed; continuing.";
        return 0;
    fi
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
    if ! api --paginate --slurp "$endpoint" "$@" > "$outfile" 2> "$outfile.err"; then
        warn "could not snapshot $endpoint (see $outfile.err)";
        rm -f "$outfile";
        return 0;
    fi;
    rm -f "$outfile.err"
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
