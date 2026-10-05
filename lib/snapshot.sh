# Snapshot readable GitHub repository configuration before deletion.

save_repo_state () 
{ 
    local dir="$1" state owner;
    state="$dir/repo-state.sh";
    : > "$state";
    write_assignment "$state" SNAPSHOT_SCHEMA_VERSION 2;
    write_assignment "$state" REPO "$REPO";
    owner="${REPO%%/*}";
    write_assignment "$state" OWNER "$owner";
    write_assignment "$state" OWNER_TYPE "$(api "users/$owner" --jq '.type // "User"' 2> /dev/null || printf User)";
    write_assignment "$state" REPO_ID "$(repo_field '.id')";
    write_assignment "$state" DESCRIPTION "$(repo_field '.description // ""')";
    write_assignment "$state" HOMEPAGE "$(repo_field '.homepage // ""')";
    write_assignment "$state" VISIBILITY "$(repo_field '.visibility // (if .private then "private" else "public" end)')";
    write_assignment "$state" DEFAULT_BRANCH "$(repo_field '.default_branch // "main"')";
    write_assignment "$state" HAS_ISSUES "$(repo_field '.has_issues // false')";
    write_assignment "$state" HAS_PROJECTS "$(repo_field '.has_projects // false')";
    write_assignment "$state" HAS_WIKI "$(repo_field '.has_wiki // false')";
    write_assignment "$state" HAS_DISCUSSIONS "$(repo_field '.has_discussions // false')";
    write_assignment "$state" ALLOW_SQUASH "$(repo_field 'if .allow_squash_merge == null then true else .allow_squash_merge end')";
    write_assignment "$state" ALLOW_MERGE "$(repo_field 'if .allow_merge_commit == null then true else .allow_merge_commit end')";
    write_assignment "$state" ALLOW_REBASE "$(repo_field 'if .allow_rebase_merge == null then true else .allow_rebase_merge end')";
    write_assignment "$state" ALLOW_AUTO_MERGE "$(repo_field '.allow_auto_merge // false')";
    write_assignment "$state" DELETE_BRANCH_ON_MERGE "$(repo_field '.delete_branch_on_merge // false')";
    write_assignment "$state" ALLOW_UPDATE_BRANCH "$(repo_field '.allow_update_branch // false')";
    write_assignment "$state" ALLOW_FORKING "$(repo_field 'if .allow_forking == null then true else .allow_forking end')";
    write_assignment "$state" HAS_DOWNLOADS "$(repo_field 'if .has_downloads == null then true else .has_downloads end')";
    write_assignment "$state" HAS_PULL_REQUESTS "$(repo_field 'if .has_pull_requests == null then true else .has_pull_requests end')";
    write_assignment "$state" PULL_REQUEST_CREATION_POLICY "$(repo_field '.pull_request_creation_policy // ""')";
    write_assignment "$state" SQUASH_MERGE_COMMIT_TITLE "$(repo_field '.squash_merge_commit_title // ""')";
    write_assignment "$state" SQUASH_MERGE_COMMIT_MESSAGE "$(repo_field '.squash_merge_commit_message // ""')";
    write_assignment "$state" MERGE_COMMIT_TITLE "$(repo_field '.merge_commit_title // ""')";
    write_assignment "$state" MERGE_COMMIT_MESSAGE "$(repo_field '.merge_commit_message // ""')";
    write_assignment "$state" WEB_COMMIT_SIGNOFF "$(repo_field '.web_commit_signoff_required // false')";
    write_assignment "$state" IS_TEMPLATE "$(repo_field '.is_template // false')";
    write_assignment "$state" ARCHIVED "$(repo_field '.archived // false')";
    write_assignment "$state" IS_FORK "$(repo_field '.fork // false')";
    write_assignment "$state" STARGAZERS "$(repo_field '.stargazers_count // 0')";
    write_assignment "$state" FORKS "$(repo_field '.forks_count // 0')";
    write_assignment "$state" ADVANCED_SECURITY "$(repo_field '.security_and_analysis.advanced_security.status // "unknown"')";
    write_assignment "$state" CODE_SECURITY "$(repo_field '.security_and_analysis.code_security.status // "unknown"')";
    write_assignment "$state" SECRET_SCANNING "$(repo_field '.security_and_analysis.secret_scanning.status // "unknown"')";
    write_assignment "$state" PUSH_PROTECTION "$(repo_field '.security_and_analysis.secret_scanning_push_protection.status // "unknown"')";
    write_assignment "$state" SECRET_SCANNING_AI "$(repo_field '.security_and_analysis.secret_scanning_ai_detection.status // "unknown"')";
    write_assignment "$state" SECRET_SCANNING_NON_PROVIDER "$(repo_field '.security_and_analysis.secret_scanning_non_provider_patterns.status // "unknown"')";
    write_assignment "$state" SECRET_SCANNING_DELEGATED_DISMISSAL "$(repo_field '.security_and_analysis.secret_scanning_delegated_alert_dismissal.status // "unknown"')";
    write_assignment "$state" SECRET_SCANNING_DELEGATED_BYPASS "$(repo_field '.security_and_analysis.secret_scanning_delegated_bypass.status // "unknown"')";
    snapshot_json "$dir/secret-scanning-delegated-bypass-options.json" "repos/$REPO" 'if .security_and_analysis.secret_scanning_delegated_bypass_options == null then empty else {security_and_analysis:{secret_scanning_delegated_bypass_options:.security_and_analysis.secret_scanning_delegated_bypass_options}} end' || :;
    if api "repos/$REPO/vulnerability-alerts" > /dev/null 2>&1; then
        write_assignment "$state" VULNERABILITY_ALERTS enabled;
    else
        write_assignment "$state" VULNERABILITY_ALERTS unknown;
    fi;
    if api "repos/$REPO/automated-security-fixes" > /dev/null 2>&1; then
        write_assignment "$state" DEPENDABOT_SECURITY_UPDATES enabled;
    else
        write_assignment "$state" DEPENDABOT_SECURITY_UPDATES unknown;
    fi;
    write_assignment "$state" PRIVATE_VULNERABILITY_REPORTING "$(api "repos/$REPO/private-vulnerability-reporting" --jq 'if .enabled then "enabled" else "disabled" end' 2> /dev/null || printf unknown)";
    if api "repos/$REPO/immutable-releases" > /dev/null 2>&1; then
        write_assignment "$state" IMMUTABLE_RELEASES enabled;
    else
        write_assignment "$state" IMMUTABLE_RELEASES unknown;
    fi;
    api "repos/$REPO" > "$dir/repository.json";
    api "repos/$REPO/topics" --jq '.names[]?' > "$dir/topics.txt" || :
}

