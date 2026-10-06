# Destructive-operation guards and detection of non-round-trippable state.

has_irreplaceable_metadata () 
{ 
    local found=0 first stars forks is_fork f secret_count webhook_count;
    : > "$BACKUP_DIR/manual-items.tsv";

    first="$(api "repos/$REPO/issues?state=all&per_page=1" --jq '.[0].number // empty' 2> /dev/null || true)";
    if [[ -n "$first" ]]; then
        record_manual_item history "issues and/or pull requests are not recreated";
        found=1;
    fi;

    first="$(api "repos/$REPO/releases?per_page=1" --jq '.[0].id // empty' 2> /dev/null || true)";
    if [[ -n "$first" ]]; then
        record_manual_item history "releases/assets are not recreated";
        found=1;
    fi;

    stars="$(repo_field '.stargazers_count // 0')";
    forks="$(repo_field '.forks_count // 0')";
    is_fork="$(repo_field '.fork // false')";

    if (( stars > 0 )); then
        record_manual_item identity "$stars star(s) do not follow the new repository ID";
        found=1;
    fi;
    if (( forks > 0 )); then
        record_manual_item identity "$forks fork(s) may be affected";
        found=1;
    fi;
    if [[ "$(bool "$is_fork")" == true ]]; then
        record_manual_item identity "fork-network identity is not recreated";
        found=1;
    fi;

    secret_count="$(count_missing_secret_values "$BACKUP_DIR")";
    if (( secret_count > 0 )); then
        record_manual_item secrets "$secret_count stored secret value(s) must be supplied or re-entered";
        found=1;
    fi;

    webhook_count="$(count_unrestorable_signed_webhooks "$BACKUP_DIR")";
    if (( webhook_count > 0 )); then
        record_manual_item webhooks "$webhook_count signed webhook secret(s) must be supplied or re-entered";
        found=1;
    fi;

    if [[ -s "$BACKUP_DIR/actions/runners.json" ]] && grep -q '"total_count"[[:space:]]*:[[:space:]]*[1-9]' "$BACKUP_DIR/actions/runners.json" 2> /dev/null; then
        record_manual_item runners "self-hosted runner registrations must be reauthorized";
        found=1;
    fi;

    if [[ -f "$BACKUP_DIR/app-installations/unavailable" ]]; then
        record_manual_item app_installations "GitHub App installations could not be inspected with the current gh token; review repository access after recreation";
        found=1;
    elif [[ -s "$BACKUP_DIR/app-installations/unverified.tsv" ]]; then
        local app_id app_slug;
        local -a app_labels=();
        while IFS=$'\t' read -r app_id app_slug; do
            [[ -n "$app_id" ]] || continue;
            app_labels+=("${app_slug:-installation-$app_id}");
        done < "$BACKUP_DIR/app-installations/unverified.tsv";
        if ((${#app_labels[@]})); then
            record_manual_item app_installations "selected GitHub App repository access could not be verified for: $(join_comma "${app_labels[@]}")";
            found=1;
        fi;
    fi;

    for f in "$BACKUP_DIR"/branch-protection/*/state.sh; do
        [[ -f "$f" ]] || continue;
        source "$f";
        source "$BACKUP_DIR/repo-state.sh";
        if [[ "$BRANCH_NAME" != "$DEFAULT_BRANCH" ]]; then
            record_manual_item branches "protected branch '$BRANCH_NAME' will not be recreated";
            found=1;
        fi;
    done;

    source "$BACKUP_DIR/repo-state.sh";
    if [[ "${LFS_USED:-false}" == true && "${LFS_BACKUP:-none}" != complete ]]; then
        record_manual_item lfs "Git LFS objects were not safely backed up";
        found=1;
    fi;

    if [[ -f "$BACKUP_DIR/pages-state.sh" ]]; then
        source "$BACKUP_DIR/pages-state.sh";
        source "$BACKUP_DIR/repo-state.sh";
        if [[ "${PAGES_BUILD_TYPE:-legacy}" != workflow && -n "${PAGES_SOURCE_BRANCH:-}" && "$PAGES_SOURCE_BRANCH" != "$DEFAULT_BRANCH" ]]; then
            record_manual_item pages "Pages source '$PAGES_SOURCE_BRANCH' will not be recreated";
            found=1;
        fi;
    fi;

    (( found ))
}

confirm_reset () 
{ 
    (( YES )) && return 0;
    local typed package_count=0 local_checkout="" worktree_count=0;
    package_count="$(count_nonempty_lines "$BACKUP_DIR/package-reset-targets.tsv")";
    [[ -s "$BACKUP_DIR/local-checkout.path" ]] && local_checkout="$(cat "$BACKUP_DIR/local-checkout.path")";
    [[ -s "$BACKUP_DIR/local-worktrees.tsv" ]] && worktree_count="$(count_nonempty_lines "$BACKUP_DIR/local-worktrees.tsv")";
    printf '\nThis will DELETE and RECREATE %s with ONE fresh initial commit.\n' "$REPO" 1>&2;
    if (( package_count )); then
        printf 'It will also DELETE %s detected same-owner GitHub package(s) for this reset.\n' "$package_count" 1>&2;
    fi;
    if [[ -n "$local_checkout" ]]; then
        printf 'It will also RESET the matching local repository at %s (%s worktree(s)).\n' "$local_checkout" "$worktree_count" 1>&2;
    fi;
    printf 'Type the full repository name (%s) to continue: ' "$REPO" 1>&2;
    if [[ -r /dev/tty ]]; then
        IFS= read -r typed < /dev/tty;
    else
        die "no interactive TTY; rerun interactively or pass --yes deliberately";
    fi;
    [[ "$typed" == "$REPO" ]] || die "confirmation did not match"
}
