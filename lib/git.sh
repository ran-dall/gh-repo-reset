# Git mirror backup, fresh root-commit creation, repository creation/push, and wiki restore.

snapshot_git_and_metadata () 
{ 
    local dir="$1";
    vlog "Creating full local mirror backup...";
    gh auth setup-git > /dev/null;
    if (( VERBOSE )); then
        gh repo clone "$REPO" "$dir/git.git" -- --mirror;
    elif ! gh repo clone "$REPO" "$dir/git.git" -- --mirror > /dev/null 2>&1; then
        die "could not create the Git mirror backup";
    fi;
    source "$dir/repo-state.sh";
    write_assignment "$dir/repo-state.sh" LFS_USED false;
    write_assignment "$dir/repo-state.sh" LFS_BACKUP none;
    if git -C "$dir/git.git" show "refs/heads/$DEFAULT_BRANCH:.gitattributes" 2> /dev/null | grep -Eq 'filter=lfs|filter[[:space:]]*=[[:space:]]*lfs'; then
        write_assignment "$dir/repo-state.sh" LFS_USED true;
        if git lfs version > /dev/null 2>&1; then
            if git -C "$dir/git.git" lfs fetch --all origin; then
                write_assignment "$dir/repo-state.sh" LFS_BACKUP complete;
            else
                write_assignment "$dir/repo-state.sh" LFS_BACKUP failed;
                warn "Git LFS is used but the LFS object backup failed";
            fi;
        else
            write_assignment "$dir/repo-state.sh" LFS_BACKUP missing_git_lfs;
            warn "Git LFS is used but git-lfs is not installed; LFS objects are NOT backed up";
        fi;
    fi;
    if [[ "${HAS_WIKI:-false}" == true ]]; then
        if (( VERBOSE )); then
            if ! git clone --mirror "https://github.com/$REPO.wiki.git" "$dir/wiki.git"; then
                vwarn "wiki mirror is unavailable; continuing without it";
                rm -rf "$dir/wiki.git";
            fi;
        elif ! git clone --mirror "https://github.com/$REPO.wiki.git" "$dir/wiki.git" > /dev/null 2>&1; then
            rm -rf "$dir/wiki.git";
        fi;
    fi;
    snapshot_api "$dir/issues.json" "repos/$REPO/issues?state=all&per_page=100";
    snapshot_api_optional_404 "$dir/pulls.json" "repos/$REPO/pulls?state=all&per_page=100";
    snapshot_api "$dir/releases.json" "repos/$REPO/releases?per_page=100";
    if [[ "${HAS_DISCUSSIONS:-false}" == true ]]; then
        snapshot_api "$dir/discussions.json" "repos/$REPO/discussions?per_page=100";
    fi;
    snapshot_package_actions_access_hints "$dir"
    snapshot_package_reset_targets "$dir"
}

snapshot_package_actions_access_hints ()
{
    local dir="$1" owner ref out matches package url registry_used=0;
    source "$dir/repo-state.sh";
    owner="${REPO%%/*}";
    ref="refs/heads/$DEFAULT_BRANCH";
    out="$dir/package-actions-access.tsv";
    : > "$out";

    # GitHub does not expose Manage Actions access grants through a supported
    # API. Preserve concrete package references from the default branch so the
    # user gets a targeted post-reset checklist instead of a generic warning.
    matches="$(git -C "$dir/git.git" grep -I -h -Eio "ghcr\\.io/${owner}/[A-Za-z0-9._/-]+" "$ref" -- 2>/dev/null || true)";
    while IFS= read -r package; do
        [[ -n "$package" ]] || continue;
        package="${package#ghcr.io/}";
        package="${package#*/}";
        [[ -n "$package" ]] || continue;
        url="https://github.com/orgs/$owner/packages/container/package/$package/settings";
        printf 'container\t%s\t%s\n' "$package" "$url" >> "$out";
    done < <(printf '%s\n' "$matches" | awk 'NF' | sort -fu);

    if git -C "$dir/git.git" grep -I -q -E 'npm\.pkg\.github\.com' "$ref" -- 2>/dev/null; then
        registry_used=1;
        matches="$(git -C "$dir/git.git" grep -I -h -Eio "@${owner}/[A-Za-z0-9._-]+" "$ref" -- 2>/dev/null || true)";
        while IFS= read -r package; do
            [[ -n "$package" ]] || continue;
            package="${package#@}";
            package="${package#*/}";
            [[ -n "$package" ]] || continue;
            url="https://github.com/orgs/$owner/packages/npm/package/$package/settings";
            printf 'npm\t%s\t%s\n' "$package" "$url" >> "$out";
        done < <(printf '%s\n' "$matches" | awk 'NF' | sort -fu);
    fi;

    if git -C "$dir/git.git" grep -I -q -E 'nuget\.pkg\.github\.com' "$ref" -- 2>/dev/null; then
        printf 'nuget\t<registry-used>\thttps://github.com/orgs/%s/packages\n' "$owner" >> "$out";
        registry_used=1;
    fi;
    if git -C "$dir/git.git" grep -I -q -E 'rubygems\.pkg\.github\.com' "$ref" -- 2>/dev/null; then
        printf 'rubygems\t<registry-used>\thttps://github.com/orgs/%s/packages\n' "$owner" >> "$out";
        registry_used=1;
    fi;

    if git -C "$dir/git.git" grep -I -q -E 'packages:[[:space:]]*(read|write)' "$ref" -- .github/workflows 2>/dev/null; then
        registry_used=1;
    fi;

    sort -u "$out" -o "$out";
    if [[ ! -s "$out" && "$registry_used" == 1 ]]; then
        printf 'github-packages\t<workflow-uses-packages>\thttps://github.com/orgs/%s/packages\n' "$owner" > "$out";
    fi
}

