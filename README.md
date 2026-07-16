# .github — shared CI/CD automation

Shared CI definition and rollout templates for all TypeScript repos.
**Full explanation of the whole setup: [docs/automation-overview.md](docs/automation-overview.md).**
Background: the "Automated CI/CD failure fixing" proposal (2026-07).

## What lives here

| Path | Purpose |
| --- | --- |
| `.github/workflows/reusable-ci.yml` | CI definition for repos that have none: pnpm install → lint → typecheck → test → check → build (each `--if-present`), plus a PR-only, non-blocking changeset-scoped `fallow audit` lane (opt out with `run-fallow: false`). Repos with their own `ci.yml` keep it — the fixers only require a workflow named `CI`. |
| `templates/ci.yml` | Per-repo caller for repos without existing CI. The workflow name `CI` is load-bearing — both fixers trigger on it. Existing CI must add a `pull_request` trigger and a build step. |
| `templates/dependabot.yml` | Weekly, minor+patch grouped into one PR; also tracks GitHub Actions versions. |
| `templates/dependabot-auto-merge.yml` | Merges Dependabot minor+patch group PRs after a green CI run (majors are individual PRs and never auto-merged). |
| `templates/auto-fix-ci.yml` | Claude fixer for failed CI runs (non-Dependabot). Commits to the PR branch, or opens a `claude/` PR for failures on main. Failures needing a human (secrets, infrastructure) become issues labeled `ci-failure` when there is no PR to comment on. |
| `templates/fix-dependabot.yml` | Claude fixer for Dependabot PRs that break CI. Runs from `workflow_run` (base context) with the PR head in a subdirectory, per the action's security guide. |
| `templates/dependabot-major-triage.yml` | Weekly (Mon 07:00 UTC) Claude triage of open Dependabot major PRs: comments a `MERGE`/`HOLD` verdict per PR. A free gate job skips Claude entirely when no majors are open. Read-only — never touches code. |
| `scripts/rollout.sh` | Copies the templates into a repo, pushes, and (best effort) creates the main ruleset. |
| `scripts/pr-queue.sh` | The human review queue: lists open PRs across all active repos, categorized (fixer PRs, untriaged/triaged majors, stalled group PRs, other), then automation-filed issues (`posthog-error` / `ci-failure` / `incident`) and a 7-day health sweep (failed scheduled runs, disabled workflows, open Dependabot security alerts). `--nudge` close/reopens stalled group PRs so CI re-runs and auto-merge can proceed. |

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
- Auto-merge is gated on a successful CI `workflow_run` and on the
  `minor-and-patch` group branch name — majors never auto-merge.
- Required-check rulesets and GitHub's native auto-merge need GitHub Pro
  on private repos. `rollout.sh` creates the ruleset where the plan
  allows it (admin always-bypass keeps direct pushes to main working);
  everywhere else the workflow-level gating above stands alone.