snapshot_labels () 
{ 
    local dir="$1" name idx=0 ldir;
    mkdir -p "$dir/labels";
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue;
        idx=$((idx+1));
        ldir="$dir/labels/$idx";
        mkdir -p "$ldir";
        : > "$ldir/state.sh";
        write_assignment "$ldir/state.sh" LABEL_NAME "$name";
        write_assignment "$ldir/state.sh" LABEL_COLOR "$(api "repos/$REPO/labels/$(urlencode "$name")" --jq '.color // "ededed"' 2> /dev/null || printf ededed)";
        write_assignment "$ldir/state.sh" LABEL_DESCRIPTION "$(api "repos/$REPO/labels/$(urlencode "$name")" --jq '.description // ""' 2> /dev/null || true)";
    done < <(api --paginate "repos/$REPO/labels?per_page=100" --jq '.[].name' 2> /dev/null || true)
}

snapshot_deploy_keys () 
{ 
    local dir="$1" id n=0 keydir title readonly key;
    mkdir -p "$dir/deploy-keys";
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue;
        n=$((n+1));
        keydir="$dir/deploy-keys/$n";
        mkdir -p "$keydir";
        title="$(api "repos/$REPO/keys/$id" --jq '.title // ""')";
        readonly="$(api "repos/$REPO/keys/$id" --jq 'if .read_only == null then true else .read_only end')";
        key="$(api "repos/$REPO/keys/$id" --jq '.key // ""')";
        : > "$keydir/state.sh";
        write_assignment "$keydir/state.sh" TITLE "$title";
        write_assignment "$keydir/state.sh" READ_ONLY "$readonly";
        printf '%s\n' "$key" > "$keydir/key.pub";
    done < <(gh repo deploy-key list -R "$REPO" --json id --jq '.[].id' 2> /dev/null || true)
}

snapshot_variables () 
{ 
    local dir="$1" name;
    mkdir -p "$dir/variables/repository";
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue;
        gh variable get "$name" -R "$REPO" --json value --jq '.value' > "$dir/variables/repository/$name" || true;
    done < <(gh variable list -R "$REPO" --json name --jq '.[].name' 2> /dev/null || true)
}

