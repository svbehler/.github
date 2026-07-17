#!/usr/bin/env bash
# Daily status board for the local-first process (the CI auto-fix fleet is
# gone — torn down 2026-07-17). Three sections:
#
#   OPEN PRS         open PRs across the active repos. Post-teardown the only
#                    expected PRs are Dependabot security PRs and strays —
#                    the dev flow merges locally (agent-merge-main.sh).
#   SECURITY         open Dependabot security alerts per repo (the alerts
#                    stayed on when version updates were turned off).
#   PENDING PROMOTE  per product repo: what is merged on main but not yet
#                    live (git log production..main). Ship it deliberately
#                    with agent-promote-prod.sh.
#
# Counts come from the LOCAL checkouts — as-of your last fetch, no network
# git calls. gh is used for the PR/alert sections.
#
# Usage: pr-queue.sh

set -euo pipefail

OWNER=svbehler
REPOS=(
  xpo-inventory
  xpo-market
  certaince
  targical
  emily-kirby
  bc-to-datev
  tempo-website
  tombox
)

# Product repos on the promote-branch flow: "<remote-name>:<local-checkout>"
PROMOTE_REPOS=(
  "xpo-inventory:$HOME/projects/xpo-inventory"
  "xpo-market:$HOME/projects/xpo-market"
  "certaince:$HOME/projects/certaince"
  "targical:$HOME/projects/targical"
)

if [[ $# -gt 0 ]]; then
  echo "usage: pr-queue.sh   (--nudge/--html are gone with the automation fleet)" >&2
  exit 1
fi

# ---- OPEN PRS -------------------------------------------------------------
pr_rows=""
for repo in "${REPOS[@]}"; do
  prs=$(gh pr list -R "$OWNER/$repo" --state open --limit 100 \
    --json number,title,headRefName \
    --jq '.[] | [(.number | tostring), .headRefName, .title] | @tsv' 2>/dev/null) || prs=""
  [ -z "$prs" ] && continue
  while IFS=$'\t' read -r number branch title; do
    [ -z "$number" ] && continue
    kind=other
    case "$branch" in dependabot/*) kind=security ;; esac
    pr_rows+="$repo	$number	$kind	$title
"
  done <<<"$prs"
done

echo "== Open PRs (expected: Dependabot security PRs and strays only) =="
if [ -n "$pr_rows" ]; then
  printf '%s' "$pr_rows" | while IFS=$'\t' read -r repo number kind title; do
    printf '  %-19s #%-4s %-9s %s\n' "$repo" "$number" "[$kind]" "$title"
    printf '      https://github.com/%s/%s/pull/%s\n' "$OWNER" "$repo" "$number"
  done
  echo "  Handle security PRs locally: check out the branch in a worktree,"
  echo "  run local-ci.sh, then agent-merge-main.sh."
else
  echo "  None."
fi
echo

# ---- SECURITY --------------------------------------------------------------
# A 403 means Dependabot alerts are off for the repo — itself a finding
# (vulnerabilities would go unseen).
echo "== Security (open Dependabot alerts) =="
sec_found=0
for repo in "${REPOS[@]}"; do
  alerts=$(gh api -X GET "repos/$OWNER/$repo/dependabot/alerts" \
    -f state=open -f per_page=100 \
    --jq '.[] | [.security_advisory.severity, .dependency.package.name, (.security_advisory.summary // "")] | @tsv' \
    2>/dev/null) || alerts="	feature-disabled	enable Dependabot alerts in repo settings"
  [ -z "$alerts" ] && continue
  sec_found=1
  while IFS=$'\t' read -r severity pkg summary; do
    [ -z "$severity$pkg" ] && continue
    printf '  %-19s %-9s %-28s %s\n' "$repo" "$severity" "$pkg" "$summary"
  done <<<"$alerts"
done
[ "$sec_found" = 0 ] && echo "  All clear."
echo

# ---- PENDING PROMOTE --------------------------------------------------------
echo "== Pending promote (merged on main, not yet live) =="
for entry in "${PROMOTE_REPOS[@]}"; do
  repo="${entry%%:*}"
  dir="${entry#*:}"
  if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
    printf '  %-19s no local checkout at %s\n' "$repo" "$dir"
    continue
  fi
  if ! git -C "$dir" show-ref --verify --quiet refs/heads/production; then
    printf '  %-19s not yet migrated (no production branch)\n' "$repo"
    continue
  fi
  count=$(git -C "$dir" rev-list --count --first-parent production..main 2>/dev/null || echo "?")
  if [ "$count" = "0" ]; then
    printf '  %-19s up to date (production == main)\n' "$repo"
  else
    printf '  %-19s %s task(s) merged, not yet live:\n' "$repo" "$count"
    git -C "$dir" log production..main --oneline --first-parent | head -10 \
      | sed 's/^/      /'
    printf '      ship:  agent-promote-prod.sh %s\n' "$dir"
  fi
done
