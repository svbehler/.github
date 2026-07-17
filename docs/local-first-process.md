# Local-first process — how changes ship

The GitHub Actions CI/automation layer (2026-07-14 → 2026-07-17) is torn
down, and its docs/templates were deleted from this repo — git history has
them. Every gate now runs locally; GitHub is a remote and a ledger, not an
execution environment. This doc is the one-page reference for how a change
travels from idea to production.

Tooling lives in `svbehler/agents-config` (`~/.agents/scripts/`); this doc and
the daily queue script live here (`svbehler/.github`).

## The phases

A change travels through four phases. Two of them are gates with names used
everywhere in tooling and docs: **pre-merge** (guards `main`) and
**pre-promote** (guards `production`).

```
Phase 1 TASK        worktree ──▶ implement ──▶ commit
Phase 2 PRE-MERGE   local-ci pre-merge lane ──▶ /code-review + fallow audit
                    ──▶ human diff review + approval
                    ──▶ agent-merge-main.sh (--no-ff merge, pushes main)
                                                              [ships nothing]
                     ⋮  tasks accumulate on main
Phase 3 PRE-PROMOTE agent-review-promote.sh
                    ──▶ HTML review of production..main (summary, diffstat,
                        risk-flagged file diffs) ──▶ HUMAN APPROVAL, scoped
                        to the exact SHA (no bypass flag exists)
                    agent-promote-prod.sh (refuses without that approval)
                    ──▶ pending list (git log production..main) + confirm
                    ──▶ cold build + full e2e in a FRESH worktree
                    ──▶ Neon migration preflight (auto when migrations pending)
Phase 4 SHIP        Vercel:   vercel deploy --prod --skip-domain (staged, live
                              domains untouched) → smoke staged URL →
                              vercel promote → live smoke → AUTO-ROLLBACK
                    targical: d1 migrations --remote → wrangler deploy api+web
                              from the verified worktree → prod smoke
                    ──▶ production ref fast-forwards + pushes ONLY when green
```

- `main` is a **safe integration branch**: merging and pushing it deploys
  nothing, on every repo. Integrate freely.
- `production` is a **ledger**: it always equals what is live, because the
  promote script moves it only after deploy + smoke succeed.
- **No PRs.** One `--no-ff` merge commit per task is the change history
  (`git log --first-parent main`); `git log production..main` is always the
  exact list of merged-but-not-shipped changes.

### Phase 2 — the pre-merge gate (every merge into `main`)

| Step | What |
| --- | --- |
| pre-merge lane | `local-ci.sh` (currently named "fast lane" in the script): frozen install, lint, typecheck, unit tests, `prettier --check`, warm build — gates a repo doesn't define are listed loudly, never skipped silently. Run by `agent-merge-main.sh`; `SKIP_LOCAL_CI=1` for docs/config tier (recorded as a git note on the merge commit). |
| automated review | `/code-review` on the task diff + changeset-scoped `fallow audit` (delta vs `main` only). Safe findings are auto-applied as their own commits; the rest are flagged. *(Skill in progress — until it lands, run `/code-review` manually.)* |
| human approval | diff review of the task branch (including any auto-applied commits) + explicit go-ahead before `agent-merge-main.sh`. |

### Phase 3 — the pre-promote gate (every production ship)

| Step | What |
| --- | --- |
| **human review** | `agent-review-promote.sh` generates a self-contained HTML review of everything in `production..main`: shipped-task list, diffstat, per-file diffs with migrations/auth/payments/env/deploy/deps flagged and expanded first, plus an optional AI summary. Approving (a `y` on an interactive terminal — agents cannot self-approve) records an approval **scoped to the exact target SHA**; one more commit on main makes it stale and the review runs again. |
| approval enforcement | `agent-promote-prod.sh` refuses to run without the recorded approval and consumes it on success. There is **deliberately no bypass flag** — the review guards the ship decision itself, and generating + approving one takes seconds even mid-emergency. `--yes` only skips the interactive re-confirmation. |
| pre-promote lane | `local-ci.sh --pre-promote`, run by `agent-promote-prod.sh` in a **fresh worktree** with caches cleared: cold build + full Playwright suite incl. axe gates. `--skip-checks` for emergencies only — its use is recorded in the promote log and a git note. |
| migration preflight | automatic when the promote carries migration files: dry-runs pending migrations against a throwaway Neon branch of prod data. `--neon-preflight` forces, `--skip-preflight` skips loudly (also recorded). |

