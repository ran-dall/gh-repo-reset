# Build a repository-specific restore plan and concise status report.

record_manual_item ()
{
    local key="$1" detail="$2" line;
    line="$(printf '%s\t%s' "$key" "$detail")";
    [[ -f "$BACKUP_DIR/manual-items.tsv" ]] && grep -Fqx "$line" "$BACKUP_DIR/manual-items.tsv" && return 0;
    printf '%s\n' "$line" >> "$BACKUP_DIR/manual-items.tsv"
}

json_top_level_bool ()
{
    local file="$1" key="$2";
    [[ -f "$file" ]] || return 1;
    tr -d '\n' < "$file" | sed -n "s/.*\"$key\":\(true\|false\).*/\1/p" | head -n1
}

repair_legacy_repo_booleans ()
{
    local dir="$1" state="$1/repo-state.sh" raw="$1/repository.json";
    local schema var key value repaired=0;

    [[ -f "$state" ]] || return 0;
    # shellcheck disable=SC1090
    source "$state";
    schema="${SNAPSHOT_SCHEMA_VERSION:-1}";
    (( schema >= 2 )) && return 0;
    [[ -f "$raw" ]] || {
        warn "legacy backup predates reliable boolean capture; repository settings may need manual verification";
        return 0;
    };

    while IFS='|' read -r var key; do
        value="$(json_top_level_bool "$raw" "$key" || true)";
        [[ "$value" == true || "$value" == false ]] || continue;
        write_assignment "$state" "$var" "$value";
        repaired=1;
    done <<'BOOL_EOF'
ALLOW_SQUASH|allow_squash_merge
ALLOW_MERGE|allow_merge_commit
ALLOW_REBASE|allow_rebase_merge
ALLOW_FORKING|allow_forking
HAS_DOWNLOADS|has_downloads
HAS_PULL_REQUESTS|has_pull_requests
BOOL_EOF

    if (( repaired )); then
        write_assignment "$state" LEGACY_REPO_BOOLEANS_REPAIRED true;
        vlog "Repaired legacy boolean snapshot values from repository.json";
    fi;
}

count_nonempty_lines ()
{
    local file="$1";
    [[ -f "$file" ]] || { printf '0'; return 0; }
    awk 'NF { n++ } END { print n+0 }' "$file"
}

count_child_dirs ()
{
    local dir="$1";
    [[ -d "$dir" ]] || { printf '0'; return 0; }
    find "$dir" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | awk 'END { print NR+0 }'
}

count_child_files ()
{
    local dir="$1";
    [[ -d "$dir" ]] || { printf '0'; return 0; }
    find "$dir" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null | awk 'END { print NR+0 }'
}

count_secret_names ()
{
    local dir="$1" f total=0 n;
    shopt -s nullglob;
    for f in "$dir"/secrets/*.names "$dir"/environments/*/actions-secret-names.txt; do
        n="$(count_nonempty_lines "$f")";
        total=$((total+n));
    done;
    shopt -u nullglob;
    printf '%s' "$total"
}

