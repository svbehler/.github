# CI/CD auto-fix setup — how it all works

One-page explanation of the automation running across the TypeScript repos:
what the moving parts are, how a dependency bump or a broken push flows
through the system, what still needs a human, and how to operate it.

Built 2026-07-14. Templates and scripts live in this repo (`svbehler/.github`);
each active repo carries its own copy of the workflow files.

## The one-paragraph version

Dependabot opens dependency PRs on Mondays (weekly on the active products,
monthly on low-churn repos). CI runs on every PR and every
push to main. When CI fails, a Claude fixer (running on the Anthropic
**subscription**, not API billing) reads the failure logs, fixes the root
cause, commits to the branch, and reports what it did. Green minor/patch
group PRs merge themselves. Major bumps never auto-merge — a weekly triage
run comments a MERGE/HOLD verdict on each so the human decision is
pre-chewed. `scripts/pr-queue.sh` shows everything waiting on a human, in
one screen.

## Repos

| Set | Repos | Automation |
| --- | --- | --- |
| Active (8) | xpo-inventory, xpo-market, certaince, targical, emily-kirby, bc-to-datev (local dir `bc-to-datev-csv`), tempo-website, ai-company-profiler | Full: CI + Dependabot + fixers + auto-merge + major triage |
| Silenced (2) | osd-website, isaco-website | **Delivered live client projects — do not touch.** Actions is disabled repo-wide (which also stops Dependabot), zero commits allowed: a push to main would trigger a Vercel production deploy. The workflow files are present but inert. Revive with `gh api -X PUT repos/svbehler/<repo>/actions/permissions -F enabled=true`. |
| Wave 3 (later) | tombox, aeo-platform, ai-content, message-mgr, certaince-news-accumulator, xtm-outreach, mafu-sherpa-* | Rolled out via `scripts/rollout.sh` when they get GitHub remotes. The two SHERPA-\*-PTE repos are AL-Go/Business Central and out of scope. |

## The pieces

Each active repo has these files under `.github/`:

| File | What it does |
| --- | --- |
| `workflows/ci.yml` | The CI workflow. Repos without their own CI call the shared `reusable-ci.yml` from this repo (pnpm install → lint → typecheck → test → check → build, each `--if-present`). Repos with pre-existing CI (xpo-inventory, xpo-market, certaince, targical) kept theirs, extended with a `pull_request` trigger, a build step, and concurrency. **The workflow name `CI` is load-bearing** — everything below listens for it by name. |
| `dependabot.yml` | npm + github-actions updates. Cadence differs by repo: **weekly (Monday)** on the active products (xpo-inventory, xpo-market, certaince, targical), **monthly** on the low-churn repos (emily-kirby, bc-to-datev, tempo-website, ai-company-profiler) to keep noise down. Minor+patch bumps are **grouped into one PR** named `minor-and-patch` — that group name is also load-bearing. Majors arrive as individual PRs. |
| `workflows/dependabot-auto-merge.yml` | When a CI `workflow_run` succeeds on a branch containing `minor-and-patch`, squash-merges the PR. This replaces GitHub's native auto-merge and branch rulesets, which the free plan doesn't offer on private repos. |
| `workflows/fix-dependabot.yml` | Claude fixer for Dependabot PRs that break CI. Adapts the code to the new dependency version (type changes, renamed APIs, config migrations), verifies against the repo's actual CI checks, commits `auto-fix:` to the PR branch, and comments. If the bump needs a real migration decision, it comments an outline instead of committing. |
| `workflows/auto-fix-ci.yml` | Claude fixer for everything else that breaks CI (pushes to main, feature PRs). Commits to the PR branch, or — for failures on main — opens a `claude/ci-fix-<runid>` PR. Skips `dependabot/*` and `claude/*` branches. |
| `workflows/dependabot-major-triage.yml` | Weekly (Mon 07:00 UTC) + manual dispatch. A free gate job lists open major PRs and skips Claude entirely when there are none. Otherwise Claude reads changelogs, greps the repo for affected usage, and comments a `**Verdict: MERGE**` or `**Verdict: HOLD**` (marked `<!-- major-triage -->`) on each untriaged major. Read-only: never touches code, never merges. |

In this repo additionally:

| File | What it does |
| --- | --- |
| `scripts/pr-queue.sh` | The human review queue (see [Operating it](#operating-it)). |
| `scripts/rollout.sh` | Copies the templates into a new repo, pushes, reminds about the one-time steps. Refuses to overwrite an existing `ci.yml`. |
| `templates/*` | Sources for all per-repo files above. |

## How a failure flows through the system

**Dependabot group PR (the common Monday case):**

```
Dependabot opens grouped PR ──▶ CI runs
                                  │
                        green ◀───┴───▶ red
                          │              │
              auto-merge squashes   fix-dependabot.yml:
                                    Claude reads logs, adapts code,
                                    commits "auto-fix:", comments
                                         │
                                    ⚠ CI does NOT re-run by itself (see gap below)
                                         │
                                    close/reopen the PR (pr-queue.sh --nudge)
                                         │
                                    CI re-runs ──▶ green ──▶ auto-merge
```

**Push to main breaks CI:** `auto-fix-ci.yml` opens a `claude/ci-fix-<runid>`
PR with the fix. You review and merge it like any PR.

**Major bump:** sits until Monday 07:00 UTC (or a manual dispatch), gets a
MERGE/HOLD verdict comment, then waits for you. MERGE = the breaking changes
don't touch this repo's actual usage; HOLD = migration work needed first,
described in the comment.

This flow was validated end-to-end live on xpo-inventory PR #25: a
47-package group bump broke CI twice (Stripe API version + prettier 3.9
style drift), the fixer repaired both, and auto-merge landed it.

## The PostHog error lane (production errors, 4 repos)

Production runtime errors get the same treatment as CI failures on the
four PostHog-instrumented product repos (targical, xpo-inventory,
xpo-market, certaince). Two lanes, nothing auto-merges:

- **Event lane:** a PostHog error-tracking alert (issue created /
  reopened) fires a webhook destination that POSTs a
  `repository_dispatch` of type `posthog-error` to the repo.
  `workflows/fix-posthog-error.yml` dedupes against open issues/PRs by
  PostHog issue id, then triages: app bug with a confident root cause →
  fix PR on `claude/posthog-<id>`; infra/transient or unclear → GitHub
  issue labeled `posthog-error`.
- **Weekly backstop:** `workflows/posthog-error-triage.yml` sweeps the
  last 7 days of PostHog error tracking (staggered Mondays: targical
  06:00, xpo-inventory 06:15, xpo-market 06:30, certaince 06:45 UTC),
  catching slow-burn regressions the new-issue alert misses.

**How a production error flows through the event lane:**

```
PostHog error tracking: issue created / reopened
                     │
                     ▼
      alert hog function POSTs repository_dispatch
      "posthog-error" (the shared PAT lives only in
      this webhook's Authorization header)
                     │
                     ▼
   fix-posthog-error.yml: dedupe by PostHog issue id
                     │
        known ◀──────┴──────▶ new
          │                    │
   comments the           triages the code path
   recurrence and              │
   stops         app bug ◀─────┴─────▶ infra/transient/unclear
                    │                        │
          fix PR on claude/           GitHub issue labeled
          posthog-<id> — you          posthog-error — you
          review and merge            decide the next step
```

The weekly sweep is the same triage applied to everything PostHog saw
in the last 7 days, minus the webhook hop — it queries PostHog directly
with the read-only `POSTHOG_API_KEY` and compares against the existing
`posthog-error` issues before filing anything.

Parameterized templates for both live in `templates/` (placeholders
`{{REPO_DESC}}`, `{{TRIAGE_DESC}}`, `{{CRON}}`,
`{{POSTHOG_PROJECT_ID}}`) — deliberately NOT copied by `rollout.sh`;
substitute the placeholders manually per repo. Per-repo requirements
beyond the standard ones: a `POSTHOG_API_KEY` secret (read-only PostHog
personal key: `query:read` + `error_tracking:read`), a `posthog-error`
label, a PostHog alert hog function holding a fine-grained GitHub PAT
(Contents: RW) in its Authorization header, and exception capture
actually enabled in the app. One shared PAT covers all four repos;
regenerating it invalidates the old value immediately — re-PATCH all
four PostHog destinations (a PATCH must resend the full `inputs`
object). Detailed runbook: `targical/docs/posthog-error-automation.md`.

## The known gap: fixer commits don't retrigger CI (decision D3)

Fixers push with the workflow's built-in `GITHUB_TOKEN`, and GitHub
deliberately does not run workflows for events caused by that token — its
loop-prevention. Upside: a fixer can never trigger itself into an infinite
loop. Downside: after a fixer pushes to a Dependabot PR, the new commit has
**no CI run**, so auto-merge never fires on its own.

The remedy is a human-actor nudge: closing and reopening the PR re-triggers
CI. `pr-queue.sh --nudge` does this for every stalled PR in one command.
Alternatives (not adopted, to keep the loop-prevention): a fine-grained PAT
for fixer pushes, or letting the fixer close/reopen as its final step.

## Guardrails

- **Cost:** all Claude runs use `claude_code_oauth_token` (subscription via
  `claude setup-token`) — no API billing. A fixer run is roughly $2 of
  API-equivalent usage drawn from the Max subscription.
- The Claude GitHub App has no `workflows: write` — a fixer can never modify
  workflow files. Fixers never merge, rebase, or force-push.
- Routing is by **branch prefix** (`dependabot/*`, `claude/*`), never by
  actor — a human rerun/reopen changes the triggering actor, prefixes don't.
- Auto-merge requires both a green CI `workflow_run` **and** the
  `minor-and-patch` group name in the branch. Majors can't slip through.
- Fixers skip fork PRs, and the Dependabot fixer checks out the untrusted PR
  head into a `pr-head/` subdirectory per the action's security guide (the
  trusted base ref stays at the workspace root).
- The triage workflow is read-only by prompt and by allowlist (no
  Edit/Write, `gh`/`npm view`/read-only shell commands).
- Turn caps: 40 (general fixer), 60 (Dependabot fixer), 30 (triage). The
  fixer jobs provision pnpm + Node and run `pnpm install` **before** Claude
  starts — a bare runner burns the whole budget on missing tools.

## Operating it

Day-to-day there is exactly one command:

```
bash ~/projects/dot-github/scripts/pr-queue.sh          # what needs me?
bash ~/projects/dot-github/scripts/pr-queue.sh --nudge  # unstick stalled group PRs
```

It lists open PRs across all 8 active repos in four buckets:

| Bucket | Meaning | What you do |
| --- | --- | --- |
| FIX | `claude/*` fixer PRs | Review the diff, merge or close. |
| MAJOR | Dependabot majors, verdict in brackets | `[MERGE]` → merge when convenient. `[HOLD]` → read the comment, do the migration first. `[untriaged]` → wait for Monday or dispatch the triage manually. |
| STALLED | Group PRs the fixer patched but CI never re-ran (the D3 gap), or red group PRs | Run `--nudge`. |
| OTHER | Your own / anything else | Business as usual. |

Reading the `ci=` column: it aggregates **all** checks on the head commit,
including Vercel preview deploys — `ci=fail` can mean "our CI is green but
the Vercel preview failed". `ci=none` means no checks ran on the head commit
(usually a fixer commit waiting for a nudge).

A suggested Monday routine: let Dependabot + fixers + auto-merge do their
thing in the morning, run `pr-queue.sh` after lunch, `--nudge` the stalled
ones, merge the green fixer PRs and the `[MERGE]` majors you care about.

**Email is not the signal — this queue is.** The active repos are unwatched
(bot PRs/comments/merges don't email; participating and @mentions still do),
and Actions "run failed" emails can be turned off under GitHub Settings →
Notifications → Actions (UI-only; failures still show as red `ci=` here).

### Manual levers

```
# Re-run the major triage on one repo (e.g. after new majors appear mid-week)
gh workflow run dependabot-major-triage.yml -R svbehler/<repo>

# Approve a first-time contributor gate (some Dependabot runs end
# "action_required"; the API 403s for non-fork PRs — use the run page UI)
#   → open the run and click "Approve and run"

# Roll the whole setup out to a new repo
bash ~/projects/dot-github/scripts/rollout.sh <path-to-local-checkout>
```

## Per-repo requirements (for new rollouts)

1. pnpm with a `packageManager` field in package.json, and standard script
   names (`lint` / `typecheck` / `test` / `check` / `build` — any subset).
   Repos whose `test` script is Playwright-only set `run-tests: false` in
   the CI caller and expose a `test:unit` instead (see xpo-inventory).
2. Claude GitHub App installed (`claude /install-github-app`).
3. Repo secret `CLAUDE_CODE_OAUTH_TOKEN` — mint with `claude setup-token`
   in a normal terminal, set with `gh secret set CLAUDE_CODE_OAUTH_TOKEN -R
   svbehler/<repo>` **interactively; never pass the token as a command-line
   argument and never run setup-token inside an agent session.** GitHub
   secrets are write-only, so keeping no copy of the token is fine.
4. Builds that need env vars at build time: add them as Actions
   secrets/vars (`secrets: inherit` passes them through the reusable
   workflow). Payload CMS repos are the known hard case — `next build`
   wants Postgres + `PAYLOAD_SECRET`, which is why osd/isaco builds can't
   pass in plain CI (decision shelved along with those repos).

## Known rough edges

- **Duplicate fixer PRs on main failures:** the general fixer opens one PR
  per failed run, so the same root cause failing twice produces
  near-duplicate PRs (seen on certaince #9/#10). Merge one, close the rest.
  A dedupe guard is a candidate improvement.
- **Cron decay:** GitHub disables scheduled workflows after 60 days without
  repo activity. On dormant repos, re-enable the triage from the Actions tab.
- **Turn-cap "failures" that aren't:** a triage or fixer run can complete
  its actual work and still be marked failed because it hit its turn cap
  while summarizing. Check whether the comments/commits landed before
  re-running.
- **First seed of a big backlog:** ~7 majors in one repo is about the limit
  of the triage job's 30 turns. Already-marked PRs are skipped, so simply
  dispatching again picks up the remainder.

## Design decisions (for the record)

| # | Decision |
| --- | --- |
| D1 | Subscription auth (`claude_code_oauth_token`), not API keys. |
| D2 | Opus as the fixer/triage model. |
| D3 | Default `GITHUB_TOKEN` for fixer pushes — accepts the no-retrigger gap in exchange for structural loop-safety. |
| D4 | Auto-merge only the minor+patch group; majors always wait for a human. |
| D5 | Piloted on xpo-inventory, then fanned out. |

Full background: the "CI/CD Auto-Fix Proposal" artifact (2026-07).
