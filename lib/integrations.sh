# Restore access and identity-bound integrations where GitHub APIs allow it.

normalize_permission () 
{ 
    case "$1" in 
        read)
            printf pull
        ;;
        write)
            printf push
        ;;
        "")
            printf pull
        ;;
        *)
            printf '%s' "$1"
        ;;
    esac
}

restore_access () 
{ 
    local dir="$1" login permission org slug;
    while IFS='	' read -r login permission; do
        [[ -n "$login" ]] || continue;
        permission="$(normalize_permission "$permission")";
        best_effort "restoring collaborator $login" api --method PUT "repos/$REPO/collaborators/$(urlencode "$login")" -f "permission=$permission" > /dev/null;
    done < "$dir/access/collaborators.tsv";
    while IFS='	' read -r login permission; do
        [[ -n "$login" ]] || continue;
        permission="$(normalize_permission "$permission")";
        best_effort "restoring pending invitation for $login" api --method PUT "repos/$REPO/collaborators/$(urlencode "$login")" -f "permission=$permission" > /dev/null;
    done < "$dir/access/invitations.tsv";
    while IFS='	' read -r org slug permission; do
        [[ -n "$org" && -n "$slug" ]] || continue;
        permission="$(normalize_permission "$permission")";
        best_effort "restoring team access $org/$slug" api --method PUT "orgs/$(urlencode "$org")/teams/$(urlencode "$slug")/repos/$REPO" -f "permission=$permission" > /dev/null;
    done < "$dir/access/teams.tsv"
}

restore_app_installations () 
{ 
    local dir="$1" installation_id slug new_repo_id;
    [[ -f "$dir/app-installations/selected.tsv" ]] || return 0;
    new_repo_id="$(repo_field '.id')";
    while IFS='	' read -r installation_id slug; do
        [[ -n "$installation_id" ]] || continue;
        best_effort "restoring GitHub App repository access${slug:+ ($slug)}" api --method PUT "user/installations/$installation_id/repositories/$new_repo_id" > /dev/null;
    done < "$dir/app-installations/selected.tsv"
}

restore_org_bindings () 
{ 
    local dir="$1" name group_id config_id new_repo_id payload;
    source "$dir/repo-state.sh";
    [[ "${OWNER_TYPE:-User}" == Organization && -d "$dir/org-bindings" ]] || return 0;
    new_repo_id="$(repo_field '.id')";
    while IFS= read -r name; do
        [[ -n "$name" ]] && best_effort "restoring org Actions secret access: $name" api --method PUT "orgs/$OWNER/actions/secrets/$(urlencode "$name")/repositories/$new_repo_id" > /dev/null;
    done < "$dir/org-bindings/actions-secrets.txt";
    while IFS= read -r name; do
        [[ -n "$name" ]] && best_effort "restoring org Dependabot secret access: $name" api --method PUT "orgs/$OWNER/dependabot/secrets/$(urlencode "$name")/repositories/$new_repo_id" > /dev/null;
    done < "$dir/org-bindings/dependabot-secrets.txt";
    while IFS= read -r name; do
        [[ -n "$name" ]] && best_effort "restoring org Codespaces secret access: $name" api --method PUT "orgs/$OWNER/codespaces/secrets/$(urlencode "$name")/repositories/$new_repo_id" > /dev/null;
    done < "$dir/org-bindings/codespaces-secrets.txt";
    while IFS= read -r name; do
        [[ -n "$name" ]] && best_effort "restoring org Actions variable access: $name" api --method PUT "orgs/$OWNER/actions/variables/$(urlencode "$name")/repositories/$new_repo_id" > /dev/null;
    done < "$dir/org-bindings/actions-variables.txt";
    if [[ -f "$dir/org-bindings/actions-enabled-selected" ]]; then
        best_effort "restoring org Actions selected-repository access" api --method PUT "orgs/$OWNER/actions/permissions/repositories/$new_repo_id" > /dev/null;
    fi;
    while IFS= read -r group_id; do
        [[ -n "$group_id" ]] && best_effort "restoring runner-group repository access: $group_id" api --method PUT "orgs/$OWNER/actions/runner-groups/$group_id/repositories/$new_repo_id" > /dev/null;
    done < "$dir/org-bindings/runner-groups.txt";
    if [[ -s "$dir/org-bindings/code-security-configuration-id" ]]; then
        IFS= read -r config_id < "$dir/org-bindings/code-security-configuration-id" || true;
        payload="$dir/org-bindings/code-security-attach.json";
        printf '{"scope":"selected","selected_repository_ids":[%s]}\n' "$new_repo_id" > "$payload";
        restore_once "code-security-configuration:$config_id" "reattaching code security configuration $config_id" api --method POST "orgs/$OWNER/code-security/configurations/$config_id/attach" --input "$payload";
    fi
}