count_environment_variables ()
{
    local dir="$1" envdir total=0;
    shopt -s nullglob;
    for envdir in "$dir"/environments/*; do
        [[ -d "$envdir/variables" ]] || continue;
        total=$((total + $(count_child_files "$envdir/variables")));
    done;
    shopt -u nullglob;
    printf '%s' "$total"
}

count_missing_secret_values ()
{
    local dir="$1" app file name envdir total=0;
    for app in actions agents codespaces dependabot; do
        file="$dir/secrets/$app.names";
        [[ -f "$file" ]] || continue;
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue;
            if [[ -n "${SECRETS_DIR:-}" && ( -f "$SECRETS_DIR/repository/$app/$name" || -f "$SECRETS_DIR/$app/$name" ) ]]; then
                continue;
            fi;
            total=$((total+1));
        done < "$file";
    done;
    shopt -s nullglob;
    for envdir in "$dir"/environments/*; do
        [[ -f "$envdir/state.sh" && -f "$envdir/actions-secret-names.txt" ]] || continue;
        source "$envdir/state.sh";
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue;
            if [[ -n "${SECRETS_DIR:-}" && -f "$SECRETS_DIR/environments/$ENV_KEY/actions/$name" ]]; then
                continue;
            fi;
            total=$((total+1));
        done < "$envdir/actions-secret-names.txt";
    done;
    shopt -u nullglob;
    printf '%s' "$total"
}

count_restorable_webhooks ()
{
    local dir="$1" hdir secret_file total=0;
    shopt -s nullglob;
    for hdir in "$dir"/webhooks/*; do
        [[ -f "$hdir/state.sh" ]] || continue;
        source "$hdir/state.sh";
        secret_file="${SECRETS_DIR:+$SECRETS_DIR/webhooks/$OLD_HOOK_ID.secret}";
        if [[ "${HOOK_SECRET_STATUS:-unknown}" == unsigned || ( -n "$secret_file" && -f "$secret_file" ) ]]; then
            total=$((total+1));
        fi;
    done;
    shopt -u nullglob;
    printf '%s' "$total"
}

count_unrestorable_signed_webhooks ()
{
    local dir="$1" hdir secret_file total=0;
    shopt -s nullglob;
    for hdir in "$dir"/webhooks/*; do
        [[ -f "$hdir/state.sh" ]] || continue;
        source "$hdir/state.sh";
        secret_file="${SECRETS_DIR:+$SECRETS_DIR/webhooks/$OLD_HOOK_ID.secret}";
        if [[ "${HOOK_SECRET_STATUS:-unknown}" != unsigned && ( -z "$secret_file" || ! -f "$secret_file" ) ]]; then
            total=$((total+1));
        fi;
    done;
    shopt -u nullglob;
    printf '%s' "$total"
}

join_semicolon ()
{
    local out="" item;
    for item in "$@"; do
        [[ -n "$out" ]] && out+="; ";
        out+="$item";
    done;
    printf '%s' "$out"
}

join_comma ()
{
    local out="" item;
    for item in "$@"; do
        [[ -n "$out" ]] && out+=", ";
        out+="$item";
    done;
    printf '%s' "$out"
}

plan_add ()
{
    local file="$1" mode="$2" feature="$3" detail="$4";
    printf '%s\t%s\t%s\n' "$mode" "$feature" "$detail" >> "$file"
}

build_restore_plan ()
{
    local dir="$1" plan="$1/restore-plan.tsv";
    local labels keys vars env_vars envs action_policies rules protections autolinks hooks access apps org_bindings;
    local enabled=() merges=() detail f;
    source "$dir/repo-state.sh";
    : > "$plan";

    [[ "$(bool "$HAS_ISSUES")" == true ]] && enabled+=("issues");
    [[ "$(bool "$HAS_PROJECTS")" == true ]] && enabled+=("projects");
    [[ "$(bool "$HAS_WIKI")" == true ]] && enabled+=("wiki");
    [[ "$(bool "$HAS_DISCUSSIONS")" == true ]] && enabled+=("discussions");
    [[ "${ADVANCED_SECURITY:-unknown}" == enabled ]] && enabled+=("advanced security");
    [[ "${SECRET_SCANNING:-unknown}" == enabled ]] && enabled+=("secret scanning");
    [[ "${PUSH_PROTECTION:-unknown}" == enabled ]] && enabled+=("push protection");
    [[ "$(bool "$ALLOW_SQUASH")" == true ]] && merges+=("squash");
    [[ "$(bool "$ALLOW_MERGE")" == true ]] && merges+=("merge commit");
    [[ "$(bool "$ALLOW_REBASE")" == true ]] && merges+=("rebase");
    detail="default=$DEFAULT_BRANCH, visibility=$VISIBILITY";
    ((${#enabled[@]})) && detail+=", enabled=$(join_semicolon "${enabled[@]}")";
    ((${#merges[@]})) && detail+=", merge methods=$(join_semicolon "${merges[@]}")";
    detail+=", auto-merge=$(bool "$ALLOW_AUTO_MERGE"), delete-branch-on-merge=$(bool "$DELETE_BRANCH_ON_MERGE"), allow-forking=$(bool "$ALLOW_FORKING"), web-signoff=$(bool "$WEB_COMMIT_SIGNOFF")";
    plan_add "$plan" auto "repository settings" "$detail";

    labels="$(count_child_dirs "$dir/labels")";
    keys="$(count_child_dirs "$dir/deploy-keys")";
    vars="$(count_child_files "$dir/variables/repository")";
    env_vars="$(count_environment_variables "$dir")";
    vars=$((vars+env_vars));
    envs="$(count_child_dirs "$dir/environments")";
    action_policies="$(count_child_dirs "$dir/actions-policies")";
    rules="$(count_child_dirs "$dir/rulesets")";
    protections="$(count_child_dirs "$dir/branch-protection")";
    autolinks="$(count_child_dirs "$dir/autolinks")";
    hooks="$(count_restorable_webhooks "$dir")";
    access=$(( $(count_nonempty_lines "$dir/access/collaborators.tsv") + $(count_nonempty_lines "$dir/access/invitations.tsv") + $(count_nonempty_lines "$dir/access/teams.tsv") ));
    apps="$(count_nonempty_lines "$dir/app-installations/selected.tsv")";
    org_bindings=0;
    if [[ -d "$dir/org-bindings" ]]; then
        shopt -s nullglob;
        for f in "$dir"/org-bindings/*.txt; do
            org_bindings=$((org_bindings + $(count_nonempty_lines "$f")));
        done;
        shopt -u nullglob;
        [[ -f "$dir/org-bindings/actions-enabled-selected" ]] && org_bindings=$((org_bindings+1));
        [[ -f "$dir/org-bindings/code-security-configuration-id" ]] && org_bindings=$((org_bindings+1));
    fi;

    (( labels )) && plan_add "$plan" auto "labels" "$labels";
    (( keys )) && plan_add "$plan" auto "deploy keys" "$keys";
    (( vars )) && plan_add "$plan" auto "variables" "$vars";
    (( envs )) && plan_add "$plan" auto "environments" "$envs";
    if find "$dir/actions" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | grep -q .; then
        plan_add "$plan" auto "Actions configuration" "captured";
    fi;
    (( action_policies )) && plan_add "$plan" auto "Actions policies" "$action_policies";
    (( rules )) && plan_add "$plan" auto "rulesets" "$rules";
    (( protections )) && plan_add "$plan" auto "protected branches" "$protections";
    (( access )) && plan_add "$plan" auto "repository access entries" "$access";
    (( autolinks )) && plan_add "$plan" auto "autolinks" "$autolinks";
    (( hooks )) && plan_add "$plan" auto "webhooks" "$hooks";
    (( apps )) && plan_add "$plan" auto "selected GitHub App bindings" "$apps";
    (( org_bindings )) && plan_add "$plan" auto "organization bindings" "$org_bindings";
    [[ -f "$dir/custom-properties.json" ]] && plan_add "$plan" auto "custom properties" "captured";
    [[ -f "$dir/pages-state.sh" ]] && plan_add "$plan" auto "Pages" "enabled";
    [[ -d "$dir/wiki.git" ]] && plan_add "$plan" auto "wiki Git history" "captured";
    source "$dir/repo-state.sh";
    [[ "${LFS_USED:-false}" == true && "${LFS_BACKUP:-none}" == complete ]] && plan_add "$plan" auto "Git LFS" "objects captured";

    if [[ -s "$dir/manual-items.tsv" ]]; then
        while IFS=$'\t' read -r feature detail; do
            [[ -n "$feature" ]] && plan_add "$plan" manual "$feature" "$detail";
        done < "$dir/manual-items.tsv";
    fi
}

print_detected_summary ()
{
    local dir="$1" enabled=() parts=() n;
    source "$dir/repo-state.sh";
    [[ "$(bool "$HAS_ISSUES")" == true ]] && enabled+=("issues");
    [[ "$(bool "$HAS_PROJECTS")" == true ]] && enabled+=("projects");
    [[ "$(bool "$HAS_WIKI")" == true ]] && enabled+=("wiki");
    [[ "$(bool "$HAS_DISCUSSIONS")" == true ]] && enabled+=("discussions");
    [[ "${ADVANCED_SECURITY:-unknown}" == enabled ]] && enabled+=("advanced security");
    [[ "${SECRET_SCANNING:-unknown}" == enabled ]] && enabled+=("secret scanning");
    [[ "${PUSH_PROTECTION:-unknown}" == enabled ]] && enabled+=("push protection");
    [[ -f "$dir/pages-state.sh" ]] && enabled+=("Pages");
    [[ "${LFS_USED:-false}" == true ]] && enabled+=("Git LFS");
    ((${#enabled[@]})) && parts+=("$(join_comma "${enabled[@]}")");

    n="$(count_child_dirs "$dir/labels")"; (( n )) && parts+=("$n labels");
    n="$(count_child_dirs "$dir/deploy-keys")"; (( n )) && parts+=("$n deploy keys");
    n="$(count_child_dirs "$dir/environments")"; (( n )) && parts+=("$n environments");
    n=$(( $(count_child_files "$dir/variables/repository") + $(count_environment_variables "$dir") )); (( n )) && parts+=("$n variables");
    n="$(count_child_dirs "$dir/rulesets")"; (( n )) && parts+=("$n rulesets");
    n="$(count_child_dirs "$dir/branch-protection")"; (( n )) && parts+=("$n protected branches");
    n="$(count_child_dirs "$dir/webhooks")"; (( n )) && parts+=("$n webhooks");
    n=$(( $(count_nonempty_lines "$dir/access/collaborators.tsv") + $(count_nonempty_lines "$dir/access/invitations.tsv") + $(count_nonempty_lines "$dir/access/teams.tsv") )); (( n )) && parts+=("$n access entries");
    n="$(count_nonempty_lines "$dir/app-installations/selected.tsv")"; (( n )) && parts+=("$n app bindings");
    n="$(count_nonempty_lines "$dir/package-actions-access.tsv")"; (( n )) && parts+=("$n package access candidates");
    n="$(count_nonempty_lines "$dir/package-reset-targets.tsv")"; (( n )) && parts+=("$n GitHub packages to delete");

    ((${#parts[@]})) && log "Detected: $(join_semicolon "${parts[@]}")"
    return 0
}

print_restore_plan_summary ()
{
    local dir="$1" mode feature detail auto=0 manual=();
    while IFS=$'\t' read -r mode feature detail; do
        [[ -n "$mode" ]] || continue;
        if [[ "$mode" == auto ]]; then
            auto=$((auto+1));
        else
            manual+=("$detail");
        fi;
    done < "$dir/restore-plan.tsv";
    log "Will restore $auto detected configuration group(s) automatically."
    ((${#manual[@]})) && warn "Manual after reset: $(join_semicolon "${manual[@]}")"
    return 0
}

print_restore_plan_details ()
{
    local dir="$1" mode feature detail;
    while IFS=$'\t' read -r mode feature detail; do
        [[ -n "$mode" ]] || continue;
        vlog "Plan [$mode] $feature: $detail";
    done < "$dir/restore-plan.tsv"
}

print_restore_result ()
{
    local dir="$1" failures=0;
    [[ -f "$dir/restore-failures.txt" ]] && failures="$(count_nonempty_lines "$dir/restore-failures.txt")";
    if (( failures )); then
        warn "$failures restore operation(s) failed; see $dir/restore-failures.txt";
    else
        log "Detected configuration restore completed."
    fi
}