Every promote (with any `--skip-*` flags used) is appended to
`~/.local/state/agent-promotes.log` and noted on the promoted commit
(`git notes --ref=promote`) — the production branch says *what* is live,
the log says *how it got there*.

### Phase 4 — ship, verify, roll back

| Step | What |
| --- | --- |
| staged deploy (Vercel) | the deployment is built and smoked on Vercel's real builder + runtime **before** the live domains see it — catches platform-runtime failures (e.g. sharp 0.35 breaking only inside Vercel's function bundle, 2026-07-17) that no local check can observe. On a failed staged build the script fetches the remote build-log tail (`vercel inspect --logs`) automatically. |
| prod smoke + auto-rollback | repo's `scripts/prod-smoke.sh` against the live domains; on failure Vercel repos roll back automatically (`vercel rollback`) and targical rolls back each deployed app automatically (`wrangler rollback`, with manual commands printed only if a rollback itself fails). |

Standing backstop outside the phases: the `.githooks/pre-push` hook — gitleaks
on every push, typecheck/lint/unit on pushes of the deploy-coupled refs
(`production`, `staging`).

## Per-platform deploy mechanics

- **Vercel repos (xpo-inventory, xpo-market, certaince):** the projects' git
  integrations are **disconnected** — no push deploys anything, the staged CLI
  deploy inside `agent-promote-prod.sh` is the only deploy path. The prod DB
  migration (`drizzle-kit migrate`) still runs inside the Vercel build
  (`vercel.json` buildCommand), i.e. during the *staged* build — so a migrate
  failure surfaces before the live domains are touched, but a *successful*
  migration is live before promote. **Migrations must therefore stay
  expand-contract compatible** (the previous code keeps working against the
  new schema); use `--neon-preflight` to dry-run risky migrations against a
  branch of prod data first. Each repo carries `.vercelignore` (CLI deploys
  upload the working tree — env files must never ship) and
  `scripts/prod-smoke.sh` (with a URL argument: smoke that staged deployment;
  without: smoke the live domains).

  **CLI-deploy gotchas** (each cost a failed staged build on 2026-07-17):
  - The build container has **no `.git`** and no usable git metadata — tools
    that read the commit (PostHog sourcemap releases) need it passed
    explicitly; the promote script sends `--build-env STAGED_GIT_COMMIT_SHA`.
  - All `VERCEL_GIT_*` env vars **exist but are EMPTY STRINGS** on CLI
    deploys, so `?? fallback` chains never fall through — treat `""` as unset
    (see the repos' `next.config.ts` `envOrUndefined` helper).
  - A staged-build failure's real error lives in the remote build log, not the
    local CLI stream — `vercel inspect --logs <deployment-url>` fetches it
    (the promote script now does this automatically on failure).
- **targical (Cloudflare Workers):** deploys run from the verified pre-promote
  worktree via the local wrangler OAuth session (no CI, no Actions secrets):
  D1 migrations `--remote`, `wrangler deploy` for `apps/api` and `apps/web`,
  then the smoke curls. A staged variant (`wrangler versions upload` → smoke
  the preview URL → `wrangler versions deploy`) is a possible future upgrade.

## Hotfixes and divergence

Default: fix on `main` through the normal task flow, then promote immediately.
Emergency-only (main carries unshippable WIP): branch from `production`, fix,
deploy via the promote script with `--target`, then merge the fix back into
`main`. The promote script refuses to run while `production` has commits that
`main` lacks — reconcile first.

## Dependencies

Dependabot version updates are **off**; security alerts + security-update PRs
stay on (the one kind of inbound PR left). Handling a security PR: check the
branch out in a worktree, run `local-ci.sh`, merge via `agent-merge-main.sh`
(GitHub marks the PR merged), ship with the next promote. Routine dep bumps
are a local chore on your schedule — bump native/binary modules (sharp,
esbuild, bcrypt…) **alone** and promote them separately: their failure mode
is the platform-runtime class that only the staged deploy can catch.

## Code health & production errors (the recurring audit)

Fallow and PostHog error triage no longer run per-change — the pre-promote
lane is ship-blockers only. Instead, a recurring local audit of `main` per
product repo turns findings into ordinary task branches that re-enter the
flow at Phase 1 and pass the same pre-merge gate as any other change:

1. **Sweep** — fallow repo-wide (deltas vs the last audit's baselines) + a
   PostHog error-tracking sweep via MCP (new/regressed issues over the last 7
   days, ranked by occurrence count and users affected).
2. **Triage** — each finding is classified: *fixable now* (clear root cause,
   bounded change), *needs investigation* (repro unclear), or *accepted*
   (annotate/baseline it so the next sweep stays quiet).
3. **Fix branches** — every *fixable now* finding becomes its own task
   worktree (`audit-<slug>`), implemented by a local agent, one finding per
   branch so review and revert stay surgical. PostHog fixes cite the issue ID
   and error signature in the commit body; the issue is marked resolved only
   after the fix has shipped in a promote.
4. **Same gate as everything else** — each branch goes through the full
   pre-merge gate (lane + /code-review + fallow + human approval) and rides a
   normal promote. The audit itself never merges or ships anything.

The fallow safety rules (guard config-string-wired files, cold-build
verification for dead-code waves) apply as written in the global CLAUDE.md.

## Daily status & worktree hygiene

- `bash ~/projects/dot-github/scripts/pr-queue.sh` — the GitHub-side view:
  OPEN PRS (security PRs / strays), SECURITY (open Dependabot alerts across
  repos), PENDING PROMOTE (`production..main` per product repo).
- `agent-status.sh [repo…]` — the local view, read-only: pending promotes
  with their review state (approved / review needed), every task branch
  (worktree, dirty/clean, ahead of main or SWEEPABLE, last-commit age),
  leftover `promote-check-*` worktrees from failed promotes, unpushed main,
  and stale review approvals.
- `agent-sweep.sh` — reaps everything status marks SWEEPABLE: merged task
  branches lose their worktree, local branch, and remote branch. Ancestry-
  based (safe because every merge is a local `--no-ff` merge); dirty
  worktrees refuse and are left intact. Runs best-effort at the start of
  every new task (`agent-start-worktree.sh`), so leftovers never pile up.

## What was removed (2026-07-17)

All workflows in xpo-inventory, xpo-market, certaince, targical, emily-kirby,
tombox (CI, e2e, fallow, both Claude fixers, PR review, Dependabot auto-merge
+ major triage, PostHog error lanes, vercel-deploy-watch), all
`dependabot.yml` files, and the per-repo Actions secrets
(`CLAUDE_CODE_OAUTH_TOKEN`, `POSTHOG_API_KEY`, `CLOUDFLARE_*`, stale
`VERCEL_*`). osd-website / isaco-website (delivered client sites, Actions
disabled) were not touched.

The retired layer's record (`docs/automation-overview.md`), the archived
workflow templates (`historical/`), and the PR-flow helper scripts
(`agent-ship-pr.sh`, `agent-finish-pr.sh` in agents-config) were deleted
2026-07-17 — the local CI process is the only flow going forward; git
history preserves all of it.