record_package_actions_access_followup ()
{
    local dir="$1" type name url label;
    local -a labels=();
    [[ -s "$dir/package-actions-access.tsv" ]] || return 0;

    while IFS=$'\t' read -r type name url; do
        [[ -n "$type" ]] || continue;
        if [[ -s "$dir/package-reset-targets.tsv" ]] && grep -Fqx "$(printf '%s\t%s' "$type" "$name")" "$dir/package-reset-targets.tsv"; then
            continue;
        fi;
        if [[ "$name" == "<registry-used>" || "$name" == "<workflow-uses-packages>" ]]; then
            label="$type";
        else
            label="$type/$name";
        fi;
        labels+=("$label");
    done < "$dir/package-actions-access.tsv";

    ((${#labels[@]})) || return 0;
    record_manual_item package_actions_access "review GitHub Packages Manage Actions access for: $(join_comma "${labels[@]}"); GitHub does not expose prior repository grants through a supported API"
}

snapshot_package_reset_targets ()
{
    local dir="$1" out repo_name list_endpoint package_base name linked_repo_id;
    source "$dir/repo-state.sh";
    out="$dir/package-reset-targets.tsv";
    repo_name="${REPO#*/}";
    : > "$out";

    # Keep a same-name fallback for legacy/unlinked GHCR packages. GitHub does
    # not automatically link packages pushed from the CLI, even if their name
    # matches the repository name.
    printf 'container\t%s\n' "$repo_name" >> "$out";

    if [[ "${OWNER_TYPE:-User}" == Organization ]]; then
        list_endpoint="orgs/$OWNER/packages?package_type=container&per_page=100";
        package_base="orgs/$OWNER/packages/container";
    else
        list_endpoint="users/$OWNER/packages?package_type=container&per_page=100";
        package_base="users/$OWNER/packages/container";
    fi;

    # Repository linkage is the authoritative provenance signal for containers
    # published from this repository. Enumerate owner-scoped containers, fetch
    # each package detail, and keep only packages linked to this repository ID.
    snapshot_capture "$dir/container-package-names.txt" "owner container packages" \
      api --paginate "$list_endpoint" --jq '.[].name';

    if [[ -f "$dir/container-package-names.txt" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue;
            linked_repo_id="$(snapshot_value "container package $name repository association" "" \
              api "$package_base/$(urlencode "$name")" --jq '.repository.id // empty')";
            [[ -n "$linked_repo_id" && "$linked_repo_id" == "$REPO_ID" ]] || continue;
            printf 'container\t%s\n' "$name" >> "$out";
        done < "$dir/container-package-names.txt";
    fi;

    sort -u "$out" -o "$out";
    record_snapshot_status "GitHub package reset targets" captured
}

delete_reset_packages ()
{
    local dir="$1" base type name encoded err failed=0;
    source "$dir/repo-state.sh";
    : > "$dir/package-delete-failures.tsv";
    : > "$dir/package-delete-errors.log";
    [[ -s "$dir/package-reset-targets.tsv" ]] || return 0;

    if [[ "${OWNER_TYPE:-User}" == Organization ]]; then
        base="orgs/$OWNER/packages";
    else
        base="users/$OWNER/packages";
    fi;

    while IFS=$'\t' read -r type name; do
        [[ -n "$type" && -n "$name" ]] || continue;
        encoded="$(urlencode "$name")";
        err="$(mktemp)";
        log "Deleting GitHub package $type/$name...";
        if api --method DELETE "$base/$type/$encoded" > /dev/null 2> "$err"; then
            rm -f "$err";
            continue;
        fi;
        if snapshot_error_is_404 "$err"; then
            vlog "GitHub package $type/$name is already absent.";
            rm -f "$err";
            continue;
        fi;

        failed=1;
        printf '%s\t%s\n' "$type" "$name" >> "$dir/package-delete-failures.tsv";
        {
            printf '[%s/%s]\n' "$type" "$name";
            cat "$err";
            printf '\n';
        } >> "$dir/package-delete-errors.log";
        warn "Could not delete GitHub package $type/$name.";
        rm -f "$err";
    done < "$dir/package-reset-targets.tsv";

    (( failed == 0 ))
}

prepare_initial_commit () 
{ 
    local dir="$1" tree commit login name email;
    source "$dir/repo-state.sh";
    if ! tree="$(git -C "$dir/git.git" rev-parse "refs/heads/$DEFAULT_BRANCH^{tree}" 2> /dev/null)"; then
        warn "old repository has no readable '$DEFAULT_BRANCH' branch; creating an empty initial tree";
        tree="$(git -C "$dir/git.git" mktree < /dev/null)";
    fi;
    name="${GIT_AUTHOR_NAME:-$(git config --global user.name 2> /dev/null || true)}";
    email="${GIT_AUTHOR_EMAIL:-$(git config --global user.email 2> /dev/null || true)}";
    login="$(api user --jq '.login // ""' 2> /dev/null || true)";
    [[ -n "$name" ]] || name="${login:-gh-repo-reset}";
    [[ -n "$email" ]] || email="${login:-gh-repo-reset}@users.noreply.github.com";
    commit="$(printf 'Initial commit\n' | GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" git -C "$dir/git.git" commit-tree "$tree")";
    git -C "$dir/git.git" update-ref refs/gh-repo-reset/initial "$commit";
    printf '%s\n' "$commit" > "$dir/initial-commit.txt";
    vlog "Prepared fresh root commit $commit from $DEFAULT_BRANCH's current tree."
}

create_repository () 
{ 
    local visibility="$1" attempt;
    case "$visibility" in 
        public | private | internal)
            ;;
        *)
            die "unsupported repository visibility: $visibility"
            ;;
    esac;
    for attempt in 1 2 3 4 5; do
        if (( VERBOSE )); then
            gh repo create "$REPO" "--$visibility" && return 0;
        elif gh repo create "$REPO" "--$visibility" > /dev/null 2>&1; then
            return 0;
        fi;
        if (( attempt < 5 )); then
            sleep 2;
        fi;
    done;
    die "could not recreate $REPO after deletion"
}

push_initial_commit () 
{ 
    local dir="$1" attempt existing expected err;
    source "$dir/repo-state.sh";
    gh auth setup-git > /dev/null;
    git -C "$dir/git.git" remote set-url origin "https://github.com/$REPO.git";
    # A mirror clone sets remote.origin.mirror=true, which makes Git reject
    # a single-ref push ("--mirror can't be combined with refspecs").
    git -C "$dir/git.git" config --unset-all remote.origin.mirror > /dev/null 2>&1 || true;

    expected="$(cat "$dir/initial-commit.txt")";
    existing="$(git -C "$dir/git.git" ls-remote origin "refs/heads/$DEFAULT_BRANCH" 2> /dev/null | awk 'NR==1 {print $1}' || true)";
    if [[ -n "$existing" ]]; then
        if [[ "$existing" == "$expected" ]]; then
            vlog "$DEFAULT_BRANCH already points at the prepared initial commit; skipping push.";
            return 0;
        fi;
        die "$REPO already has an unexpected $DEFAULT_BRANCH commit; refusing to overwrite it";
    fi;

    if [[ "${LFS_USED:-false}" == true && "${LFS_BACKUP:-none}" == complete ]]; then
        best_effort "restoring Git LFS objects" git -C "$dir/git.git" lfs push origin refs/gh-repo-reset/initial;
    fi;

    err="$dir/push.err";
    for attempt in 1 2 3 4 5; do
        : > "$err";
        if (( VERBOSE )); then
            if git -C "$dir/git.git" push origin "refs/gh-repo-reset/initial:refs/heads/$DEFAULT_BRANCH" 2> >(tee "$err" >&2); then
                rm -f "$err";
                return 0;
            fi;
        elif git -C "$dir/git.git" push origin "refs/gh-repo-reset/initial:refs/heads/$DEFAULT_BRANCH" > /dev/null 2> "$err"; then
            rm -f "$err";
            return 0;
        fi;
        if (( attempt < 5 )); then
            sleep 2;
        fi;
    done;

    printf '[%s] Git push failed:\n' "$PROGRAM" >&2;
    sed 's/^/  /' "$err" >&2 || true;
    die "could not push the fresh initial commit; backup is still safe at $dir"
}

restore_wiki () 
{ 
    local dir="$1";
    [[ -d "$dir/wiki.git" ]] || return 0;
    if git -C "$dir/wiki.git" show-ref --quiet 2> /dev/null; then
        git -C "$dir/wiki.git" remote set-url origin "https://github.com/$REPO.wiki.git" || return 0;
        best_effort "restoring wiki Git history" git -C "$dir/wiki.git" push --mirror origin;
    fi
}
