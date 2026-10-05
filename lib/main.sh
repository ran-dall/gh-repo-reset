# CLI state and lifecycle orchestration.

API_VERSION="2026-03-10"
REPO=""
BACKUP_ROOT="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/gh-repo-reset"
YES=0
ALLOW_METADATA_LOSS=0
NO_OPEN=0
DRY_RUN=0
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

gh_repo_reset_main() {
  while (($#)); do
    case "$1" in
      --yes) YES=1 ;;
      --allow-metadata-loss) ALLOW_METADATA_LOSS=1 ;;
      --backup-dir) shift; (($#)) || die "--backup-dir requires a value"; BACKUP_ROOT="$1" ;;
      --secrets-dir) shift; (($#)) || die "--secrets-dir requires a value"; SECRETS_DIR="$1" ;;
      --no-open) NO_OPEN=1 ;;
      --dry-run) DRY_RUN=1 ;;
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
  if [[ -z "$REPO" ]]; then REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"; fi
  [[ "$REPO" == */* ]] || die "repository must be OWNER/REPO: $REPO"
  api "repos/$REPO" >/dev/null || die "cannot read $REPO with current gh authentication"

  TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  SAFE_REPO="${REPO//\//__}"
  BACKUP_DIR="$BACKUP_ROOT/$SAFE_REPO/$TIMESTAMP"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" || true

  log "Version:    $VERSION"
  log "Repository: $REPO"
  log "Backup:     $BACKUP_DIR"
  log "Snapshotting GitHub state and Git history..."

  save_repo_state "$BACKUP_DIR"
  snapshot_labels "$BACKUP_DIR"
  snapshot_deploy_keys "$BACKUP_DIR"
  snapshot_variables "$BACKUP_DIR"
  snapshot_secrets "$BACKUP_DIR"
  snapshot_environments "$BACKUP_DIR"

  # Deployment policy entries are kept as TSV so restore stays Bash + gh only.
  local envdir metadata_present
  for envdir in "$BACKUP_DIR"/environments/*; do
    [[ -f "$envdir/state.sh" ]] || continue
    # shellcheck disable=SC1090
    source "$envdir/state.sh"
    api "repos/$REPO/environments/$ENV_KEY/deployment-branch-policies?per_page=100" \
      --jq '.branch_policies[]? | [.name, (.type // "branch")] | @tsv' \
      >"$envdir/deployment-branch-policies.tsv" 2>/dev/null || :
  done

  snapshot_actions_settings "$BACKUP_DIR"
  snapshot_actions_policies "$BACKUP_DIR"
  snapshot_autolinks "$BACKUP_DIR"
  snapshot_rulesets "$BACKUP_DIR"
  snapshot_branch_protection "$BACKUP_DIR"
  snapshot_access "$BACKUP_DIR"
  snapshot_app_installations "$BACKUP_DIR"
  snapshot_org_bindings "$BACKUP_DIR"
  snapshot_custom_properties "$BACKUP_DIR"
  snapshot_pages "$BACKUP_DIR"
  snapshot_webhooks "$BACKUP_DIR"
  snapshot_git_and_metadata "$BACKUP_DIR"
  prepare_initial_commit "$BACKUP_DIR"

  metadata_present=0
  if has_irreplaceable_metadata; then metadata_present=1; fi

  if (( DRY_RUN )); then
    (( metadata_present )) && warn "a destructive run requires --allow-metadata-loss because non-round-trippable state was detected"
    log "Dry run complete. No destructive operation was performed."
    manual_followup "$BACKUP_DIR"
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

  log "Deleting $REPO..."
  if ! gh repo delete "$REPO" --yes; then
    printf '[%s] Delete failed. Try: gh auth refresh -s delete_repo\nBackup: %s\n' "$PROGRAM" "$BACKUP_DIR" >&2
    return 4
  fi

  log "Recreating $REPO with visibility: $VISIBILITY"
  create_repository "$VISIBILITY"
  log "Pushing one fresh initial commit only..."
  push_initial_commit "$BACKUP_DIR"

  log "Restoring readable repository configuration (best effort)..."
  restore_repo_settings "$BACKUP_DIR"
  restore_labels "$BACKUP_DIR"
  restore_deploy_keys "$BACKUP_DIR"
  restore_variables "$BACKUP_DIR"

  # Identity/access comes before policies that reference users, teams, or installations.
  restore_access "$BACKUP_DIR"
  restore_app_installations "$BACKUP_DIR"
  restore_org_bindings "$BACKUP_DIR"

  restore_environments "$BACKUP_DIR"
  restore_environment_branch_policies "$BACKUP_DIR"
  restore_environment_custom_protection_rules "$BACKUP_DIR"
  restore_actions_settings "$BACKUP_DIR"
  restore_actions_policies "$BACKUP_DIR"
  restore_autolinks "$BACKUP_DIR"
  restore_custom_properties "$BACKUP_DIR"
  restore_pages "$BACKUP_DIR"
  restore_wiki "$BACKUP_DIR"
  restore_webhooks "$BACKUP_DIR"
  restore_supplied_secrets

  # Protections are deliberately last so they cannot block bootstrap writes.
  restore_rulesets "$BACKUP_DIR"
  restore_branch_protection "$BACKUP_DIR"
  restore_archived_state "$BACKUP_DIR"

  manual_followup "$BACKUP_DIR"
  log "Finished. Verify the recreated repository before deleting the safety backup."
}
