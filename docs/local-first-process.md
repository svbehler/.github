# Local-first process — how changes ship

The GitHub Actions CI/automation layer (2026-07-14 → 2026-07-17, see
[automation-overview.md](automation-overview.md)) is torn down. Every gate now
runs locally; GitHub is a remote and a ledger, not an execution environment.
This doc is the one-page reference for how a change travels from idea to
production.

Tooling lives in `svbehler/agents-config` (`~/.agents/scripts/`); this doc and
the daily queue script live here (`svbehler/.github`).

## The flow

```
task worktree ──▶ local-ci.sh fast lane ──▶ /code-review + human diff review
    ──▶ agent-merge-main.sh (--no-ff merge, pushes main)      [ships nothing]
                     ⋮  tasks accumulate on main
agent-promote-prod.sh                                          [the ship gate]
    ──▶ pending list (git log production..main) + confirm
    ──▶ pre-promote lane in a FRESH worktree (cold build + full e2e)
    ──▶ Vercel repos:  vercel deploy --prod --skip-domain (staged, live
        domains untouched) → smoke the staged URL → vercel promote →
        live smoke → AUTO-ROLLBACK on failure
    ──▶ targical:      d1 migrations --remote → wrangler deploy api+web
        from the verified worktree → prod smoke
    ──▶ production ref fast-forwards + pushes ONLY after everything is green
```

- `main` is a **safe integration branch**: merging and pushing it deploys
  nothing, on every repo. Integrate freely.
- `production` is a **ledger**: it always equals what is live, because the
  promote script moves it only after deploy + smoke succeed.
- **No PRs.** One `--no-ff` merge commit per task is the change history
  (`git log --first-parent main`); `git log production..main` is always the
  exact list of merged-but-not-shipped changes.

## The gates

| Gate | When | What |
| --- | --- | --- |
| local-ci fast lane | every merge into main (run by `agent-merge-main.sh`; `SKIP_LOCAL_CI=1` for docs/config) | frozen install, lint, typecheck, unit tests, `prettier --check`, warm build |
| review | before integration | local `/code-review` + human diff review of the task branch |
| pre-promote lane | every production ship (run by `agent-promote-prod.sh`; `--skip-checks` for emergencies) | **cold** build in a fresh worktree (caches cleared) + full Playwright suite incl. axe gates |
| staged deploy (Vercel) | every production ship | the deployment is built and smoked on Vercel's real builder + runtime **before** the live domains see it — catches platform-runtime failures (e.g. sharp 0.35 breaking only inside Vercel's function bundle, 2026-07-17) that no local check can observe |
| prod smoke + auto-rollback | after promote | repo's `scripts/prod-smoke.sh` against the live domains; on failure Vercel repos roll back automatically (`vercel rollback`), targical prints the `wrangler rollback` commands |
| pre-push hook | pushes of `production` (and `staging`) | gitleaks always (all branches) + typecheck/lint/unit on the deploy-coupled refs |

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

Fallow and PostHog error triage no longer run per-change — the promote lane is
ship-blockers only. Instead, a recurring local audit of `main` per product
repo (fallow repo-wide deltas + a PostHog error sweep via MCP over the last 7
days) turns findings into ordinary task branches that ride the normal flow.
The fallow safety rules (guard config-string-wired files, cold-build
verification for dead-code waves) apply as written in the global CLAUDE.md.

## Daily status

`bash ~/projects/dot-github/scripts/pr-queue.sh` — OPEN PRS (security PRs /
strays), SECURITY (open Dependabot alerts across repos), PENDING PROMOTE
(`production..main` per product repo).

## What was removed (2026-07-17)

All workflows in xpo-inventory, xpo-market, certaince, targical, emily-kirby,
tombox (CI, e2e, fallow, both Claude fixers, PR review, Dependabot auto-merge
+ major triage, PostHog error lanes, vercel-deploy-watch), all
`dependabot.yml` files, and the per-repo Actions secrets
(`CLAUDE_CODE_OAUTH_TOKEN`, `POSTHOG_API_KEY`, `CLOUDFLARE_*`, stale
`VERCEL_*`). osd-website / isaco-website (delivered client sites, Actions
disabled) were not touched. Rationale and the full history of the old layer:
[automation-overview.md](automation-overview.md).