snapshot_secrets () 
{ 
    local dir="$1" app;
    mkdir -p "$dir/secrets";
    for app in actions agents codespaces dependabot;
    do
        gh secret list -R "$REPO" --app "$app" --json name,updatedAt > "$dir/secrets/$app.json" 2> /dev/null || :;
        gh secret list -R "$REPO" --app "$app" --json name --jq '.[].name' > "$dir/secrets/$app.names" 2> /dev/null || :;
    done
}

snapshot_environments () 
{ 
    local dir="$1" env idx=0 envdir name encoded;
    mkdir -p "$dir/environments";
    while IFS= read -r env; do
        [[ -n "$env" ]] || continue;
        idx=$((idx+1));
        envdir="$dir/environments/$idx";
        mkdir -p "$envdir/variables";
        encoded="$(urlencode "$env")";
        : > "$envdir/state.sh";
        write_assignment "$envdir/state.sh" ENV_NAME "$env";
        write_assignment "$envdir/state.sh" ENV_KEY "$encoded";
        snapshot_json "$envdir/environment-restore.json" "repos/$REPO/environments/$encoded" '{wait_timer:([.protection_rules[]? | select(.type=="wait_timer") | .wait_timer][0] // 0),prevent_self_review:([.protection_rules[]? | select(.type=="required_reviewers") | .prevent_self_review][0] // false),reviewers:([.protection_rules[]? | select(.type=="required_reviewers") | .reviewers[]? | {type:.type,id:.reviewer.id}]),deployment_branch_policy:(.deployment_branch_policy // null)}' || :;
        api "repos/$REPO/environments/$encoded" > "$envdir/environment.json" 2> /dev/null || :;
        api --paginate "repos/$REPO/environments/$encoded/deployment_protection_rules?per_page=100" --jq '.custom_deployment_protection_rules[]? | [.app.id, (.app.slug // "")] | @tsv' > "$envdir/custom-deployment-protection-rules.tsv" 2> /dev/null || :;
        snapshot_json "$envdir/deployment-branch-policies.json" "repos/$REPO/environments/$encoded/deployment-branch-policies?per_page=100" '{branch_policies:(.branch_policies // [] | map({name,type:(.type // "branch")}))}' || :;
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue;
            gh variable get "$name" -R "$REPO" --env "$env" --json value --jq '.value' > "$envdir/variables/$name" || true;
        done < <(gh variable list -R "$REPO" --env "$env" --json name --jq '.[].name' 2> /dev/null || true);
        gh secret list -R "$REPO" --env "$env" --app actions --json name,updatedAt > "$envdir/actions-secrets.json" 2> /dev/null || :;
        gh secret list -R "$REPO" --env "$env" --app actions --json name --jq '.[].name' > "$envdir/actions-secret-names.txt" 2> /dev/null || :;
    done < <(api --paginate "repos/$REPO/environments?per_page=100" --jq '.environments[].name' 2> /dev/null || true)
}

snapshot_actions_settings () 
{ 
    local dir="$1" a;
    a="$dir/actions";
    mkdir -p "$a";
    snapshot_json "$a/permissions.json" "repos/$REPO/actions/permissions" '{enabled,allowed_actions,sha_pinning_required:(.sha_pinning_required // false)}' || :;
    snapshot_json "$a/selected-actions.json" "repos/$REPO/actions/permissions/selected-actions" '{github_owned_allowed,verified_allowed,patterns_allowed:(.patterns_allowed // [])}' || :;
    snapshot_json "$a/workflow-permissions.json" "repos/$REPO/actions/permissions/workflow" '{default_workflow_permissions,can_approve_pull_request_reviews}' || :;
    snapshot_json "$a/access.json" "repos/$REPO/actions/permissions/access" '{access_level}' || :;
    snapshot_json "$a/fork-pr-workflows.json" "repos/$REPO/actions/permissions/fork-pr-workflows-private-repos" '{run_workflows_from_fork_pull_requests,send_write_tokens_to_workflows,send_secrets_and_variables,require_approval_for_fork_pr_workflows}' || :;
    snapshot_json "$a/fork-pr-contributor-approval.json" "repos/$REPO/actions/permissions/fork-pr-contributor-approval" '{approval_policy}' || :;
    snapshot_json "$a/oidc-subject.json" "repos/$REPO/actions/oidc/customization/sub" '{use_default,include_claim_keys:(.include_claim_keys // []),use_immutable_subject:(.use_immutable_subject // false)}' || :;
    snapshot_json "$a/artifact-retention.json" "repos/$REPO/actions/permissions/artifact-and-log-retention" '{days}' || :;
    snapshot_api "$a/runners.json" "repos/$REPO/actions/runners?per_page=100"
}

