# CLI state and lifecycle orchestration.

API_VERSION="2026-03-10"
REPO=""
BACKUP_ROOT="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/gh-repo-reset"
BACKUP_ROOT_EXPLICIT=0
YES=0
ALLOW_METADATA_LOSS=0
NO_OPEN=0
DRY_RUN=0
VERBOSE=0
RESUME_FROM=""
SECRETS_DIR=""

self_test () 
{ 
    [[ "$(urlencode 'prod/us west')" == 'prod%2Fus%20west' ]] || die "urlencode self-test failed";
    [[ "$(bool enabled)" == true && "$(bool false)" == false ]] || die "bool self-test failed";
    [[ "$(normalize_permission write)" == push && "$(normalize_permission read)" == pull ]] || die "permission self-test failed";
    [[ "$VERSION" == 'v0.0.0-1' ]] || die "version pin self-test failed";
    local tmp;
    tmp="$(mktemp)";
    write_assignment "$tmp" TEST_VALUE 'a b $ c';
    source "$tmp";
    rm -f "$tmp";
    [[ "$TEST_VALUE" == 'a b $ c' ]] || die "state round-trip self-test failed";
    printf '%s self-test: ok\n' "$PROGRAM"
}

restore_detected_state ()
{
  local dir="$1"
  BACKUP_DIR="$dir"
  : > "$BACKUP_DIR/restore-failures.txt"
  : > "$BACKUP_DIR/restore-errors.log"
  # shellcheck disable=SC1090
  source "$dir/repo-state.sh"

  vlog "Ensuring the prepared initial commit is on $DEFAULT_BRANCH..."
  push_initial_commit "$dir"

  log "Restoring repository state..."
  restore_repo_settings "$dir"
  restore_labels "$dir"
  restore_deploy_keys "$dir"
  restore_variables "$dir"

  restore_access "$dir"
  restore_app_installations "$dir"
  restore_org_bindings "$dir"

  restore_environments "$dir"
  restore_environment_branch_policies "$dir"
  restore_environment_custom_protection_rules "$dir"
  restore_actions_settings "$dir"
  restore_actions_policies "$dir"
  restore_autolinks "$dir"
  restore_custom_properties "$dir"
  restore_pages "$dir"
  restore_wiki "$dir"
  restore_webhooks "$dir"
  restore_supplied_secrets

  restore_rulesets "$dir"
  restore_branch_protection "$dir"
  restore_archived_state "$dir"

  print_restore_result "$dir"
  manual_followup "$dir"
  reset_local_checkout "$dir"
}

