# Restore repository-native configuration after recreation.

restore_security_analysis_status () 
{ 
    local key="$1" status="$2" label="$3" tmp;
    [[ "$status" == enabled || "$status" == disabled ]] || return 0;
    tmp="$(mktemp)";
    printf '{"security_and_analysis":{"%s":{"status":"%s"}}}\n' "$key" "$status" > "$tmp";
    best_effort "$label" api --method PATCH "repos/$REPO" --input "$tmp" > /dev/null;
    rm -f "$tmp"
}

restore_repo_settings () 
{ 
    local dir="$1";
    source "$dir/repo-state.sh";
    local args=("$REPO" --description "$DESCRIPTION" --homepage "$HOMEPAGE" --enable-issues="$(bool "$HAS_ISSUES")" --enable-projects="$(bool "$HAS_PROJECTS")" --enable-wiki="$(bool "$HAS_WIKI")" --enable-discussions="$(bool "$HAS_DISCUSSIONS")" --enable-squash-merge="$(bool "$ALLOW_SQUASH")" --enable-merge-commit="$(bool "$ALLOW_MERGE")" --enable-rebase-merge="$(bool "$ALLOW_REBASE")" --enable-auto-merge="$(bool "$ALLOW_AUTO_MERGE")" --delete-branch-on-merge="$(bool "$DELETE_BRANCH_ON_MERGE")" --allow-update-branch="$(bool "$ALLOW_UPDATE_BRANCH")");
    best_effort "restoring repository settings" gh repo edit "${args[@]}";
    best_effort "restoring default branch" gh repo edit "$REPO" --default-branch "$DEFAULT_BRANCH";
    [[ "$(bool "$IS_TEMPLATE")" == true ]] && best_effort "restoring template flag" gh repo edit "$REPO" --template;
    local desired_forking current_forking;
    desired_forking="$(bool "$ALLOW_FORKING")";
    current_forking="$(repo_field '.allow_forking // false' 2> /dev/null || printf unknown)";
    if [[ "$current_forking" != "$desired_forking" ]]; then
        best_effort "restoring forking policy" gh repo edit "$REPO" --allow-forking="$desired_forking";
    else
        vlog "Forking policy already matches: $desired_forking";
    fi;
    best_effort "restoring web commit signoff" api --method PATCH "repos/$REPO" -F "web_commit_signoff_required=$(bool "$WEB_COMMIT_SIGNOFF")" > /dev/null;
    local extra_payload="$dir/repository-extra-settings.json";
    printf '{' > "$extra_payload";
    printf '"has_downloads":%s,"has_pull_requests":%s' "$(bool "${HAS_DOWNLOADS:-true}")" "$(bool "${HAS_PULL_REQUESTS:-true}")" >> "$extra_payload";
    [[ -n "${PULL_REQUEST_CREATION_POLICY:-}" ]] && printf ',"pull_request_creation_policy":"%s"' "$PULL_REQUEST_CREATION_POLICY" >> "$extra_payload";
    [[ -n "${SQUASH_MERGE_COMMIT_TITLE:-}" ]] && printf ',"squash_merge_commit_title":"%s"' "$SQUASH_MERGE_COMMIT_TITLE" >> "$extra_payload";
    [[ -n "${SQUASH_MERGE_COMMIT_MESSAGE:-}" ]] && printf ',"squash_merge_commit_message":"%s"' "$SQUASH_MERGE_COMMIT_MESSAGE" >> "$extra_payload";
    [[ -n "${MERGE_COMMIT_TITLE:-}" ]] && printf ',"merge_commit_title":"%s"' "$MERGE_COMMIT_TITLE" >> "$extra_payload";
    [[ -n "${MERGE_COMMIT_MESSAGE:-}" ]] && printf ',"merge_commit_message":"%s"' "$MERGE_COMMIT_MESSAGE" >> "$extra_payload";
    printf '}\n' >> "$extra_payload";
    restore_json "restoring additional repository merge/PR settings" PATCH "repos/$REPO" "$extra_payload";
    if [[ "$ADVANCED_SECURITY" != unknown ]]; then
        best_effort "restoring advanced security" gh repo edit "$REPO" --enable-advanced-security="$(bool "$ADVANCED_SECURITY")";
    fi;
    if [[ "$SECRET_SCANNING" != unknown ]]; then
        best_effort "restoring secret scanning" gh repo edit "$REPO" --enable-secret-scanning="$(bool "$SECRET_SCANNING")";
    fi;
    if [[ "$PUSH_PROTECTION" != unknown ]]; then
        best_effort "restoring secret scanning push protection" gh repo edit "$REPO" --enable-secret-scanning-push-protection="$(bool "$PUSH_PROTECTION")";
    fi;
    restore_security_analysis_status code_security "${CODE_SECURITY:-unknown}" "restoring code security";
    restore_security_analysis_status secret_scanning_ai_detection "${SECRET_SCANNING_AI:-unknown}" "restoring secret scanning AI detection";
    restore_security_analysis_status secret_scanning_non_provider_patterns "${SECRET_SCANNING_NON_PROVIDER:-unknown}" "restoring non-provider secret scanning";
    restore_security_analysis_status secret_scanning_delegated_alert_dismissal "${SECRET_SCANNING_DELEGATED_DISMISSAL:-unknown}" "restoring delegated secret-alert dismissal";
    restore_security_analysis_status secret_scanning_delegated_bypass "${SECRET_SCANNING_DELEGATED_BYPASS:-unknown}" "restoring delegated push-protection bypass";
    restore_json "restoring delegated push-protection reviewers/options" PATCH "repos/$REPO" "$dir/secret-scanning-delegated-bypass-options.json";
    if [[ "$VULNERABILITY_ALERTS" == enabled || "${DEPENDABOT_SECURITY_UPDATES:-unknown}" == enabled ]]; then
        best_effort "restoring vulnerability alerts" api --method PUT "repos/$REPO/vulnerability-alerts" > /dev/null;
    fi;
    if [[ "${DEPENDABOT_SECURITY_UPDATES:-unknown}" == enabled ]]; then
        best_effort "restoring Dependabot security updates" api --method PUT "repos/$REPO/automated-security-fixes" > /dev/null;
    fi;
    if [[ "${PRIVATE_VULNERABILITY_REPORTING:-unknown}" == enabled ]]; then
        best_effort "restoring private vulnerability reporting" api --method PUT "repos/$REPO/private-vulnerability-reporting" > /dev/null;
    fi;
    if [[ "${IMMUTABLE_RELEASES:-unknown}" == enabled ]]; then
        best_effort "restoring immutable releases" api --method PUT "repos/$REPO/immutable-releases" > /dev/null;
    fi;
    local topics_payload="$dir/topics-restore.json" topic sep="";
    printf '{"names":[' > "$topics_payload";
    while IFS= read -r topic; do
        [[ -n "$topic" ]] || continue;
        printf '%s"%s"' "$sep" "$topic" >> "$topics_payload";
        sep=",";
    done < "$dir/topics.txt";
    printf ']}\n' >> "$topics_payload";
    best_effort "restoring repository topics" api --method PUT "repos/$REPO/topics" --input "$topics_payload" > /dev/null
}