snapshot_actions_policies () 
{ 
    local dir="$1" id idx=0 pdir;
    mkdir -p "$dir/actions-policies";
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue;
        idx=$((idx+1));
        pdir="$dir/actions-policies/$idx";
        mkdir -p "$pdir";
        write_assignment "$pdir/state.sh" OLD_ACTIONS_POLICY_ID "$id";
        snapshot_json "$pdir/create.json" "repos/$REPO/actions/policies/$id" '{name,enforcement,conditions:(.conditions // {}),rules:(.rules // [])}' || :;
    done < <(api --paginate "repos/$REPO/actions/policies?has_parents=false&per_page=100" --jq '.policies[]? | select(.source_type=="Repository") | .id' 2> /dev/null || true)
}

snapshot_autolinks () 
{ 
    local dir="$1" id idx=0 adir;
    mkdir -p "$dir/autolinks";
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue;
        idx=$((idx+1));
        adir="$dir/autolinks/$idx";
        mkdir -p "$adir";
        snapshot_json "$adir/create.json" "repos/$REPO/autolinks/$id" '{key_prefix,url_template,is_alphanumeric}' || :;
    done < <(api --paginate "repos/$REPO/autolinks?per_page=100" --jq '.[].id' 2> /dev/null || true)
}

snapshot_rulesets () 
{ 
    local dir="$1" id idx=0 rdir;
    mkdir -p "$dir/rulesets";
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue;
        idx=$((idx+1));
        rdir="$dir/rulesets/$idx";
        mkdir -p "$rdir";
        write_assignment "$rdir/state.sh" OLD_RULESET_ID "$id";
        snapshot_json "$rdir/create.json" "repos/$REPO/rulesets/$id" '{name,target,enforcement,bypass_actors:(.bypass_actors // [] | map({actor_id,actor_type,bypass_mode})),conditions,rules}' || :;
    done < <(api --paginate "repos/$REPO/rulesets?includes_parents=false&per_page=100" --jq '.[] | select(.source_type=="Repository") | .id' 2> /dev/null || true)
}

snapshot_branch_protection () 
{ 
    local dir="$1" branch idx=0 bdir enc sig;
    mkdir -p "$dir/branch-protection";
    while IFS= read -r branch; do
        [[ -n "$branch" ]] || continue;
        idx=$((idx+1));
        bdir="$dir/branch-protection/$idx";
        mkdir -p "$bdir";
        enc="$(urlencode "$branch")";
        : > "$bdir/state.sh";
        write_assignment "$bdir/state.sh" BRANCH_NAME "$branch";
        snapshot_json "$bdir/protection.json" "repos/$REPO/branches/$enc/protection" '{required_status_checks:(if .required_status_checks==null then null else {strict:(.required_status_checks.strict // false),contexts:(.required_status_checks.contexts // []),checks:(.required_status_checks.checks // [] | map({context,app_id}))} end),enforce_admins:(.enforce_admins.enabled // false),required_pull_request_reviews:(if .required_pull_request_reviews==null then null else ({dismiss_stale_reviews:(.required_pull_request_reviews.dismiss_stale_reviews // false),require_code_owner_reviews:(.required_pull_request_reviews.require_code_owner_reviews // false),required_approving_review_count:(.required_pull_request_reviews.required_approving_review_count // 0),require_last_push_approval:(.required_pull_request_reviews.require_last_push_approval // false)} + (if .required_pull_request_reviews.dismissal_restrictions==null then {} else {dismissal_restrictions:{users:(.required_pull_request_reviews.dismissal_restrictions.users // [] | map(.login)),teams:(.required_pull_request_reviews.dismissal_restrictions.teams // [] | map(.slug)),apps:(.required_pull_request_reviews.dismissal_restrictions.apps // [] | map(.slug))}} end) + (if .required_pull_request_reviews.bypass_pull_request_allowances==null then {} else {bypass_pull_request_allowances:{users:(.required_pull_request_reviews.bypass_pull_request_allowances.users // [] | map(.login)),teams:(.required_pull_request_reviews.bypass_pull_request_allowances.teams // [] | map(.slug)),apps:(.required_pull_request_reviews.bypass_pull_request_allowances.apps // [] | map(.slug))}} end)) end),restrictions:(if .restrictions==null then null else {users:(.restrictions.users // [] | map(.login)),teams:(.restrictions.teams // [] | map(.slug)),apps:(.restrictions.apps // [] | map(.slug))} end),required_linear_history:(.required_linear_history.enabled // false),allow_force_pushes:(.allow_force_pushes.enabled // false),allow_deletions:(.allow_deletions.enabled // false),block_creations:(.block_creations.enabled // false),required_conversation_resolution:(.required_conversation_resolution.enabled // false),lock_branch:(.lock_branch.enabled // false),allow_fork_syncing:(.allow_fork_syncing.enabled // false)}' || :;
        sig="$(api "repos/$REPO/branches/$enc/protection/required_signatures" --jq '.enabled // false' 2> /dev/null || printf false)";
        write_assignment "$bdir/state.sh" REQUIRED_SIGNATURES "$sig";
    done < <(api --paginate "repos/$REPO/branches?protected=true&per_page=100" --jq '.[].name' 2> /dev/null || true)
}