gh_repo_reset_main() {
  local requested_repo="" git_snapshot_pid="" api_snapshot_failed=0 git_snapshot_failed=0 repo_backup_root=""
  while (($#)); do
    case "$1" in
      --yes) YES=1 ;;
      --allow-metadata-loss) ALLOW_METADATA_LOSS=1 ;;
      --backup-dir) shift; (($#)) || die "--backup-dir requires a value"; BACKUP_ROOT="$1"; BACKUP_ROOT_EXPLICIT=1 ;;
      --secrets-dir) shift; (($#)) || die "--secrets-dir requires a value"; SECRETS_DIR="$1" ;;
      --no-open) NO_OPEN=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --verbose) VERBOSE=1 ;;
      --resume-from) shift; (($#)) || die "--resume-from requires a backup directory"; RESUME_FROM="$1" ;;
      --self-test) self_test; return 0 ;;
      --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; return 0 ;;
      -h|--help) usage; return 0 ;;
      -*) die "unknown option: $1" ;;
      *) [[ -z "$REPO" ]] || die "only one repository may be specified"; REPO="$1" ;;
    esac
    shift
  done

  need gh
  need git
  gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated; run: gh auth login"

  if [[ -n "$RESUME_FROM" ]]; then
    [[ -d "$RESUME_FROM" ]] || die "resume backup directory not found: $RESUME_FROM"
    RESUME_FROM="$(cd -- "$RESUME_FROM" && pwd)"
    [[ -f "$RESUME_FROM/repo-state.sh" && -d "$RESUME_FROM/git.git" && -f "$RESUME_FROM/initial-commit.txt" ]] || die "resume backup is incomplete: $RESUME_FROM"
    requested_repo="$REPO"
    # shellcheck disable=SC1090
    source "$RESUME_FROM/repo-state.sh"
    if [[ -n "$requested_repo" && "$requested_repo" != "$REPO" ]]; then
      die "resume backup is for $REPO, not $requested_repo"
    fi
    api "repos/$REPO" >/dev/null || die "cannot read recreated $REPO with current gh authentication"
    BACKUP_DIR="$RESUME_FROM"
    repair_legacy_repo_booleans "$BACKUP_DIR"
    # shellcheck disable=SC1090
    source "$BACKUP_DIR/repo-state.sh"
    reconcile_deploy_key_manual_items "$BACKUP_DIR"
    record_package_actions_access_followup "$BACKUP_DIR"
    log "Resuming reset: $REPO"
    build_restore_plan "$BACKUP_DIR"
    (( VERBOSE )) && print_detected_summary "$BACKUP_DIR"
    print_restore_plan_summary "$BACKUP_DIR"
    (( VERBOSE )) && print_restore_plan_details "$BACKUP_DIR"
    restore_detected_state "$BACKUP_DIR"
    log "Done. Backup: $BACKUP_DIR"
    return 0
  fi

  if [[ -z "$REPO" ]]; then REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"; fi
  [[ "$REPO" == */* ]] || die "repository must be OWNER/REPO: $REPO"
  api "repos/$REPO" >/dev/null || die "cannot read $REPO with current gh authentication"

  if (( DRY_RUN && ! BACKUP_ROOT_EXPLICIT )); then
    BACKUP_ROOT="${TMPDIR:-/tmp}/gh-repo-reset"
  fi

  TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  SAFE_REPO="${REPO//\//__}"
  repo_backup_root="$BACKUP_ROOT/$SAFE_REPO"
  mkdir -p "$repo_backup_root" || die "could not create backup root: $repo_backup_root"
  BACKUP_DIR="$repo_backup_root/$TIMESTAMP"
  if ! mkdir "$BACKUP_DIR" 2>/dev/null; then
    BACKUP_DIR="$(mktemp -d "$repo_backup_root/${TIMESTAMP}.XXXXXX")" \
      || die "could not create a unique backup directory"
  fi
  chmod 700 "$BACKUP_DIR" || die "could not secure backup directory: $BACKUP_DIR"
  : > "$BACKUP_DIR/snapshot-status.tsv"
  : > "$BACKUP_DIR/snapshot-failures.txt"
  : > "$BACKUP_DIR/snapshot-errors.log"

  if (( DRY_RUN )); then
    log "Dry run: $REPO"
  else
    log "Preparing reset: $REPO"
  fi
  vlog "Version: $VERSION"
  if (( DRY_RUN )); then
    vlog "Snapshot: $BACKUP_DIR"
  else
    vlog "Backup: $BACKUP_DIR"
  fi
  vlog "Snapshotting repository state..."

  save_repo_state "$BACKUP_DIR"

  # The Git mirror is often the longest single operation and does not consume
  # the API probe pool. Keep it running while all GitHub API reads share one
  # bounded concurrency budget.
  snapshot_git_backup "$BACKUP_DIR" &
  local git_snapshot_pid=$!

  # Broad independent API reads share the rolling snapshot pool.
  if ! run_snapshot_jobs "$BACKUP_DIR" \
    snapshot_history_metadata \
    snapshot_environments \
    snapshot_labels \
    snapshot_actions_settings \
    snapshot_deploy_keys \
    snapshot_variables \
    snapshot_secrets \
    snapshot_access \
    snapshot_rulesets \
    snapshot_branch_protection \
    snapshot_actions_policies \
    snapshot_autolinks \
    snapshot_app_installations \
    snapshot_custom_properties \
    snapshot_pages \
    snapshot_webhooks; then
    api_snapshot_failed=1
  fi

  # N+1 membership/detail surfaces run as dedicated bounded stages instead of
  # nesting another pool inside the broad snapshot pool. Do not start more API
  # work if a broad snapshot worker failed unexpectedly.
  if (( ! api_snapshot_failed )); then
    snapshot_org_bindings "$BACKUP_DIR"
    snapshot_package_reset_targets "$BACKUP_DIR"
  fi

  if wait "$git_snapshot_pid"; then
    if [[ -s "$BACKUP_DIR/git-state.sh" ]]; then
      cat "$BACKUP_DIR/git-state.sh" >> "$BACKUP_DIR/repo-state.sh" \
        || die "could not merge Git backup state"
      rm -f "$BACKUP_DIR/git-state.sh"
      record_snapshot_status "Git mirror backup" captured
    else
      record_snapshot_failure "Git mirror backup state"
      git_snapshot_failed=1
    fi
  else
    record_snapshot_failure "Git mirror backup"
    git_snapshot_failed=1
  fi

  (( api_snapshot_failed )) && record_snapshot_failure "API snapshot worker pool"
  (( git_snapshot_failed )) && vlog "Git mirror backup did not complete cleanly."

  if [[ ! -s "$BACKUP_DIR/snapshot-status.tsv" ]]; then
    warn "Snapshot status manifest is empty; refusing to continue."
    warn "No destructive changes were made. Snapshot kept at $BACKUP_DIR"
    return 5
  fi

  if grep -Eq '[[:space:]]failed$' "$BACKUP_DIR/snapshot-status.tsv" || [[ -s "$BACKUP_DIR/snapshot-failures.txt" ]]; then
    local -a snapshot_failures=()
    if [[ -s "$BACKUP_DIR/snapshot-failures.txt" ]]; then
      mapfile -t snapshot_failures < <(awk 'NF' "$BACKUP_DIR/snapshot-failures.txt")
    fi
    if (( ${#snapshot_failures[@]} )); then
      warn "Snapshot incomplete: $(join_comma "${snapshot_failures[@]}")."
    else
      warn "Snapshot incomplete; see $BACKUP_DIR/snapshot-status.tsv"
    fi
    [[ -s "$BACKUP_DIR/snapshot-errors.log" ]] && warn "Snapshot errors: $BACKUP_DIR/snapshot-errors.log"
    if (( VERBOSE )) && [[ -s "$BACKUP_DIR/snapshot-errors.log" ]]; then
      sed 's/^/  /' "$BACKUP_DIR/snapshot-errors.log" >&2 || true
    fi
    warn "No destructive changes were made. Snapshot kept at $BACKUP_DIR"
    return 5
  fi

  if ! prepare_local_checkout_reset "$BACKUP_DIR"; then
    warn "Local checkout preflight failed; refusing to continue."
    warn "Snapshot kept at $BACKUP_DIR"
    return 7
  fi

  local metadata_present
  prepare_initial_commit "$BACKUP_DIR"

  metadata_present=0
  if has_irreplaceable_metadata; then metadata_present=1; fi
  record_package_actions_access_followup "$BACKUP_DIR"
  build_restore_plan "$BACKUP_DIR"
  (( VERBOSE )) && print_detected_summary "$BACKUP_DIR"
  print_restore_plan_summary "$BACKUP_DIR"
  (( VERBOSE )) && print_restore_plan_details "$BACKUP_DIR"

  if (( DRY_RUN )); then
    log "Dry run complete — no changes made."
    (( metadata_present )) && log "A real reset requires --allow-metadata-loss."
    log "Snapshot: $BACKUP_DIR"
    return 0
  fi

  if (( metadata_present && ! ALLOW_METADATA_LOSS )); then
    cat >&2 <<GUARD_EOF

[$PROGRAM] Refusing to delete $REPO because GitHub-only history or credential material
cannot be round-tripped. The safety backup was still created at:
  $BACKUP_DIR

Inspect it, provide any recoverable secret values with --secrets-dir, then rerun with
--allow-metadata-loss if this reset is really intended.
GUARD_EOF
    return 3
  fi

  confirm_reset
  # shellcheck disable=SC1090
  source "$BACKUP_DIR/repo-state.sh"

  if [[ -s "$BACKUP_DIR/package-reset-targets.tsv" ]]; then
    vlog "Deleting $(count_nonempty_lines "$BACKUP_DIR/package-reset-targets.tsv") GitHub package(s)..."
    if ! delete_reset_packages "$BACKUP_DIR"; then
      warn "Package cleanup failed; refusing to delete $REPO."
      warn "GitHub package deletion requires package admin access; classic tokens need read:packages and delete:packages."
      [[ -s "$BACKUP_DIR/package-delete-errors.log" ]] && warn "Package errors: $BACKUP_DIR/package-delete-errors.log"
      return 6
    fi
  fi

  log "Recreating $REPO..."
  if ! gh repo delete "$REPO" --yes >/dev/null 2>&1; then
    printf '[%s] Delete failed. Try: gh auth refresh -s delete_repo\nBackup: %s\n' "$PROGRAM" "$BACKUP_DIR" >&2
    return 4
  fi

  vlog "Recreating with visibility: $VISIBILITY"
  create_repository "$VISIBILITY"
  restore_detected_state "$BACKUP_DIR"
  log "Done. Backup: $BACKUP_DIR"
}
