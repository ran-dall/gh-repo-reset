# Build a repository-specific restore plan and concise status report.

record_manual_item ()
{
    local key="$1" detail="$2";
    printf '%s\t%s\n' "$key" "$detail" >> "$BACKUP_DIR/manual-items.tsv"
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

join_semicolon ()
{
    local out="" item;
    for item in "$@"; do
        [[ -n "$out" ]] && out+="; ";
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
    local labels keys vars envs rules protections autolinks hooks access apps org_bindings;
    local enabled=() detail f;
    source "$dir/repo-state.sh";
    : > "$plan";

    [[ "$(bool "$HAS_ISSUES")" == true ]] && enabled+=("issues");
    [[ "$(bool "$HAS_PROJECTS")" == true ]] && enabled+=("projects");
    [[ "$(bool "$HAS_WIKI")" == true ]] && enabled+=("wiki");
    [[ "$(bool "$HAS_DISCUSSIONS")" == true ]] && enabled+=("discussions");
    [[ "${ADVANCED_SECURITY:-unknown}" == enabled ]] && enabled+=("advanced security");
    [[ "${SECRET_SCANNING:-unknown}" == enabled ]] && enabled+=("secret scanning");
    [[ "${PUSH_PROTECTION:-unknown}" == enabled ]] && enabled+=("push protection");
    detail="default=$DEFAULT_BRANCH, visibility=$VISIBILITY";
    ((${#enabled[@]})) && detail+=", enabled=$(join_semicolon "${enabled[@]}")";
    plan_add "$plan" auto "repository settings" "$detail";

    labels="$(count_child_dirs "$dir/labels")";
    keys="$(count_child_dirs "$dir/deploy-keys")";
    vars="$(count_child_files "$dir/variables/repository")";
    envs="$(count_child_dirs "$dir/environments")";
    rules="$(count_child_dirs "$dir/rulesets")";
    protections="$(count_child_dirs "$dir/branch-protection")";
    autolinks="$(count_child_dirs "$dir/autolinks")";
    hooks="$(count_child_dirs "$dir/webhooks")";
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
    (( vars )) && plan_add "$plan" auto "repository variables" "$vars";
    (( envs )) && plan_add "$plan" auto "environments" "$envs";
    [[ -d "$dir/actions" ]] && plan_add "$plan" auto "Actions configuration" "captured";
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
    ((${#enabled[@]})) && parts+=("$(IFS=', '; echo "${enabled[*]}")");

    n="$(count_child_dirs "$dir/labels")"; (( n )) && parts+=("$n labels");
    n="$(count_child_dirs "$dir/environments")"; (( n )) && parts+=("$n environments");
    n="$(count_child_files "$dir/variables/repository")"; (( n )) && parts+=("$n variables");
    n="$(count_child_dirs "$dir/rulesets")"; (( n )) && parts+=("$n rulesets");
    n="$(count_child_dirs "$dir/branch-protection")"; (( n )) && parts+=("$n protected branches");
    n="$(count_child_dirs "$dir/webhooks")"; (( n )) && parts+=("$n webhooks");

    ((${#parts[@]})) && log "Detected: $(join_semicolon "${parts[@]}")"
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