snapshot_access () 
{ 
    local dir="$1";
    mkdir -p "$dir/access";
    api --paginate "repos/$REPO/collaborators?affiliation=direct&per_page=100" --jq '.[] | [.login, (.role_name // "")] | @tsv' > "$dir/access/collaborators.tsv" 2> /dev/null || :;
    api --paginate "repos/$REPO/invitations?per_page=100" --jq '.[] | [(.invitee.login // ""), (.permissions // "pull")] | @tsv' > "$dir/access/invitations.tsv" 2> /dev/null || :;
    api --paginate "repos/$REPO/teams?per_page=100" --jq '.[] | [(.organization.login // ""), .slug, (.permission // "pull")] | @tsv' > "$dir/access/teams.tsv" 2> /dev/null || :
}

snapshot_app_installations () 
{ 
    local dir="$1" installation_id selection slug;
    source "$dir/repo-state.sh";
    mkdir -p "$dir/app-installations";
    : > "$dir/app-installations/selected.tsv";
    while IFS='	' read -r installation_id selection slug; do
        [[ -n "$installation_id" && "$selection" == selected ]] || continue;
        if api --paginate "user/installations/$installation_id/repositories?per_page=100" --jq '.repositories[]?.id' 2> /dev/null | grep -Fxq "$REPO_ID"; then
            printf '%s\t%s\n' "$installation_id" "$slug" >> "$dir/app-installations/selected.tsv";
        fi;
    done < <(api --paginate "user/installations?per_page=100" --jq '.installations[]? | [.id, .repository_selection, (.app_slug // "")] | @tsv' 2> /dev/null || true)
}

