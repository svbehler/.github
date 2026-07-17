# .github — process docs & status tooling

Shared process documentation and the daily status script for all TypeScript
repos. The GitHub Actions CI/automation layer that used to live here was
**retired 2026-07-17** — checks run locally now, and production ships through
a deliberate promote step.

**Current process: [docs/local-first-process.md](docs/local-first-process.md).**

| Path | Purpose |
| --- | --- |
| `docs/local-first-process.md` | How changes ship: local-ci lanes, no-PR integration, staged promotes, hotfix path, dependency policy. |
| `docs/automation-overview.md` | Historical record of the retired 2026-07 automation layer (CI + Claude fixers + Dependabot auto-merge + PostHog lanes). |
| `scripts/pr-queue.sh` | Daily status: open PRs (security/strays), open Dependabot security alerts, and the pending-promote list (`production..main`) per product repo. |
| `historical/` | The retired workflow templates and rollout script, kept for reference. |

The tooling that runs the process (`local-ci.sh`, `agent-merge-main.sh`,
`agent-promote-prod.sh`, fixture tests) lives in `svbehler/agents-config`
(`~/.agents/scripts/`).
