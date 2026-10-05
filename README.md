# gh-repo-reset

`gh-repo-reset` is a Bash wrapper around GitHub CLI (`gh`) that **recreates a GitHub repository from scratch** while keeping the exact contents of its current default branch.

The new repository gets **one brand-new root commit named `Initial commit`**. Old Git history, branches, and tags stay only in the local safety backup and are not pushed back.

Version is intentionally pinned to **`v0.0.0-1`**.

> This deletes and recreates a repository. Run `--dry-run` first.

## Requirements

- Bash 4+
- `git`
- GitHub CLI: `gh`
- `gh` authenticated with admin/owner access to the target repository
- `git-lfs` optional but strongly recommended when the repository uses Git LFS
- `xdg-open` optional; after a real reset it opens GitHub settings pages that need manual follow-up

Repository deletion requires the `delete_repo` scope:

```bash
gh auth refresh -s delete_repo
```

## What it recreates

The tool takes a local safety snapshot first, then restores as much readable repository state as GitHub exposes:

- exact tree of the old default branch as one fresh `Initial commit`
- repository visibility and common repository/merge/security settings
- topics and labels
- deploy keys (public key, title, read/write setting)
- repository variables, including their values
- environments, environment variables, required reviewers, wait timers, and deployment branch/tag policies
- repository secret **names/metadata** for Actions, Agents, Codespaces, and Dependabot
- environment Actions secret **names/metadata**
- Actions permissions, selected-action policy, workflow-token defaults, fork-PR settings, artifact/log retention, repository Actions policies, and OIDC subject customization
- direct collaborators, pending collaborator invitations, and team access when the API permits it
- repository rulesets
- protection for the recreated default branch, including required signatures when enabled
- repository custom-property values
- autolink references
- Pages when its configured source still exists after the reset
- unsigned webhooks; signed webhooks can also be restored when their signing secret is explicitly supplied
- wiki Git history on a best-effort basis
- Git LFS objects when `git-lfs` is installed
- archived state after the rest of the restore is complete

The backup also keeps a full Git mirror and snapshots useful GitHub-only metadata for inspection.

## What GitHub does not let it capture

GitHub does **not** return stored secret values. The tool therefore never claims to back up secret material it cannot read.

It cannot automatically recover:

- Actions, Agents, Codespaces, Dependabot, or environment secret **values**
- your `gh` authentication token or personal access token
- the ephemeral Actions `GITHUB_TOKEN`
- private deploy-key material
- webhook signing secrets
- self-hosted runner registration/authentication tokens
- GitHub App/OAuth grants tied to the old repository identity
- package/container repository authorization tied to the old repository identity
- external cloud/OIDC trust that embeds the old GitHub repository ID

It also intentionally does not recreate issues, pull requests, releases, discussions, stars, forks, old branches/tags, or old commit history. Non-default branch protection cannot be functional because those branches are intentionally not recreated.

When something needs manual re-authorization, the tool warns and uses `xdg-open` to open the relevant GitHub settings page when available.

## Layout

The implementation is split by the reset lifecycle so the functional core stays easy to change:

```text
gh-repo-reset                  # small launcher / remote bootstrap
mise.toml                      # local development tasks (mise by jdx)
lib/
├── core.sh                    # shared gh/API/logging/serialization helpers
├── snapshot.sh                # capture readable GitHub repository state
├── git.sh                     # mirror backup, fresh root commit, push, wiki
├── safety.sh                  # destructive guards / non-round-trippable detection
├── restore.sh                 # repository-native settings and policies
├── integrations.sh            # access, apps, org bindings, Pages, webhooks, secrets
├── followup.sh                # manual re-authorization summary + xdg-open
└── main.sh                    # CLI parsing and lifecycle orchestration
```

The intended flow is `preflight → snapshot → prepare fresh commit → reset → restore → follow-up`. Configuration that GitHub exposes is restored automatically where practical; unreadable or identity-bound credentials stay an explicit manual boundary instead of being silently skipped.

## Run it remotely

This is the normal way to use the tool. There is no install step.

The launcher is intentionally small. When streamed, it uses authenticated `gh api` calls to fetch the pinned `v0.0.0-1` modules before running them. Until that tag is published, it falls back to `main` with a warning; setting `GH_REPO_RESET_SOURCE_REF` explicitly disables the fallback and pins the exact ref you name. Because this repository can be private and the tool already depends on `gh`, the authenticated remote form is:

```bash
gh api repos/ran-dall/gh-repo-reset/contents/gh-repo-reset \
  -H 'Accept: application/vnd.github.raw+json' \
  | bash -s -- OWNER/REPO --dry-run
```

Real run:

```bash
gh api repos/ran-dall/gh-repo-reset/contents/gh-repo-reset \
  -H 'Accept: application/vnd.github.raw+json' \
  | bash -s -- OWNER/REPO --allow-metadata-loss
```

When this repository is public, plain `curl` also works:

```bash
curl -fsSL https://raw.githubusercontent.com/ran-dall/gh-repo-reset/main/gh-repo-reset \
  | bash -s -- OWNER/REPO --dry-run
```

For a pinned release/tagged run, replace `main` with `v0.0.0-1`. The streamed launcher then fetches its modules from the same pinned version by default. Set `GH_REPO_RESET_SOURCE_REF=main` only when intentionally testing unreleased code.

Piped execution still reads destructive confirmation from `/dev/tty`.

## Local development

Cloning the repository is only needed when developing or testing the tool locally. Local project tasks use [mise](https://mise.jdx.dev/) by JDX; the checkout runs in place and has no local installation workflow.

Run the mocked test suite:

```bash
mise run test
```

You can also execute the checkout directly while developing:

```bash
./gh-repo-reset OWNER/REPO --dry-run
```

## Restore secret values you already have

The tool **does not search your machine for credentials**. If you already have the values, pass an explicit directory with `--secrets-dir`.

```text
my-secrets/
├── repository/
│   ├── actions/API_TOKEN
│   ├── agents/AGENT_TOKEN
│   ├── codespaces/DEV_TOKEN
│   └── dependabot/PRIVATE_REGISTRY_TOKEN
├── environments/
│   └── production/
│       └── actions/DEPLOY_TOKEN
└── webhooks/
    └── 12345678.secret
```

Environment directory names use the environment's URL-encoded name. For example, `prod/us` becomes `prod%2Fus`.

Then run:

```bash
./gh-repo-reset OWNER/REPO --secrets-dir ./my-secrets --allow-metadata-loss
```

For backward compatibility, repository secrets are also accepted from `my-secrets/actions/NAME`, `agents/NAME`, `codespaces/NAME`, and `dependabot/NAME`.

## Backups

Dry runs use temporary storage by default:

```text
${TMPDIR:-/tmp}/gh-repo-reset/OWNER__REPO/TIMESTAMP/
```

A real destructive run uses persistent state storage:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/gh-repo-reset/OWNER__REPO/TIMESTAMP/
```

Pass `--backup-dir DIR` to override either location. Dry-run snapshots are disposable and do not open browser windows. For a real reset, `git.git/` is the full old Git mirror; keep that safety backup until the recreated repository, integrations, packages, workflows, and deployments have all been verified.

Easy peasy lemon squeezy — with a safety backup first.