snapshot_org_bindings () 
{ 
    local dir="$1" name group_id config_id enabled;
    source "$dir/repo-state.sh";
    [[ "${OWNER_TYPE:-User}" == Organization ]] || return 0;
    mkdir -p "$dir/org-bindings";
    : > "$dir/org-bindings/actions-secrets.txt";
    : > "$dir/org-bindings/dependabot-secrets.txt";
    : > "$dir/org-bindings/codespaces-secrets.txt";
    : > "$dir/org-bindings/actions-variables.txt";
    : > "$dir/org-bindings/runner-groups.txt";
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue;
        if api --paginate "orgs/$OWNER/actions/secrets/$(urlencode "$name")/repositories?per_page=100" --jq '.repositories[]?.id' 2> /dev/null | grep -Fxq "$REPO_ID"; then
            printf '%s\n' "$name" >> "$dir/org-bindings/actions-secrets.txt";
        fi;
    done < <(api --paginate "orgs/$OWNER/actions/secrets?per_page=100" --jq '.secrets[]? | select(.visibility=="selected") | .name' 2> /dev/null || true);
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue;
        if api --paginate "orgs/$OWNER/dependabot/secrets/$(urlencode "$name")/repositories?per_page=100" --jq '.repositories[]?.id' 2> /dev/null | grep -Fxq "$REPO_ID"; then
            printf '%s\n' "$name" >> "$dir/org-bindings/dependabot-secrets.txt";
        fi;
    done < <(api --paginate "orgs/$OWNER/dependabot/secrets?per_page=100" --jq '.secrets[]? | select(.visibility=="selected") | .name' 2> /dev/null || true);
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue;
        if api --paginate "orgs/$OWNER/codespaces/secrets/$(urlencode "$name")/repositories?per_page=100" --jq '.repositories[]?.id' 2> /dev/null | grep -Fxq "$REPO_ID"; then
            printf '%s\n' "$name" >> "$dir/org-bindings/codespaces-secrets.txt";
        fi;
    done < <(api --paginate "orgs/$OWNER/codespaces/secrets?per_page=100" --jq '.secrets[]? | select(.visibility=="selected") | .name' 2> /dev/null || true);
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue;
        if api --paginate "orgs/$OWNER/actions/variables/$(urlencode "$name")/repositories?per_page=100" --jq '.repositories[]?.id' 2> /dev/null | grep -Fxq "$REPO_ID"; then
            printf '%s\n' "$name" >> "$dir/org-bindings/actions-variables.txt";
        fi;
    done < <(api --paginate "orgs/$OWNER/actions/variables?per_page=100" --jq '.variables[]? | select(.visibility=="selected") | .name' 2> /dev/null || true);
    enabled="$(api "orgs/$OWNER/actions/permissions" --jq '.enabled_repositories // ""' 2> /dev/null || true)";
    if [[ "$enabled" == selected ]] && api --paginate "orgs/$OWNER/actions/permissions/repositories?per_page=100" --jq '.repositories[]?.id' 2> /dev/null | grep -Fxq "$REPO_ID"; then
        : > "$dir/org-bindings/actions-enabled-selected";
    fi;
    while IFS= read -r group_id; do
        [[ -n "$group_id" ]] || continue;
        if api --paginate "orgs/$OWNER/actions/runner-groups/$group_id/repositories?per_page=100" --jq '.repositories[]?.id' 2> /dev/null | grep -Fxq "$REPO_ID"; then
            printf '%s\n' "$group_id" >> "$dir/org-bindings/runner-groups.txt";
        fi;
    done < <(api --paginate "orgs/$OWNER/actions/runner-groups?per_page=100" --jq '.runner_groups[]? | select(.visibility=="selected") | .id' 2> /dev/null || true);
    config_id="$(api "repos/$REPO/code-security-configuration" --jq 'select(.status=="attached") | .configuration.id // empty' 2> /dev/null || true)";
    if [[ -n "$config_id" ]]; then
        printf '%s\n' "$config_id" > "$dir/org-bindings/code-security-configuration-id";
    fi;
    return 0
}

snapshot_custom_properties () 
{ 
    local dir="$1";
    snapshot_json "$dir/custom-properties.json" "repos/$REPO/properties/values" '{properties:.}' || :
}

snapshot_pages () 
{ 
    local dir="$1" file;
    file="$dir/pages-state.sh";
    if ! api "repos/$REPO/pages" > /dev/null 2>&1; then
        return 0;
    fi;
    : > "$file";
    write_assignment "$file" PAGES_PRESENT true;
    write_assignment "$file" PAGES_BUILD_TYPE "$(api "repos/$REPO/pages" --jq '.build_type // "legacy"')";
    write_assignment "$file" PAGES_SOURCE_BRANCH "$(api "repos/$REPO/pages" --jq '.source.branch // ""')";
    write_assignment "$file" PAGES_SOURCE_PATH "$(api "repos/$REPO/pages" --jq '.source.path // "/"')";
    write_assignment "$file" PAGES_CNAME "$(api "repos/$REPO/pages" --jq '.cname // ""')";
    write_assignment "$file" PAGES_HTTPS "$(api "repos/$REPO/pages" --jq '.https_enforced // false')";
    api "repos/$REPO/pages" > "$dir/pages.json" || :
}

snapshot_webhooks () 
{ 
    local dir="$1" id idx=0 hdir secret_status;
    mkdir -p "$dir/webhooks";
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue;
        idx=$((idx+1));
        hdir="$dir/webhooks/$idx";
        mkdir -p "$hdir";
        : > "$hdir/state.sh";
        write_assignment "$hdir/state.sh" OLD_HOOK_ID "$id";
        snapshot_json "$hdir/create.json" "repos/$REPO/hooks/$id" '{name,active,events,config:{url:.config.url,content_type:(.config.content_type // "json"),insecure_ssl:(.config.insecure_ssl // "0")}}' || :;
        secret_status="$(api "repos/$REPO/hooks/$id/config" --jq 'if (.secret // "") == "" then "unsigned" else "signed" end' 2> /dev/null || printf unknown)";
        write_assignment "$hdir/state.sh" HOOK_SECRET_STATUS "$secret_status";
    done < <(api --paginate "repos/$REPO/hooks?per_page=100" --jq '.[].id' 2> /dev/null || true)
}
