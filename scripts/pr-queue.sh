#!/usr/bin/env bash
# Review queue for the CI auto-fix fleet.
#
# Lists open PRs across the active repos, categorized by what they need
# from a human:
#
#   FIX      claude/* branches - fixer-created PRs awaiting your review
#   MAJOR    Dependabot major bumps (never auto-merged), with the weekly
#            triage verdict (MERGE/HOLD) if one has been commented
#   STALLED  Dependabot group PRs whose last commit is an "auto-fix:" but
#            whose head has no green CI - bot commits don't retrigger CI
#            (decision D3), so these need a close/reopen nudge
#   OTHER    everything else (your own feature PRs etc.)
#
# Usage: pr-queue.sh [--nudge]
#   --nudge   close/reopen each STALLED PR to retrigger CI, then exit.
#             On green CI the auto-merge workflow takes it from there.

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
)

NUDGE=0
if [ "${1:-}" = "--nudge" ]; then
  NUDGE=1
elif [ -n "${1:-}" ]; then
  echo "usage: pr-queue.sh [--nudge]" >&2
  exit 1
fi

# One line per PR: repo TAB number TAB category TAB ci TAB verdict TAB branch TAB title
rows=""

ci_state() {
  # Reduce a statusCheckRollup conclusion list to one word.
  # No checks on the head commit means CI never ran for it (the D3 gap).
  jq -r 'if length == 0 then "none"
         elif any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT") then "fail"
         elif all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "pass"
         else "pending" end'
}

for repo in "${REPOS[@]}"; do
  # No `commits` field here: on a full page of PRs it exceeds GitHub's
  # GraphQL node limit. The last commit is fetched per-PR where needed.
  prs=$(gh pr list -R "$OWNER/$repo" --state open --limit 100 \
    --json number,title,headRefName,author,statusCheckRollup)

  count=$(echo "$prs" | jq 'length')
  for i in $(seq 0 $((count - 1))); do
    pr=$(echo "$prs" | jq ".[$i]")
    number=$(echo "$pr" | jq -r .number)
    branch=$(echo "$pr" | jq -r .headRefName)
    title=$(echo "$pr" | jq -r .title)
    ci=$(echo "$pr" | jq '[.statusCheckRollup[]? | (.conclusion // .state)]' | ci_state)

    verdict="-"
    case "$branch" in
      claude/*)
        category=FIX
        ;;
      dependabot/*)
        if [[ "$branch" == *minor-and-patch* ]]; then
          # Group PRs auto-merge on green; they only need a human (or a
          # nudge) when the fixer pushed and CI never re-ran, or is red.
          last_commit=$(gh api "repos/$OWNER/$repo/pulls/$number/commits" \
            --jq 'last | .commit.message | split("\n")[0]')
          if [[ "$last_commit" == auto-fix:* && "$ci" != pass ]]; then
            category=STALLED
          elif [ "$ci" = fail ]; then
            category=STALLED
          else
            continue # in flight - auto-merge or the fixer will handle it
          fi
        else
          category=MAJOR
          body=$(gh api "repos/$OWNER/$repo/issues/$number/comments" \
            --jq '[.[] | select(.body | contains("<!-- major-triage -->"))] | last | .body // ""')
          # grep exits 1 on no match (untriaged PR); don't let -e/pipefail kill us
          v=$(echo "$body" | { grep -oE 'Verdict: (MERGE|HOLD)' || true; } | head -1 | cut -d' ' -f2)
          verdict="${v:-untriaged}"
        fi
        ;;
      *)
        category=OTHER
        ;;
    esac

    rows+="$repo	$number	$category	$ci	$verdict	$branch	$title
"
  done
done

if [ -z "$rows" ]; then
  echo "Queue is empty - nothing needs review."
  exit 0
fi

print_section() {
  local cat="$1" heading="$2"
  local section
  section=$(printf '%s' "$rows" | awk -F'\t' -v c="$cat" '$3 == c')
  [ -z "$section" ] && return 0
  echo "== $heading =="
  printf '%s\n' "$section" | while IFS=$'\t' read -r repo number _ ci verdict branch title; do
    if [ "$cat" = MAJOR ]; then
      printf '  %-19s #%-4s ci=%-7s %-10s %s\n' "$repo" "$number" "$ci" "[$verdict]" "$title"
    else
      printf '  %-19s #%-4s ci=%-7s %s\n' "$repo" "$number" "$ci" "$title"
    fi
    printf '      https://github.com/%s/%s/pull/%s\n' "$OWNER" "$repo" "$number"
  done
  echo
}

if [ "$NUDGE" = 1 ]; then
  stalled=$(printf '%s' "$rows" | awk -F'\t' '$3 == "STALLED" { print $1 "\t" $2 }')
  if [ -z "$stalled" ]; then
    echo "No stalled PRs to nudge."
    exit 0
  fi
  printf '%s\n' "$stalled" | while IFS=$'\t' read -r repo number; do
    echo "==> Nudging $OWNER/$repo #$number (close/reopen to retrigger CI)"
    gh pr close -R "$OWNER/$repo" "$number"
    sleep 2
    gh pr reopen -R "$OWNER/$repo" "$number"
  done
  echo "Done. CI reruns as a human-actor event; auto-merge picks up green group PRs."
  exit 0
fi

print_section FIX     "Fixer PRs (claude/*) - review and merge/close"
print_section MAJOR   "Dependabot majors - your call (weekly triage verdict in brackets)"
print_section STALLED "Stalled group PRs - run with --nudge to retrigger CI"
print_section OTHER   "Other open PRs"
