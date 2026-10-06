# gh-repo-reset

`gh-repo-reset` is a Bash wrapper around GitHub CLI (`gh`) that **recreates a GitHub repository from scratch** while keeping the exact contents of its current default branch.

The new repository gets **one brand-new root commit named `Initial commit`**. When the command is run from a matching local worktree, the whole local repository is reset too: every clean linked worktree lands on that root commit, while only the current worktree keeps the `main` branch. Old Git history, branches, and tags stay only in the timestamped safety backup.

Version is intentionally pinned to **`v0.0.0-1`**.

> This deletes and recreates a repository. It deletes GHCR containers linked to the repository in GitHub package metadata, plus `ghcr.io/OWNER/REPO` as a legacy same-name fallback. Merely referenced dependencies are not deletion targets. Run `--dry-run` first.

## Requirements

- Bash 4+
- `git`
- GitHub CLI: `gh`
- `gh` authenticated with admin/owner access to the target repository
- `git-lfs` optional but strongly recommended when the repository uses Git LFS
- `xdg-open` optional; after a real reset it opens only settings pages that correspond to detected manual follow-up

Repository deletion requires the `delete_repo` scope:

```bash
gh auth refresh -s delete_repo
```

If the snapshot detects GitHub Packages to delete, package cleanup also requires package admin access. Classic tokens need `read:packages` and `delete:packages`; package cleanup failure stops the reset before repository deletion.

## What it recreates

The tool first inventories the repository's **actual enabled/present state**, builds a repository-specific restore plan, then restores as much captured state as GitHub exposes:

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
- GitHub Packages **Manage Actions access** grants tied to the old repository identity; GitHub does not expose those prior repository grants through a supported API, so linked reset-target containers are deleted while referenced-but-unlinked dependencies remain a manual follow-up
- external cloud/OIDC trust that embeds the old GitHub repository ID

It also intentionally does not recreate issues, pull requests, releases, discussions, stars, forks, old branches/tags, old commit history, or package artifacts deleted as reset targets. Non-default branch protection cannot be functional because those branches are intentionally not recreated.

When something needs manual re-authorization, the tool warns and uses `xdg-open` to open the relevant GitHub settings page when available. For GHCR, `container/REPO` is always written to `package-reset-targets.tsv` as a legacy fallback. The snapshot also enumerates the owner's container packages and adds every package whose GitHub package metadata links it to the repository ID being reset. A container that is merely pulled or referenced by the repository is not deleted unless it is linked to this repository. Registry usage without a concrete package name stays a manual follow-up.

## Layout

The implementation is split by the reset lifecycle so the functional core stays easy to change:

```text
gh-repo-reset                  # small launcher / remote bootstrap
gh-repo-reset.usage.kdl        # declarative CLI contract for usage tooling
mise.toml                      # pinned local tools + task graph
mise-tasks/test                # usage-powered selectable test task
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

The intended flow is `preflight → snapshot → prepare fresh commit → package cleanup → reset → restore → follow-up`. Configuration that GitHub exposes is restored automatically where practical; unreadable or identity-bound credentials stay an explicit manual boundary instead of being silently skipped.

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

Streamed bootstrap fetches the complete `lib/` module tree in one GraphQL request when GitHub exposes every blob intact, with bounded parallel REST as a compatibility fallback. Snapshot reads also run concurrently while the full Git mirror is being created. The default concurrency is 4; set `GH_REPO_RESET_JOBS=N` to tune it for a high-latency connection, but higher values can increase GitHub secondary-rate-limit pressure.

Piped execution still reads destructive confirmation from `/dev/tty`.

## Local development

Cloning the repository is only needed when developing or testing the tool locally. Local development uses [mise](https://mise.jdx.dev/) by JDX with pinned `gh` and `usage` versions; the checkout runs in place and has no local installation workflow.

The committed `gh-repo-reset.usage.kdl` file is the declarative CLI contract. It is used for local validation/tooling only, so remote users do **not** need `usage` installed. The launcher can emit that contract with `gh-repo-reset __usage_spec__`.

Mise's test task uses `#USAGE` arguments, so the available suites get generated help and shell completion:

```bash
mise run test --help
mise run test --suite org
mise run test --suite pipe
mise run test
```

Normal runs are intentionally concise: they report what was actually detected, how many configuration groups will be restored automatically, and only the manual items that apply to that repository. Add `--verbose` for detailed snapshot diagnostics and the full per-feature restore plan.

Run the full local contract + test pass with:

```bash
mise run check
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

Pass `--backup-dir DIR` to override either location. Dry-run snapshots are disposable and do not open browser windows. For a real reset, `git.git/` is the full old remote Git mirror. If the command is run inside a matching target worktree, `local.git/` also backs up the local repository refs and every worktree HEAD before they are rewritten. Every linked worktree must be clean. Secondary worktree directories are preserved and detached onto the fresh root commit; the worktree you ran from becomes the sole local `main` branch. Ignored files are left alone. Keep the safety backup until the recreated repository, local worktrees, integrations, packages, workflows, and deployments have all been verified.

If a destructive run is interrupted after the repository has been recreated, resume from that same backup instead of starting another reset:

```bash
./gh-repo-reset --resume-from /path/to/backup
```

Resume validates the backup, refuses to overwrite an unexpected default-branch commit, retries the initial push without `--force`, continues the detected-state restore, and resets the recorded matching local checkout when that local backup metadata is present.

Easy peasy lemon squeezy — with a safety backup first.