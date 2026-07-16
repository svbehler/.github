#!/usr/bin/env bash
# Roll the standard CI + auto-fix setup out to a repo.
#
# Usage: rollout.sh <path-to-local-repo-checkout>
#
# Copies the template files, commits and pushes them, and (best effort)
# creates the main ruleset (required "CI" check with admin bypass so
# direct pushes to main keep working). Rulesets need GitHub Pro on
# private repos; without them, dependabot-auto-merge.yml still gates
# merges on a green CI run in workflow logic.
#
# NOT done by this script (one-time, interactive):
#   - Installing the Claude GitHub App on the repo (claude /install-github-app)
#   - Setting the CLAUDE_CODE_OAUTH_TOKEN secret:
#       gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>
#     (interactive prompt; never pass the token as an argument)

set -euo pipefail

TEMPLATES_DIR="$(cd "$(dirname "$0")/../templates" && pwd)"
# Check-run name produced by templates/ci.yml calling the reusable workflow.
# Verified on the pilot repo; update here if the job names ever change.
REQUIRED_CHECK="ci / checks"

REPO_DIR="${1:?usage: rollout.sh <path-to-local-repo-checkout>}"
cd "$REPO_DIR"

REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "==> Rolling out to $REPO_SLUG"

if [ -n "$(git status --porcelain | grep -v '^??' || true)" ]; then
  echo "ERROR: $REPO_DIR has uncommitted tracked changes; commit or stash first." >&2
  exit 1
fi

mkdir -p .github/workflows
if [ -e .github/workflows/ci.yml ]; then
  echo "==> Existing ci.yml found — keeping it. Verify manually that it:"
  echo "    - is named 'CI' (the fixers trigger on that name)"
  echo "    - has a pull_request trigger (Dependabot/fix PRs need checks)"
  echo "    - runs the build (the Vercel/Cloudflare front-run)"
else
  cp "$TEMPLATES_DIR/ci.yml" .github/workflows/ci.yml
fi
cp "$TEMPLATES_DIR/auto-fix-ci.yml" .github/workflows/auto-fix-ci.yml
cp "$TEMPLATES_DIR/fix-dependabot.yml" .github/workflows/fix-dependabot.yml
cp "$TEMPLATES_DIR/dependabot-auto-merge.yml" .github/workflows/dependabot-auto-merge.yml
cp "$TEMPLATES_DIR/dependabot-major-triage.yml" .github/workflows/dependabot-major-triage.yml
cp "$TEMPLATES_DIR/pr-review.yml" .github/workflows/pr-review.yml
cp "$TEMPLATES_DIR/dependabot.yml" .github/dependabot.yml

git add .github
if git diff --staged --quiet; then
  echo "==> Files already up to date; skipping commit."
else
  git commit -m "ci: add standard CI, Dependabot config, and auto-fix workflows"
  git push
fi

if gh api "repos/$REPO_SLUG/rulesets" -q '.[].name' | grep -qx "main-required-ci"; then
  echo "==> Ruleset main-required-ci already exists; skipping."
else
  echo "==> Creating main ruleset (required check: $REQUIRED_CHECK, admin bypass)"
  echo "    (403 = private repo on free plan; merge gating then relies on"
  echo "    dependabot-auto-merge.yml's green-CI condition, which is fine)"
  gh api -X POST "repos/$REPO_SLUG/rulesets" --input - <<JSON || true
{
  "name": "main-required-ci",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "$REQUIRED_CHECK" } ]
      }
    }
  ]
}
JSON
fi

if gh secret list -R "$REPO_SLUG" | grep -q '^CLAUDE_CODE_OAUTH_TOKEN'; then
  echo "==> CLAUDE_CODE_OAUTH_TOKEN secret is set."
else
  echo "==> TODO: set the fixer token (interactive, never via argument):"
  echo "        gh secret set CLAUDE_CODE_OAUTH_TOKEN -R $REPO_SLUG"
fi
echo "==> TODO: ensure the Claude GitHub App is installed on $REPO_SLUG."
echo "==> Done."
