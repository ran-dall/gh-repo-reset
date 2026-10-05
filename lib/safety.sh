# Destructive-operation guards and detection of non-round-trippable state.

file_has_secret_names () 
{ 
    local f;
    for f in "$BACKUP_DIR"/secrets/*.names "$BACKUP_DIR"/environments/*/actions-secret-names.txt;
    do
        [[ -f "$f" && -s "$f" ]] && return 0;
    done;
    return 1
}

has_irreplaceable_metadata () 
{ 
    local found=0 first stars forks is_fork f;
    first="$(api "repos/$REPO/issues?state=all&per_page=1" --jq '.[0].number // empty' 2> /dev/null || true)";
    if [[ -n "$first" ]]; then
        warn "repository has issues and/or pull requests; they are archived locally but not recreated";
        found=1;
    fi;
    first="$(api "repos/$REPO/releases?per_page=1" --jq '.[0].id // empty' 2> /dev/null || true)";
    if [[ -n "$first" ]]; then
        warn "repository has releases/assets that are not recreated";
        found=1;
    fi;
    stars="$(repo_field '.stargazers_count // 0')";
    forks="$(repo_field '.forks_count // 0')";
    is_fork="$(repo_field '.fork // false')";
    if (( stars > 0 )); then
        warn "repository has $stars star(s) that do not follow a newly created repository ID";
        found=1;
    fi;
    if (( forks > 0 )); then
        warn "repository has $forks fork(s); fork-network identity can be affected";
        found=1;
    fi;
    if [[ "$(bool "$is_fork")" == true ]]; then
        warn "repository is a fork; the recreated repository is standalone";
        found=1;
    fi;
    if file_has_secret_names; then
        warn "stored secret values are intentionally unreadable; names only were captured";
        found=1;
    fi;
    for f in "$BACKUP_DIR"/webhooks/*/state.sh;
    do
        [[ -f "$f" ]] || continue;
        source "$f";
        if [[ "${HOOK_SECRET_STATUS:-unknown}" != unsigned ]]; then
            warn "a webhook may use a signing secret; it requires an explicitly supplied secret value";
            found=1;
            break;
        fi;
    done;
    if [[ -s "$BACKUP_DIR/actions/runners.json" ]] && grep -q '"total_count"[[:space:]]*:[[:space:]]*[1-9]' "$BACKUP_DIR/actions/runners.json" 2> /dev/null; then
        warn "repository has self-hosted runner registrations; runner credentials cannot be migrated";
        found=1;
    fi;
    for f in "$BACKUP_DIR"/branch-protection/*/state.sh;
    do
        [[ -f "$f" ]] || continue;
        source "$f";
        source "$BACKUP_DIR/repo-state.sh";
        if [[ "$BRANCH_NAME" != "$DEFAULT_BRANCH" ]]; then
            warn "protected branch '$BRANCH_NAME' will not exist after the single-branch reset";
            found=1;
        fi;
    done;
    source "$BACKUP_DIR/repo-state.sh";
    if [[ "${LFS_USED:-false}" == true && "${LFS_BACKUP:-none}" != complete ]]; then
        warn "Git LFS content is in use but was not safely backed up";
        found=1;
    fi;
    if [[ -f "$BACKUP_DIR/pages-state.sh" ]]; then
        source "$BACKUP_DIR/pages-state.sh";
        source "$BACKUP_DIR/repo-state.sh";
        if [[ "${PAGES_BUILD_TYPE:-legacy}" != workflow && -n "${PAGES_SOURCE_BRANCH:-}" && "$PAGES_SOURCE_BRANCH" != "$DEFAULT_BRANCH" ]]; then
            warn "Pages publishes from '$PAGES_SOURCE_BRANCH', which will not be recreated";
            found=1;
        fi;
    fi;
    (( found ))
}

confirm_reset () 
{ 
    (( YES )) && return 0;
    local typed;
    printf '\nThis will DELETE and RECREATE %s with ONE fresh initial commit.\n' "$REPO" 1>&2;
    printf 'Type the full repository name (%s) to continue: ' "$REPO" 1>&2;
    if [[ -r /dev/tty ]]; then
        IFS= read -r typed < /dev/tty;
    else
        die "no interactive TTY; rerun interactively or pass --yes deliberately";
    fi;
    [[ "$typed" == "$REPO" ]] || die "confirmation did not match"
}