restore_pages () 
{ 
    local dir="$1" page_key="pages-site";
    [[ -f "$dir/pages-state.sh" ]] || return 0;
    source "$dir/pages-state.sh";
    source "$dir/repo-state.sh";
    if ! restore_step_done "$page_key"; then
        if [[ "$PAGES_BUILD_TYPE" == workflow ]]; then
            if ! api --method POST "repos/$REPO/pages" -f build_type=workflow > /dev/null 2>&1; then
                record_restore_failure "workflow-based Pages site";
                warn "could not recreate workflow-based Pages site";
                return 0;
            fi;
        else
            if [[ -n "$PAGES_SOURCE_BRANCH" && "$PAGES_SOURCE_BRANCH" == "$DEFAULT_BRANCH" ]]; then
                if ! api --method POST "repos/$REPO/pages" -f "source[branch]=$PAGES_SOURCE_BRANCH" -f "source[path]=$PAGES_SOURCE_PATH" > /dev/null 2>&1; then
                    record_restore_failure "Pages site";
                    warn "could not recreate Pages site";
                    return 0;
                fi;
            else
                warn "Pages source branch '$PAGES_SOURCE_BRANCH' was not recreated; Pages requires manual follow-up";
                return 0;
            fi;
        fi;
        mark_restore_step_done "$page_key";
    else
        vlog "Pages site already recreated; skipping create.";
    fi;
    local page_args=(--method PUT "repos/$REPO/pages" -F "https_enforced=$(bool "$PAGES_HTTPS")");
    [[ -n "$PAGES_CNAME" ]] && page_args+=(-f "cname=$PAGES_CNAME");
    best_effort "restoring Pages settings" api "${page_args[@]}" > /dev/null
}

restore_webhooks () 
{ 
    local dir="$1" hdir secret_file new_id id_file key;
    shopt -s nullglob;
    for hdir in "$dir"/webhooks/*;
    do
        [[ -f "$hdir/state.sh" && -s "$hdir/create.json" ]] || continue;
        source "$hdir/state.sh";
        key="webhook:$OLD_HOOK_ID";
        secret_file="${SECRETS_DIR:+$SECRETS_DIR/webhooks/$OLD_HOOK_ID.secret}";
        if [[ "${HOOK_SECRET_STATUS:-unknown}" != unsigned && ( -z "$secret_file" || ! -f "$secret_file" ) ]]; then
            warn "skipping webhook $OLD_HOOK_ID: signing secret cannot be read back; supply $SECRETS_DIR/webhooks/$OLD_HOOK_ID.secret";
            continue;
        fi;
        id_file="$hdir/restored-id";
        if [[ -s "$id_file" ]]; then
            IFS= read -r new_id < "$id_file" || true;
            mark_restore_step_done "$key";
            clear_restore_step_pending "$key";
            vlog "webhook $OLD_HOOK_ID already created as $new_id; skipping create.";
        elif restore_step_done "$key"; then
            record_restore_failure "webhook $OLD_HOOK_ID (completed journal entry missing restored ID)";
            warn "webhook $OLD_HOOK_ID was marked restored but its new ID is missing; refusing to create a possible duplicate";
            continue;
        elif restore_step_pending "$key"; then
            record_restore_failure "webhook $OLD_HOOK_ID (unfinished prior attempt)";
            warn "webhook $OLD_HOOK_ID has an unfinished prior create attempt; refusing to create a possible duplicate";
            continue;
        else
            mark_restore_step_pending "$key";
            if ! new_id="$(api --method POST "repos/$REPO/hooks" --input "$hdir/create.json" --jq '.id' 2> /dev/null)"; then
                clear_restore_step_pending "$key";
                record_restore_failure "webhook $OLD_HOOK_ID";
                warn "restoring webhook $OLD_HOOK_ID failed";
                continue;
            fi;
            printf '%s\n' "$new_id" > "$id_file";
            mark_restore_step_done "$key";
            clear_restore_step_pending "$key";
        fi;
        if [[ -n "$secret_file" && -f "$secret_file" ]]; then
            best_effort "restoring signing secret for webhook $OLD_HOOK_ID" api --method PATCH "repos/$REPO/hooks/$new_id/config" -F "secret=@$secret_file" > /dev/null;
        fi;
    done;
    shopt -u nullglob
}

restore_supplied_secrets () 
{ 
    local app file name envdir secret_env_dir;
    [[ -n "$SECRETS_DIR" ]] || return 0;
    [[ -d "$SECRETS_DIR" ]] || { 
        warn "secrets directory not found: $SECRETS_DIR";
        return 0
    };
    shopt -s nullglob;
    for app in actions agents codespaces dependabot;
    do
        for file in "$SECRETS_DIR/repository/$app"/* "$SECRETS_DIR/$app"/*;
        do
            [[ -f "$file" ]] || continue;
            name="$(basename "$file")";
            if ! gh secret set "$name" -R "$REPO" --app "$app" < "$file"; then
                record_restore_failure "$app secret $name";
                warn "restoring $app secret $name failed";
            fi;
        done;
    done;
    for envdir in "$BACKUP_DIR"/environments/*;
    do
        [[ -f "$envdir/state.sh" ]] || continue;
        source "$envdir/state.sh";
        secret_env_dir="$SECRETS_DIR/environments/$ENV_KEY/actions";
        for file in "$secret_env_dir"/*;
        do
            [[ -f "$file" ]] || continue;
            name="$(basename "$file")";
            if ! gh secret set "$name" -R "$REPO" --env "$ENV_NAME" --app actions < "$file"; then
                record_restore_failure "environment secret $ENV_NAME/$name";
                warn "restoring environment secret $ENV_NAME/$name failed";
            fi;
        done;
    done;
    shopt -u nullglob
}
