# .github — process docs & status tooling

Shared process documentation and the daily status script for all TypeScript
repos. The GitHub Actions CI/automation layer that used to live here was
**retired 2026-07-17** — checks run locally now, and production ships through
a reviewed, deliberate promote step. The retired layer's docs and workflow
templates were deleted 2026-07-17; git history has them if ever needed.

**Current process: [docs/local-first-process.md](docs/local-first-process.md).**

| Path | Purpose |
| --- | --- |
| `docs/local-first-process.md` | How changes ship: local-ci lanes, no-PR integration, the HTML promote review gate, staged promotes, hotfix path, dependency policy. |
| `scripts/pr-queue.sh` | Daily GitHub-side status: open PRs (security/strays), open Dependabot security alerts, and the pending-promote list (`production..main`) per product repo. The local-side counterpart (`agent-status.sh`) lives with the tooling. |

The tooling that runs the process (`local-ci.sh`, `agent-merge-main.sh`,
`agent-review-promote.sh`, `agent-promote-prod.sh`, `agent-status.sh`,
`agent-sweep.sh`, fixture tests) lives in `svbehler/agents-config`
(`~/.agents/scripts/`).
