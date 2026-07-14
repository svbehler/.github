# .github — shared CI/CD automation

Shared CI definition and rollout templates for all TypeScript repos.
Full background: the "Automated CI/CD failure fixing" proposal (2026-07).

## What lives here

| Path | Purpose |
| --- | --- |
| `.github/workflows/reusable-ci.yml` | The one CI definition every repo calls: pnpm install → lint → typecheck → test → check → build (each `--if-present`). |
| `templates/ci.yml` | Per-repo caller. The workflow name `CI` is load-bearing — both fixers trigger on it. |
| `templates/dependabot.yml` | Weekly, minor+patch grouped into one PR; also tracks GitHub Actions versions. |
| `templates/dependabot-auto-merge.yml` | Auto-merges green non-major Dependabot PRs (gated by the required-check ruleset). |
| `templates/auto-fix-ci.yml` | Claude fixer for failed CI runs (non-Dependabot). Commits to the PR branch, or opens a `claude/` PR for failures on main. |
| `templates/fix-dependabot.yml` | Claude fixer for Dependabot PRs that break CI. Runs from `workflow_run` (base context) with the PR head in a subdirectory, per the action's security guide. |
| `scripts/rollout.sh` | Copies the templates into a repo, pushes, enables auto-merge, creates the main ruleset. |

## Per-repo requirements

1. `pnpm` with a `packageManager` field, and standard script names
   (`lint` / `typecheck` / `test` / `check` / `build` — any subset).
2. Claude GitHub App installed (`claude /install-github-app`).
3. Repo secret `CLAUDE_CODE_OAUTH_TOKEN` (subscription token from
   `claude setup-token`). Set interactively — never pass the value as a
   command-line argument:

   ```
   gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>
   ```

4. Builds that need env vars at build time: add them as repo Actions
   secrets/vars; `secrets: inherit` in the caller passes them through.

## Guardrails (summary)

- Fix commits are pushed with the workflow `GITHUB_TOKEN`, which does not
  re-trigger workflows — GitHub's built-in loop prevention. The fixer
  re-runs the checks itself and reports results in its PR comment.
- Fixers skip fork PRs, `claude/` branches, and (in the general fixer)
  Dependabot branches.
- The Claude app has no `workflows: write`, so the fixer can never modify
  workflow files. It never merges, rebases, or force-pushes.
- The main ruleset requires the `ci / checks` status but gives repository
  admins an always-bypass, so direct pushes to main keep working.
