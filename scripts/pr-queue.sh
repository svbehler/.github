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
# Below the PR buckets it also prints:
#
#   ISSUES   open issues the automation filed for a human - labels
#            posthog-error (production errors), ci-failure (fixer
#            couldn't fix), incident (deploy/smoke failures)
#   HEALTH   the automation watching itself: scheduled workflow runs
#            that failed in the last 7 days (token expiry, turn caps),
#            workflows GitHub disabled (60-day cron decay), and open
#            Dependabot security alerts per repo
#
# Usage: pr-queue.sh [--nudge]
#   --nudge   close/reopen each STALLED PR to retrigger CI, then exit
#             (skips the ISSUES/HEALTH sweep). On green CI the
#             auto-merge workflow takes it from there.

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

if [ -z "$rows" ]; then
  echo "No open PRs."
  echo
else
  print_section FIX     "Fixer PRs (claude/*) - review and merge/close"
  print_section MAJOR   "Dependabot majors - your call (weekly triage verdict in brackets)"
  print_section STALLED "Stalled group PRs - run with --nudge to retrigger CI"
  print_section OTHER   "Other open PRs"
fi

# ---- ISSUES: what the automation filed for a human ----------------------
# posthog-error = production error triage, ci-failure = the fixer needed a
# human decision, incident = production deploy/smoke failure.

issue_rows=""
for repo in "${REPOS[@]}"; do
  filtered=$(gh issue list -R "$OWNER/$repo" --state open --limit 100 \
    --json number,title,labels \
    --jq '.[]
      | select([.labels[].name]
          | any(. == "posthog-error" or . == "ci-failure" or . == "incident"))
      | [ (.number | tostring),
          ([.labels[].name
            | select(. == "posthog-error" or . == "ci-failure" or . == "incident")]
            | join(",")),
          .title ]
      | @tsv')
  [ -z "$filtered" ] && continue
  while IFS=$'\t' read -r number labels title; do
    [ -z "$number" ] && continue
    issue_rows+="$repo	$number	$labels	$title
"
  done <<<"$filtered"
done

if [ -n "$issue_rows" ]; then
  echo "== Automation issues - decide or delegate =="
  printf '%s' "$issue_rows" | while IFS=$'\t' read -r repo number labels title; do
    printf '  %-19s #%-4s %-16s %s\n' "$repo" "$number" "[$labels]" "$title"
    printf '      https://github.com/%s/%s/issues/%s\n' "$OWNER" "$repo" "$number"
  done
  echo
fi

# ---- HEALTH: the automation watching itself ------------------------------
# Catches silent decay: scheduled runs failing (expired OAuth token, turn
# caps), workflows GitHub disabled after 60 dormant days, and Dependabot
# security alerts that never become PRs (transitive deps).

since=$(date -u -d '7 days ago' +%Y-%m-%d)
health=""
for repo in "${REPOS[@]}"; do
  notes=""

  failed_sched=$(gh api -X GET "repos/$OWNER/$repo/actions/runs" \
    -f event=schedule -f status=failure -f created=">=$since" -f per_page=50 \
    --jq '[.workflow_runs[].name] | group_by(.) | map("\(.[0]) x\(length)") | join(", ")' \
    2>/dev/null) || failed_sched=""
  [ -n "$failed_sched" ] && notes+="      failed scheduled runs: $failed_sched"$'\n'

  disabled=$(gh api -X GET "repos/$OWNER/$repo/actions/workflows" -f per_page=100 \
    --jq '[.workflows[] | select(.state | startswith("disabled")) | "\(.name) (\(.state))"] | join(", ")' \
    2>/dev/null) || disabled=""
  [ -n "$disabled" ] && notes+="      disabled workflows: $disabled"$'\n'

  # A 403 here means the Dependabot alerts feature is off for the repo -
  # itself a health finding (vulnerabilities would go unseen).
  alerts=$(gh api -X GET "repos/$OWNER/$repo/dependabot/alerts" \
    -f state=open -f per_page=100 \
    --jq 'group_by(.security_advisory.severity) | map("\(length) \(.[0].security_advisory.severity)") | join(", ")' \
    2>/dev/null) || alerts="feature disabled - enable Dependabot alerts in repo settings"
  [ -n "$alerts" ] && notes+="      open security alerts: $alerts"$'\n'

  [ -n "$notes" ] && health+="  $repo"$'\n'"$notes"
done

echo "== Automation health (7-day sweep) =="
if [ -n "$health" ]; then
  printf '%s' "$health"
else
  echo "  All clear: no failed scheduled runs, disabled workflows, or open security alerts."
fi
