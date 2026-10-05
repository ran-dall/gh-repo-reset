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
    if (( VERBOSE )); then
        if ! git clone --mirror "https://github.com/$REPO.wiki.git" "$dir/wiki.git"; then
            vwarn "wiki mirror is unavailable; continuing without it";
            rm -rf "$dir/wiki.git";
        fi;
    elif ! git clone --mirror "https://github.com/$REPO.wiki.git" "$dir/wiki.git" > /dev/null 2>&1; then
        rm -rf "$dir/wiki.git";
    fi;
    snapshot_api "$dir/issues.json" "repos/$REPO/issues?state=all&per_page=100";
    snapshot_api "$dir/pulls.json" "repos/$REPO/pulls?state=all&per_page=100";
    snapshot_api "$dir/releases.json" "repos/$REPO/releases?per_page=100";
    snapshot_api "$dir/discussions.json" "repos/$REPO/discussions?per_page=100"
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
    for attempt in 1 2 3 4 5;
    do
        if (( VERBOSE )); then
            gh repo create "$REPO" "--$visibility" && return 0;
        elif gh repo create "$REPO" "--$visibility" > /dev/null 2>&1; then
            return 0;
        fi;
        (( attempt < 5 )) && sleep 2;
    done;
    die "could not recreate $REPO after deletion"
}

push_initial_commit () 
{ 
    local dir="$1";
    source "$dir/repo-state.sh";
    gh auth setup-git > /dev/null;
    git -C "$dir/git.git" remote set-url origin "https://github.com/$REPO.git";
    if [[ "${LFS_USED:-false}" == true && "${LFS_BACKUP:-none}" == complete ]]; then
        best_effort "restoring Git LFS objects" git -C "$dir/git.git" lfs push origin refs/gh-repo-reset/initial;
    fi;
    if (( VERBOSE )); then
        git -C "$dir/git.git" push --force origin "refs/gh-repo-reset/initial:refs/heads/$DEFAULT_BRANCH";
    elif ! git -C "$dir/git.git" push --force origin "refs/gh-repo-reset/initial:refs/heads/$DEFAULT_BRANCH" > /dev/null 2>&1; then
        die "could not push the fresh initial commit";
    fi
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