restore_labels () 
{ 
    local dir="$1" tmp ldir cdir idx=0;
    local raw_name raw_color raw_description;
    local current_name current_color current_description found desired_match;

    tmp="$(mktemp -d)";
    mkdir -p "$tmp/current";

    while IFS=$'\t' read -r raw_name raw_color raw_description; do
        [[ -n "$raw_name" ]] || continue;
        idx=$((idx+1));
        cdir="$tmp/current/$idx";
        mkdir -p "$cdir";
        current_name="$(tsv_decode "$raw_name")";
        current_color="$(tsv_decode "$raw_color")";
        current_description="$(tsv_decode "$raw_description")";
        write_assignment "$cdir/state.sh" CURRENT_LABEL_NAME "$current_name";
        write_assignment "$cdir/state.sh" CURRENT_LABEL_COLOR "$current_color";
        write_assignment "$cdir/state.sh" CURRENT_LABEL_DESCRIPTION "$current_description";
    done < <(
        gh label list -R "$REPO" --limit 1000 --json name,color,description \
          --jq '.[] | [.name, .color, (.description // "")] | @tsv' 2> /dev/null || true
    );

    shopt -s nullglob;
    for ldir in "$dir"/labels/*; do
        # shellcheck disable=SC1090
        source "$ldir/state.sh";
        found=0;
        for cdir in "$tmp"/current/*; do
            # shellcheck disable=SC1090
            source "$cdir/state.sh";
            if [[ "$CURRENT_LABEL_NAME" == "$LABEL_NAME" ]]; then
                found=1;
                if [[ "$CURRENT_LABEL_COLOR" == "$LABEL_COLOR" && "$CURRENT_LABEL_DESCRIPTION" == "$LABEL_DESCRIPTION" ]]; then
                    : > "$cdir/keep";
                else
                    best_effort "updating label $LABEL_NAME" gh label create "$LABEL_NAME" -R "$REPO" \
                      --force --color "$LABEL_COLOR" --description "$LABEL_DESCRIPTION";
                    : > "$cdir/keep";
                fi;
                break;
            fi;
        done;

        if (( ! found )); then
            best_effort "restoring label $LABEL_NAME" gh label create "$LABEL_NAME" -R "$REPO" \
              --color "$LABEL_COLOR" --description "$LABEL_DESCRIPTION";
        fi;
    done;

    for cdir in "$tmp"/current/*; do
        [[ -f "$cdir/keep" ]] && continue;
        # shellcheck disable=SC1090
        source "$cdir/state.sh";
        desired_match=0;
        for ldir in "$dir"/labels/*; do
            # shellcheck disable=SC1090
            source "$ldir/state.sh";
            if [[ "$LABEL_NAME" == "$CURRENT_LABEL_NAME" ]]; then
                desired_match=1;
                break;
            fi;
        done;
        if (( ! desired_match )); then
            best_effort "removing stale label $CURRENT_LABEL_NAME" \
              gh label delete "$CURRENT_LABEL_NAME" -R "$REPO" --yes;
        fi;
    done;
    shopt -u nullglob;
    rm -rf "$tmp"
}

normalize_ssh_public_key ()
{
    awk 'NF >= 2 { print $1 " " $2; exit }' "$1"
}

deploy_key_attached_to_target ()
{
    local keyfile="$1" desired existing_key existing_normalized existing_readonly;
    desired="$(normalize_ssh_public_key "$keyfile")";
    [[ -n "$desired" ]] || return 1;

    while IFS=$'\t' read -r existing_key existing_readonly; do
        [[ -n "$existing_key" ]] || continue;
        existing_normalized="$(printf '%s\n' "$existing_key" | awk 'NF >= 2 { print $1 " " $2; exit }')";
        if [[ "$existing_normalized" == "$desired" ]]; then
            return 0;
        fi;
    done < <(
        gh repo deploy-key list -R "$REPO" --json key,readOnly \
          --jq '.[] | [.key, (.readOnly|tostring)] | @tsv' 2>/dev/null || true
    );

    return 1
}

clear_deploy_key_manual_items ()
{
    local dir="$1" file="$1/manual-items.tsv" tmp;
    [[ -f "$file" ]] || return 0;
    tmp="$(mktemp)";
    awk -F '\t' '$1 != "deploy_keys"' "$file" > "$tmp";
    mv "$tmp" "$file"
}

reconcile_deploy_key_manual_items ()
{
    local dir="$1" keydir found=0 unresolved=0;
    shopt -s nullglob;
    for keydir in "$dir"/deploy-keys/*; do
        [[ -f "$keydir/key.pub" ]] || continue;
        found=1;
        if ! deploy_key_attached_to_target "$keydir/key.pub"; then
            unresolved=1;
            break;
        fi;
    done;
    shopt -u nullglob;

    if (( found && ! unresolved )); then
        clear_deploy_key_manual_items "$dir";
    fi
}

restore_deploy_keys () 
{ 
    local dir="$1" keydir err label;
    shopt -s nullglob;
    for keydir in "$dir"/deploy-keys/*;
    do
        source "$keydir/state.sh";

        if deploy_key_attached_to_target "$keydir/key.pub"; then
            vlog "Deploy key already attached: $TITLE";
            continue;
        fi;

        err="$keydir/restore.err";
        label="restoring deploy key: $TITLE";
        if [[ "$(bool "$READ_ONLY")" == true ]]; then
            if gh repo deploy-key add "$keydir/key.pub" -R "$REPO" --title "$TITLE" > /dev/null 2> "$err"; then
                rm -f "$err";
                continue;
            fi;
        else
            label="restoring writable deploy key: $TITLE";
            if gh repo deploy-key add "$keydir/key.pub" -R "$REPO" --title "$TITLE" --allow-write > /dev/null 2> "$err"; then
                rm -f "$err";
                continue;
            fi;
        fi;

        if grep -qi 'key is already in use' "$err"; then
            if deploy_key_attached_to_target "$keydir/key.pub"; then
                vlog "Deploy key became attached during restore: $TITLE";
                rm -f "$err";
                continue;
            fi;
            record_manual_item deploy_keys "deploy key '$TITLE' is already attached to another GitHub account or repository";
            warn "deploy key '$TITLE' could not be transferred because GitHub reports that key is already in use";
            rm -f "$err";
            continue;
        fi;

        record_restore_failure "$label";
        warn "$label failed; continuing.";
        (( VERBOSE )) && sed 's/^/  /' "$err" >&2 || true;
        rm -f "$err";
    done;
    shopt -u nullglob;

    reconcile_deploy_key_manual_items "$dir"
}

restore_variables () 
{ 
    local dir="$1" file name;
    shopt -s nullglob;
    for file in "$dir"/variables/repository/*;
    do
        [[ -f "$file" ]] || continue;
        name="$(basename "$file")";
        best_effort "restoring repository variable $name" gh variable set "$name" -R "$REPO" --body "$(cat "$file")";
    done;
    shopt -u nullglob
}

restore_environment_policy ()
{
    local envdir="$1" file endpoint fallback first_err fallback_err policy has_restricted_rules=0;
    file="$envdir/environment-restore.json";
    endpoint="repos/$REPO/environments/$ENV_KEY";

    if [[ ! -s "$file" ]]; then
        best_effort "creating environment $ENV_NAME" api --method PUT "$endpoint" > /dev/null;
        return 0;
    fi;

    first_err="$envdir/environment-policy.err";
    if api --method PUT "$endpoint" --input "$file" > /dev/null 2> "$first_err"; then
        rm -f "$first_err";
        return 0;
    fi;

    # Older snapshots always included wait/reviewer fields, even when those
    # protection rules did not exist. Private repos on some GitHub plans reject
    # those optional fields. Retry with only the branch-policy portion so the
    # environment itself and deploy-branch behavior can still round-trip.
    fallback="$envdir/environment-policy-fallback.json";
    if grep -Eq '"protected_branches"[[:space:]]*:[[:space:]]*true' "$file"; then
        policy='{"protected_branches":true,"custom_branch_policies":false}';
    elif grep -Eq '"custom_branch_policies"[[:space:]]*:[[:space:]]*true' "$file"; then
        policy='{"protected_branches":false,"custom_branch_policies":true}';
    else
        policy='null';
    fi;
    printf '{"deployment_branch_policy":%s}\n' "$policy" > "$fallback";

    fallback_err="$envdir/environment-policy-fallback.err";
    if api --method PUT "$endpoint" --input "$fallback" > /dev/null 2> "$fallback_err"; then
        if [[ -f "$envdir/environment.json" ]]; then
            # Legacy backups kept the raw environment response. Prefer it when
            # present because old projected snapshots always included empty
            # wait/reviewer fields.
            if grep -Eq '"type"[[:space:]]*:[[:space:]]*"(wait_timer|required_reviewers)"' "$envdir/environment.json"; then
                has_restricted_rules=1;
            fi;
        elif grep -Eq '"wait_timer"[[:space:]]*:|"reviewers"[[:space:]]*:' "$file"; then
            # Current snapshots omit these keys unless the corresponding
            # protection rule actually existed.
            has_restricted_rules=1;
        fi;

        if (( has_restricted_rules )); then
            record_manual_item environment_policy "environment '$ENV_NAME' wait timer or required reviewers could not be restored automatically";
            warn "environment '$ENV_NAME' restored without wait timer/required-reviewer protection rules";
            if [[ -n "${BACKUP_DIR:-}" ]]; then
                {
                    printf '[environment policy %s: full policy rejected, fallback succeeded]\n' "$ENV_NAME";
                    cat "$first_err";
                    printf '\n';
                } >> "$BACKUP_DIR/restore-errors.log" 2>/dev/null || true;
            fi;
        else
            vlog "Environment '$ENV_NAME' restored via branch-policy-compatible fallback.";
        fi;
        rm -f "$first_err" "$fallback_err" "$fallback";
        return 0;
    fi;

    record_restore_failure "restoring environment policy $ENV_NAME";
    if [[ -n "${BACKUP_DIR:-}" ]]; then
        {
            printf '[restoring environment policy %s]\n' "$ENV_NAME";
            cat "$first_err";
            printf '[fallback]\n';
            cat "$fallback_err";
            printf '\n';
        } >> "$BACKUP_DIR/restore-errors.log" 2>/dev/null || true;
    fi;
    warn "restoring environment policy $ENV_NAME failed; continuing.";
    rm -f "$first_err" "$fallback_err" "$fallback";
    return 0
}

restore_environments () 
{ 
    local dir="$1" envdir file name;
    shopt -s nullglob;
    for envdir in "$dir"/environments/*;
    do
        [[ -f "$envdir/state.sh" ]] || continue;
        source "$envdir/state.sh";
        restore_environment_policy "$envdir";
        for file in "$envdir"/variables/*;
        do
            [[ -f "$file" ]] || continue;
            name="$(basename "$file")";
            best_effort "restoring environment variable $ENV_NAME/$name" gh variable set "$name" -R "$REPO" --env "$ENV_NAME" --body "$(cat "$file")";
        done;
    done;
    shopt -u nullglob
}

restore_environment_branch_policies () 
{ 
    local dir="$1" envdir p_name p_type;
    shopt -s nullglob;
    for envdir in "$dir"/environments/*;
    do
        [[ -f "$envdir/state.sh" ]] || continue;
        source "$envdir/state.sh";
        [[ -f "$envdir/deployment-branch-policies.tsv" ]] || continue;
        while IFS='	' read -r p_name p_type; do
            [[ -n "$p_name" ]] || continue;
            restore_once "environment-branch-policy:$ENV_KEY:$(urlencode "${p_type:-branch}"):$(urlencode "$p_name")" "restoring deployment policy $ENV_NAME/$p_name" api --method POST "repos/$REPO/environments/$ENV_KEY/deployment-branch-policies" -f "name=$p_name" -f "type=${p_type:-branch}";
        done < "$envdir/deployment-branch-policies.tsv";
    done;
    shopt -u nullglob
}

restore_environment_custom_protection_rules () 
{ 
    local dir="$1" envdir integration_id app_slug;
    shopt -s nullglob;
    for envdir in "$dir"/environments/*;
    do
        [[ -f "$envdir/state.sh" && -f "$envdir/custom-deployment-protection-rules.tsv" ]] || continue;
        source "$envdir/state.sh";
        while IFS='	' read -r integration_id app_slug; do
            [[ -n "$integration_id" ]] || continue;
            restore_once "environment-protection-rule:$ENV_KEY:$integration_id" "custom deployment protection rule ${app_slug:-$integration_id} for $ENV_NAME" api --method POST "repos/$REPO/environments/$ENV_KEY/deployment_protection_rules" -F "integration_id=$integration_id";
        done < "$envdir/custom-deployment-protection-rules.tsv";
    done;
    shopt -u nullglob
}

restore_actions_settings () 
{ 
    local dir="$1" a;
    a="$dir/actions";
    restore_json "restoring Actions repository permissions" PUT "repos/$REPO/actions/permissions" "$a/permissions.json";
    restore_json "restoring allowed Actions/reusable workflows" PUT "repos/$REPO/actions/permissions/selected-actions" "$a/selected-actions.json";
    restore_json "restoring default workflow permissions" PUT "repos/$REPO/actions/permissions/workflow" "$a/workflow-permissions.json";
    restore_json "restoring Actions access policy" PUT "repos/$REPO/actions/permissions/access" "$a/access.json";
    restore_json "restoring fork PR workflow policy" PUT "repos/$REPO/actions/permissions/fork-pr-workflows-private-repos" "$a/fork-pr-workflows.json";
    restore_json "restoring fork PR approval policy" PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" "$a/fork-pr-contributor-approval.json";
    restore_json "restoring Actions OIDC subject customization" PUT "repos/$REPO/actions/oidc/customization/sub" "$a/oidc-subject.json";
    restore_json "restoring Actions artifact/log retention" PUT "repos/$REPO/actions/permissions/artifact-and-log-retention" "$a/artifact-retention.json"
}

restore_actions_policies () 
{ 
    local dir="$1" pdir;
    shopt -s nullglob;
    for pdir in "$dir"/actions-policies/*;
    do
        [[ -s "$pdir/create.json" && -f "$pdir/state.sh" ]] || continue;
        source "$pdir/state.sh";
        restore_json_once "actions-policy:$OLD_ACTIONS_POLICY_ID" "restoring repository Actions policy" POST "repos/$REPO/actions/policies" "$pdir/create.json";
    done;
    shopt -u nullglob
}

restore_autolinks () 
{ 
    local dir="$1" adir key;
    shopt -s nullglob;
    for adir in "$dir"/autolinks/*;
    do
        [[ -s "$adir/create.json" ]] || continue;
        key="$(basename "$adir")";
        restore_json_once "autolink:$key" "restoring autolink reference" POST "repos/$REPO/autolinks" "$adir/create.json";
    done;
    shopt -u nullglob
}

restore_rulesets () 
{ 
    local dir="$1" rdir;
    shopt -s nullglob;
    for rdir in "$dir"/rulesets/*;
    do
        [[ -s "$rdir/create.json" && -f "$rdir/state.sh" ]] || continue;
        source "$rdir/state.sh";
        restore_json_once "ruleset:$OLD_RULESET_ID" "restoring repository ruleset" POST "repos/$REPO/rulesets" "$rdir/create.json";
    done;
    shopt -u nullglob
}

restore_branch_protection () 
{ 
    local dir="$1" bdir enc;
    source "$dir/repo-state.sh";
    shopt -s nullglob;
    for bdir in "$dir"/branch-protection/*;
    do
        [[ -f "$bdir/state.sh" ]] || continue;
        source "$bdir/state.sh";
        if [[ "$BRANCH_NAME" != "$DEFAULT_BRANCH" ]]; then
            warn "skipping protection for absent branch '$BRANCH_NAME'";
            continue;
        fi;
        enc="$(urlencode "$BRANCH_NAME")";
        restore_json "restoring branch protection for $BRANCH_NAME" PUT "repos/$REPO/branches/$enc/protection" "$bdir/protection.json";
        if [[ "$(bool "${REQUIRED_SIGNATURES:-false}")" == true ]]; then
            restore_once "required-signatures:$enc" "restoring required signatures for $BRANCH_NAME" api --method POST "repos/$REPO/branches/$enc/protection/required_signatures";
        fi;
    done;
    shopt -u nullglob
}

restore_custom_properties () 
{ 
    local dir="$1";
    restore_json "restoring custom property values" PATCH "repos/$REPO/properties/values" "$dir/custom-properties.json"
}

restore_archived_state () 
{ 
    local dir="$1";
    source "$dir/repo-state.sh";
    if [[ "$(bool "${ARCHIVED:-false}")" == true ]]; then
        best_effort "restoring archived state" gh repo archive "$REPO" --yes;
    fi
}
