# Summarize automatic coverage and open manual follow-up pages.

manual_followup () 
{ 
    local dir="$1" base="https://github.com/$REPO/settings" owner owner_type package_url installations_url;
    owner="${REPO%%/*}";
    owner_type="$(api "users/$owner" --jq '.type // "User"' 2> /dev/null || printf User)";
    if [[ "$owner_type" == Organization ]]; then
        package_url="https://github.com/orgs/$owner/packages";
        installations_url="https://github.com/organizations/$owner/settings/installations";
    else
        package_url="https://github.com/users/$owner/packages";
        installations_url="https://github.com/settings/installations";
    fi;
    if (( DRY_RUN )); then
        printf '\n[%s] Dry-run follow-up preview.\n' "$PROGRAM" 1>&2;
    else
        printf '\n[%s] Automatic restore pass complete.\n' "$PROGRAM" 1>&2;
    fi;
    cat 1>&2 <<MANUAL_EOF
[$PROGRAM] Automatically handled when GitHub exposes enough information:
  - repository settings/topics/labels and supported security toggles
  - deploy-key PUBLIC keys
  - repository/environment variables (values are readable)
  - environments, reviewers/timers/deployment policies, and custom deployment-protection apps when still authorized
  - Actions permission/policy settings, artifact retention, and repository OIDC subject customization
  - repository rulesets and default-branch protection
  - direct collaborator/team access and pending collaborator invitations
  - organization selected-repository bindings for Actions/Dependabot/Codespaces secrets, Actions variables, Actions enablement, runner groups, and code-security configuration when gh has org permission
  - repository custom-property values and autolink references
  - Pages when its source still exists, plus wiki Git history when GitHub accepts the recreated wiki remote
  - Git LFS objects when git-lfs is installed
  - unsigned webhooks, plus signed webhooks when you explicitly provide the secret

[$PROGRAM] Still review/re-authorize identity-bound or unreadable state:
  - Actions/Agents/Codespaces/Dependabot/environment secret VALUES
  - GitHub App installations that could not be re-added with the current gh credential, plus third-party OAuth/integration grants
  - package/container repository access (GitHub does not expose the full Manage Actions access UI as a round-trippable repository API)
  - self-hosted runner registrations
  - webhook signing secrets not explicitly supplied
  - cloud OIDC trust that embeds the old repository ID
  - non-default branch protection (those branches are intentionally not recreated)
  - issues/PRs/releases/discussions/stars/forks and other GitHub-only history

The tool does NOT export your gh authentication token/PAT, private deploy keys, GITHUB_TOKEN,
or runner registration tokens. Those are credentials, not readable repository configuration.

Safety backup: $dir
Old Git history: $dir/git.git
MANUAL_EOF

    open_url "$base/secrets/actions";
    open_url "$base/environments";
    open_url "$base/rules";
    open_url "$base/hooks";
    open_url "$base/access";
    open_url "$base/pages";
    open_url "$base/actions";
    open_url "$base/actions/runners";
    open_url "$installations_url";
    open_url "$package_url"
}
