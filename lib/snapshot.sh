# Snapshot readable GitHub repository configuration before deletion.

save_repo_state () 
{ 
    local dir="$1" state owner;
    state="$dir/repo-state.sh";
    : > "$state";
    write_assignment "$state" SNAPSHOT_SCHEMA_VERSION 3;
    write_assignment "$state" REPO "$REPO";
    owner="${REPO%%/*}";
    write_assignment "$state" OWNER "$owner";

    # Keep a raw copy for audit/recovery, but extract all top-level settings in
    # one additional request instead of issuing one request per field.
    api "repos/$REPO" > "$dir/repository.json";
    api "repos/$REPO" --jq '
      def assign($k; $v): "\($k)=\((($v | tostring) | @sh))";
      [
        assign("OWNER_TYPE"; (.owner.type // "User")),
        assign("REPO_ID"; .id),
        assign("DESCRIPTION"; (.description // "")),
        assign("HOMEPAGE"; (.homepage // "")),
        assign("VISIBILITY"; (.visibility // (if .private then "private" else "public" end))),
        assign("DEFAULT_BRANCH"; (.default_branch // "main")),
        assign("HAS_ISSUES"; (.has_issues // false)),
        assign("HAS_PROJECTS"; (.has_projects // false)),
        assign("HAS_WIKI"; (.has_wiki // false)),
        assign("HAS_DISCUSSIONS"; (.has_discussions // false)),
        assign("ALLOW_SQUASH"; (if .allow_squash_merge == null then true else .allow_squash_merge end)),
        assign("ALLOW_MERGE"; (if .allow_merge_commit == null then true else .allow_merge_commit end)),
        assign("ALLOW_REBASE"; (if .allow_rebase_merge == null then true else .allow_rebase_merge end)),
        assign("ALLOW_AUTO_MERGE"; (.allow_auto_merge // false)),
        assign("DELETE_BRANCH_ON_MERGE"; (.delete_branch_on_merge // false)),
        assign("ALLOW_UPDATE_BRANCH"; (.allow_update_branch // false)),
        assign("ALLOW_FORKING"; (if .allow_forking == null then true else .allow_forking end)),
        assign("HAS_DOWNLOADS"; (if .has_downloads == null then true else .has_downloads end)),
        assign("HAS_PULL_REQUESTS"; (if .has_pull_requests == null then true else .has_pull_requests end)),
        assign("PULL_REQUEST_CREATION_POLICY"; (.pull_request_creation_policy // "")),
        assign("SQUASH_MERGE_COMMIT_TITLE"; (.squash_merge_commit_title // "")),
        assign("SQUASH_MERGE_COMMIT_MESSAGE"; (.squash_merge_commit_message // "")),
        assign("MERGE_COMMIT_TITLE"; (.merge_commit_title // "")),
        assign("MERGE_COMMIT_MESSAGE"; (.merge_commit_message // "")),
        assign("WEB_COMMIT_SIGNOFF"; (.web_commit_signoff_required // false)),
        assign("IS_TEMPLATE"; (.is_template // false)),
        assign("ARCHIVED"; (.archived // false)),
        assign("IS_FORK"; (.fork // false)),
        assign("STARGAZERS"; (.stargazers_count // 0)),
        assign("FORKS"; (.forks_count // 0)),
        assign("ADVANCED_SECURITY"; (.security_and_analysis.advanced_security.status // "unknown")),
        assign("CODE_SECURITY"; (.security_and_analysis.code_security.status // "unknown")),
        assign("SECRET_SCANNING"; (.security_and_analysis.secret_scanning.status // "unknown")),
        assign("PUSH_PROTECTION"; (.security_and_analysis.secret_scanning_push_protection.status // "unknown")),
        assign("SECRET_SCANNING_AI"; (.security_and_analysis.secret_scanning_ai_detection.status // "unknown")),
        assign("SECRET_SCANNING_NON_PROVIDER"; (.security_and_analysis.secret_scanning_non_provider_patterns.status // "unknown")),
        assign("SECRET_SCANNING_DELEGATED_DISMISSAL"; (.security_and_analysis.secret_scanning_delegated_alert_dismissal.status // "unknown")),
        assign("SECRET_SCANNING_DELEGATED_BYPASS"; (.security_and_analysis.secret_scanning_delegated_bypass.status // "unknown"))
      ] | .[]
    ' >> "$state";

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
    snapshot_capture "$dir/topics.txt" "repository topics" api "repos/$REPO/topics" --jq '.names[]?'
}

snapshot_labels () 
{ 
    local dir="$1" raw_name raw_color raw_description name color description idx=0 ldir;
    mkdir -p "$dir/labels";
    while IFS=$'\t' read -r raw_name raw_color raw_description; do
        [[ -n "$raw_name" ]] || continue;
        name="$(tsv_decode "$raw_name")";
        color="$(tsv_decode "$raw_color")";
        description="$(tsv_decode "$raw_description")";
        idx=$((idx+1));
        ldir="$dir/labels/$idx";
        mkdir -p "$ldir";
        : > "$ldir/state.sh";
        write_assignment "$ldir/state.sh" LABEL_NAME "$name";
        write_assignment "$ldir/state.sh" LABEL_COLOR "${color:-ededed}";
        write_assignment "$ldir/state.sh" LABEL_DESCRIPTION "$description";
    done < <(
        snapshot_stream "labels" gh label list -R "$REPO" --limit 1000 --json name,color,description \
          --jq '.[] | [.name, .color, (.description // "")] | @tsv'
    )
}

snapshot_deploy_keys () 
{ 
    local dir="$1" raw_title raw_key raw_readonly title key readonly n=0 keydir;
    mkdir -p "$dir/deploy-keys";
    while IFS=$'\t' read -r raw_title raw_key raw_readonly; do
        [[ -n "$raw_key" ]] || continue;
        title="$(tsv_decode "$raw_title")";
        key="$(tsv_decode "$raw_key")";
        readonly="$(tsv_decode "$raw_readonly")";
        n=$((n+1));
        keydir="$dir/deploy-keys/$n";
        mkdir -p "$keydir";
        : > "$keydir/state.sh";
        write_assignment "$keydir/state.sh" TITLE "$title";
        write_assignment "$keydir/state.sh" READ_ONLY "$readonly";
        printf '%s\n' "$key" > "$keydir/key.pub";
    done < <(
        snapshot_stream "deploy keys" gh repo deploy-key list -R "$REPO" --json title,key,readOnly \
          --jq '.[] | [.title, .key, (.readOnly|tostring)] | @tsv'
    )
}

snapshot_variables () 
{ 
    local dir="$1" raw_name raw_value name value;
    mkdir -p "$dir/variables/repository";
    while IFS=$'\t' read -r raw_name raw_value; do
        [[ -n "$raw_name" ]] || continue;
        name="$(tsv_decode "$raw_name")";
        value="$(tsv_decode "$raw_value")";
        printf '%s' "$value" > "$dir/variables/repository/$name";
    done < <(
        snapshot_stream "repository variables" gh variable list -R "$REPO" --json name,value \
          --jq '.[] | [.name, .value] | @tsv'
    )
}

snapshot_secrets () 
{ 
    local dir="$1" app raw_name raw_updated name updated;
    mkdir -p "$dir/secrets";
    for app in actions agents codespaces dependabot; do
        : > "$dir/secrets/$app.names";
        : > "$dir/secrets/$app.tsv";
        while IFS=$'\t' read -r raw_name raw_updated; do
            [[ -n "$raw_name" ]] || continue;
            name="$(tsv_decode "$raw_name")";
            updated="$(tsv_decode "$raw_updated")";
            printf '%s\n' "$name" >> "$dir/secrets/$app.names";
            printf '%s\t%s\n' "$name" "$updated" >> "$dir/secrets/$app.tsv";
        done < <(
            snapshot_stream "repository $app secret metadata" gh secret list -R "$REPO" --app "$app" --json name,updatedAt \
              --jq '.[] | [.name, (.updatedAt // "")] | @tsv'
        );
    done
}

snapshot_environments () 
{ 
    local dir="$1" env idx=0 envdir name encoded;
    local raw_name raw_value value raw_secret_name raw_secret_updated secret_name secret_updated;
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

        snapshot_json_required "$envdir/environment-restore.json" "repos/$REPO/environments/$encoded" '(.protection_rules // []) as $rules | ([$rules[]? | select(.type=="wait_timer")][0]) as $wait | ([$rules[]? | select(.type=="required_reviewers")][0]) as $review | ({deployment_branch_policy:(.deployment_branch_policy // null)} + (if $wait == null then {} else {wait_timer:($wait.wait_timer // 0)} end) + (if $review == null then {} else {prevent_self_review:($review.prevent_self_review // false),reviewers:([$review.reviewers[]? | {type:.type,id:.reviewer.id}])} end))';
        snapshot_capture "$envdir/environment.json" "environment $env" api "repos/$REPO/environments/$encoded";
        snapshot_capture "$envdir/custom-deployment-protection-rules.tsv" "environment $env custom deployment protection rules" api --paginate "repos/$REPO/environments/$encoded/deployment_protection_rules?per_page=100" --jq '.custom_deployment_protection_rules[]? | [.app.id, (.app.slug // "")] | @tsv';
        snapshot_capture "$envdir/deployment-branch-policies.tsv" "environment $env deployment branch policies" api "repos/$REPO/environments/$encoded/deployment-branch-policies?per_page=100" \
          --jq '.branch_policies[]? | [.name, (.type // "branch")] | @tsv';

        while IFS=$'\t' read -r raw_name raw_value; do
            [[ -n "$raw_name" ]] || continue;
            name="$(tsv_decode "$raw_name")";
            value="$(tsv_decode "$raw_value")";
            printf '%s' "$value" > "$envdir/variables/$name";
        done < <(
            snapshot_stream "environment $env variables" gh variable list -R "$REPO" --env "$env" --json name,value \
              --jq '.[] | [.name, .value] | @tsv'
        );

        : > "$envdir/actions-secret-names.txt";
        : > "$envdir/actions-secrets.tsv";
        while IFS=$'\t' read -r raw_secret_name raw_secret_updated; do
            [[ -n "$raw_secret_name" ]] || continue;
            secret_name="$(tsv_decode "$raw_secret_name")";
            secret_updated="$(tsv_decode "$raw_secret_updated")";
            printf '%s\n' "$secret_name" >> "$envdir/actions-secret-names.txt";
            printf '%s\t%s\n' "$secret_name" "$secret_updated" >> "$envdir/actions-secrets.tsv";
        done < <(
            snapshot_stream "environment $env Actions secret metadata" gh secret list -R "$REPO" --env "$env" --app actions --json name,updatedAt \
              --jq '.[] | [.name, (.updatedAt // "")] | @tsv'
        );
    done < <(
        snapshot_stream "environments" api --paginate "repos/$REPO/environments?per_page=100" --jq '.environments[].name'
    )
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
    local dir="$1" payload idx=0 adir;
    mkdir -p "$dir/autolinks";
    while IFS= read -r payload; do
        [[ -n "$payload" ]] || continue;
        idx=$((idx+1));
        adir="$dir/autolinks/$idx";
        mkdir -p "$adir";
        printf '%s\n' "$payload" > "$adir/create.json";
    done < <(
        gh repo autolink list -R "$REPO" --json keyPrefix,urlTemplate,isAlphanumeric \
          --jq '.[] | {key_prefix:.keyPrefix,url_template:.urlTemplate,is_alphanumeric:.isAlphanumeric} | @json' \
          2> /dev/null || true
    )
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
    if ! api "repos/$REPO/pages" > "$dir/pages.json" 2> /dev/null; then
        rm -f "$dir/pages.json";
        return 0;
    fi;
    : > "$file";
    write_assignment "$file" PAGES_PRESENT true;
    api "repos/$REPO/pages" --jq '
      def assign($k; $v): "\($k)=\((($v | tostring) | @sh))";
      [
        assign("PAGES_BUILD_TYPE"; (.build_type // "legacy")),
        assign("PAGES_SOURCE_BRANCH"; (.source.branch // "")),
        assign("PAGES_SOURCE_PATH"; (.source.path // "/")),
        assign("PAGES_CNAME"; (.cname // "")),
        assign("PAGES_HTTPS"; (.https_enforced // false))
      ] | .[]
    ' >> "$file"
}

snapshot_webhooks () 
{ 
    local dir="$1" raw_id raw_payload id payload idx=0 hdir secret_status;
    mkdir -p "$dir/webhooks";
    while IFS=$'\t' read -r raw_id raw_payload; do
        [[ -n "$raw_id" ]] || continue;
        id="$(tsv_decode "$raw_id")";
        payload="$(tsv_decode "$raw_payload")";
        idx=$((idx+1));
        hdir="$dir/webhooks/$idx";
        mkdir -p "$hdir";
        : > "$hdir/state.sh";
        write_assignment "$hdir/state.sh" OLD_HOOK_ID "$id";
        printf '%s\n' "$payload" > "$hdir/create.json";
        secret_status="$(api "repos/$REPO/hooks/$id/config" --jq 'if (.secret // "") == "" then "unsigned" else "signed" end' 2> /dev/null || printf unknown)";
        write_assignment "$hdir/state.sh" HOOK_SECRET_STATUS "$secret_status";
    done < <(
        api --paginate "repos/$REPO/hooks?per_page=100" \
          --jq '.[] | [.id, ({name,active,events,config:{url:.config.url,content_type:(.config.content_type // "json"),insecure_ssl:(.config.insecure_ssl // "0")}} | tojson)] | @tsv' \
          2> /dev/null || true
    )
}
