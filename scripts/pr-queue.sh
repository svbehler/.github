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
# Usage: pr-queue.sh [--nudge|--html]
#   --nudge   close/reopen each STALLED PR to retrigger CI, then exit
#             (skips the ISSUES/HEALTH sweep). On green CI the
#             auto-merge workflow takes it from there.
#   --html    emit the same queue as a self-contained, email-safe HTML
#             fragment (inline styles, tables) on stdout — for the
#             Monday report page/email.

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
HTML=0
case "${1:-}" in
  --nudge) NUDGE=1 ;;
  --html) HTML=1 ;;
  "") ;;
  *)
    echo "usage: pr-queue.sh [--nudge|--html]" >&2
    exit 1
    ;;
esac

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

# ---- HEALTH: the automation watching itself ------------------------------
# Catches silent decay: scheduled runs failing (expired OAuth token, turn
# caps), workflows GitHub disabled after 60 dormant days, and Dependabot
# security alerts that never become PRs (transitive deps).

since=$(date -u -d '7 days ago' +%Y-%m-%d)
# One line per finding: repo TAB detail
health_rows=""
for repo in "${REPOS[@]}"; do
  failed_sched=$(gh api -X GET "repos/$OWNER/$repo/actions/runs" \
    -f event=schedule -f status=failure -f created=">=$since" -f per_page=50 \
    --jq '[.workflow_runs[].name] | group_by(.) | map("\(.[0]) x\(length)") | join(", ")' \
    2>/dev/null) || failed_sched=""
  [ -n "$failed_sched" ] && health_rows+="$repo	failed scheduled runs: $failed_sched
"

  disabled=$(gh api -X GET "repos/$OWNER/$repo/actions/workflows" -f per_page=100 \
    --jq '[.workflows[] | select(.state | startswith("disabled")) | "\(.name) (\(.state))"] | join(", ")' \
    2>/dev/null) || disabled=""
  [ -n "$disabled" ] && health_rows+="$repo	disabled workflows: $disabled
"

  # A 403 here means the Dependabot alerts feature is off for the repo -
  # itself a health finding (vulnerabilities would go unseen).
  alerts=$(gh api -X GET "repos/$OWNER/$repo/dependabot/alerts" \
    -f state=open -f per_page=100 \
    --jq 'group_by(.security_advisory.severity) | map("\(length) \(.[0].security_advisory.severity)") | join(", ")' \
    2>/dev/null) || alerts="feature disabled - enable Dependabot alerts in repo settings"
  [ -n "$alerts" ] && health_rows+="$repo	open security alerts: $alerts
"
done

# ---- Render: HTML (email-safe: inline styles, tables) --------------------

if [ "$HTML" = 1 ]; then
  esc() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
  }

  ci_color() {
    case "$1" in
      pass) echo "#1a7f37" ;;
      fail) echo "#cf222e" ;;
      pending) echo "#9a6700" ;;
      *) echo "#57606a" ;;
    esac
  }

  # The HTML report is organized by ACTION, not by PR taxonomy: each open
  # PR maps to exactly one thing the human does with it this Monday.
  action_of() {
    # category ci verdict -> action group
    case "$1" in
      FIX) if [ "$2" = pass ]; then echo REVIEW; else echo INVESTIGATE; fi ;;
      STALLED) echo NUDGE ;;
      MAJOR)
        case "$3" in
          MERGE) if [ "$2" = pass ]; then echo MERGE; else echo WAIT; fi ;;
          HOLD) echo PLAN ;;
          *) echo WAIT ;;
        esac
        ;;
      *) echo WAIT ;;
    esac
  }

  # One <li> per pending action; count 0 renders nothing.
  todo() {
    [ "$1" = 0 ] && return 0
    printf '<li style="margin:3px 0;">%s</li>\n' "$2"
  }

  pl() {
    # "" for 1, "s" otherwise
    if [ "$1" = 1 ]; then echo ""; else echo "s"; fi
  }

  html_group() {
    local grp="$1" heading="$2" hint="$3" count="$4" dim="${5:-}"
    [ "$count" = 0 ] && return 0
    local tcolor="#1f2328"
    [ -n "$dim" ] && tcolor="#57606a"
    printf '<h2 style="font-size:15px;margin:26px 0 2px;color:%s;">%s (%s)</h2>\n' "$tcolor" "$(esc "$heading")" "$count"
    printf '<p style="margin:0 0 8px;color:#57606a;font-size:12px;">%s</p>\n' "$(esc "$hint")"
    printf '<table cellpadding="0" cellspacing="0" style="border-collapse:collapse;width:100%%;font-size:13px;">\n'
    printf '%s' "$rows" | while IFS=$'\t' read -r repo number cat ci verdict branch title; do
      [ -z "$repo" ] && continue
      [ "$(action_of "$cat" "$ci" "$verdict")" = "$grp" ] || continue
      printf '<tr style="border-bottom:1px solid #eaeef2;">'
      printf '<td style="padding:6px 8px 6px 0;white-space:nowrap;color:#57606a;vertical-align:top;">%s</td>' "$(esc "$repo")"
      printf '<td style="padding:6px 8px;vertical-align:top;"><a href="https://github.com/%s/%s/pull/%s" style="color:#0969da;text-decoration:none;">#%s</a> %s</td>' "$OWNER" "$repo" "$number" "$number" "$(esc "$title")"
      printf '<td style="padding:6px 0 6px 8px;white-space:nowrap;text-align:right;vertical-align:top;"><b style="color:%s;">ci=%s</b>' "$(ci_color "$ci")" "$(esc "$ci")"
      if [ "$cat" = MAJOR ]; then
        printf ' [%s]' "$(esc "$verdict")"
      fi
      printf '</td></tr>\n'
    done
    printf '</table>\n'
  }

  n_merge=0; n_review=0; n_invest=0; n_nudge=0; n_plan=0; n_wait=0
  while IFS=$'\t' read -r r_repo r_number r_cat r_ci r_verdict r_branch r_title; do
    [ -z "$r_repo" ] && continue
    case "$(action_of "$r_cat" "$r_ci" "$r_verdict")" in
      MERGE) n_merge=$((n_merge + 1)) ;;
      REVIEW) n_review=$((n_review + 1)) ;;
      INVESTIGATE) n_invest=$((n_invest + 1)) ;;
      NUDGE) n_nudge=$((n_nudge + 1)) ;;
      PLAN) n_plan=$((n_plan + 1)) ;;
      WAIT) n_wait=$((n_wait + 1)) ;;
    esac
  done <<<"$rows"
  n_issues=$(printf '%s' "$issue_rows" | grep -c . || true)
  n_health=$(printf '%s' "$health_rows" | grep -c . || true)
  n_actions=$((n_merge + n_review + n_invest + n_nudge + n_plan + n_issues))

  printf '<div style="font-family:-apple-system,BlinkMacSystemFont,&quot;Segoe UI&quot;,Roboto,Helvetica,Arial,sans-serif;max-width:760px;margin:0 auto;padding:8px 12px;color:#1f2328;background:#ffffff;">\n'
  printf '<h1 style="font-size:19px;margin:10px 0 2px;">Automation review queue</h1>\n'
  printf '<p style="margin:0 0 14px;color:#57606a;font-size:12px;">%s &middot; svbehler repos &middot; generated by pr-queue.sh --html</p>\n' "$(date -u '+%A, %d %B %Y, %H:%M UTC')"

  printf '<h2 style="font-size:15px;margin:0 0 4px;color:#1f2328;">What needs you</h2>\n'
  if [ "$n_actions" = 0 ]; then
    printf '<p style="font-size:13px;color:#1a7f37;">Nothing. Every open PR is being handled by the automation.</p>\n'
  else
    printf '<ol style="margin:4px 0 6px 22px;padding:0;font-size:13px;">\n'
    todo "$n_merge" "<b>Merge $n_merge major$(pl "$n_merge")</b> - triage said MERGE and CI is green. One click each."
    todo "$n_review" "<b>Review $n_review green fixer PR$(pl "$n_review")</b> - the fix worked; check the diff, then merge."
    todo "$n_invest" "<b>Investigate $n_invest red fixer PR$(pl "$n_invest")</b> - the fix itself is failing CI; these need a decision."
    todo "$n_nudge" "<b>Nudge $n_nudge stalled group PR$(pl "$n_nudge")</b> - run <b>pr-queue.sh --nudge</b> once, then they self-merge on green."
    todo "$n_plan" "<b>Plan $n_plan HOLD migration$(pl "$n_plan")</b> - read the triage comment, schedule the migration work."
    todo "$n_issues" "<b>Decide $n_issues automation issue$(pl "$n_issues")</b> - production errors or failures the machines could not handle alone."
    printf '</ol>\n'
  fi
  if [ "$n_wait" -gt 0 ]; then
    printf '<p style="margin:0 0 6px;font-size:12px;color:#57606a;">%s more PRs are waiting on automation (red or pending CI, untriaged majors) - no action, listed at the bottom.</p>\n' "$n_wait"
  fi

  html_group MERGE "Merge now" "Triage verdict MERGE with green CI. Merging is safe and unblocks Dependabot." "$n_merge"
  html_group REVIEW "Review and merge - green fixer PRs" "The fixer repaired CI and its checks pass. Review the diff, then merge or close." "$n_review"
  html_group INVESTIGATE "Investigate - red fixer PRs" "The fixer committed but CI is still failing (or never re-ran). Open the PR and decide: fix, close, or nudge." "$n_invest"
  html_group NUDGE "Nudge - stalled group PRs" "The fixer patched these but bot commits do not retrigger CI. pr-queue.sh --nudge close/reopens them; on green they auto-merge." "$n_nudge"
  html_group PLAN "Plan - HOLD migrations" "The weekly triage found breaking changes that touch this code. Read its PR comment; schedule the migration before merging." "$n_plan"

  if [ -n "$issue_rows" ]; then
    printf '<h2 style="font-size:15px;margin:26px 0 2px;color:#1f2328;">Decide - automation issues (%s)</h2>\n' "$n_issues"
    printf '<p style="margin:0 0 8px;color:#57606a;font-size:12px;">What the machines explicitly handed to you: posthog-error = production error, ci-failure = fixer needs a decision, incident = production deploy/smoke failure.</p>\n'
    printf '<table cellpadding="0" cellspacing="0" style="border-collapse:collapse;width:100%%;font-size:13px;">\n'
    printf '%s' "$issue_rows" | while IFS=$'\t' read -r repo number labels title; do
      printf '<tr style="border-bottom:1px solid #eaeef2;">'
      printf '<td style="padding:6px 8px 6px 0;white-space:nowrap;color:#57606a;vertical-align:top;">%s</td>' "$(esc "$repo")"
      printf '<td style="padding:6px 8px;vertical-align:top;"><a href="https://github.com/%s/%s/issues/%s" style="color:#0969da;text-decoration:none;">#%s</a> %s</td>' "$OWNER" "$repo" "$number" "$number" "$(esc "$title")"
      printf '<td style="padding:6px 0 6px 8px;white-space:nowrap;text-align:right;vertical-align:top;color:#cf222e;font-size:12px;">%s</td></tr>\n' "$(esc "$labels")"
    done
    printf '</table>\n'
  fi

  html_group WAIT "Waiting on automation - no action" "Red or pending CI on MERGE-verdict majors (the Dependabot fixer handles those), untriaged majors (Monday triage), and other open PRs. Listed for transparency only." "$n_wait" dim

  printf '<h2 style="font-size:15px;margin:26px 0 2px;color:#1f2328;">Automation health (7-day sweep)</h2>\n'
  if [ -n "$health_rows" ]; then
    printf '<p style="margin:0 0 8px;color:#57606a;font-size:12px;">The automation watching itself: failed scheduled runs point at an expired token or turn caps; disabled workflows are 60-day cron decay; alerts without PRs are transitive-dep vulnerabilities.</p>\n'
    printf '<table cellpadding="0" cellspacing="0" style="border-collapse:collapse;width:100%%;font-size:13px;">\n'
    printf '%s' "$health_rows" | while IFS=$'\t' read -r repo detail; do
      printf '<tr style="border-bottom:1px solid #eaeef2;">'
      printf '<td style="padding:6px 8px 6px 0;white-space:nowrap;color:#57606a;vertical-align:top;">%s</td>' "$(esc "$repo")"
      printf '<td style="padding:6px 0;vertical-align:top;">%s</td></tr>\n' "$(esc "$detail")"
    done
    printf '</table>\n'
  else
    printf '<p style="font-size:13px;color:#1a7f37;">All clear: no failed scheduled runs, disabled workflows, or open security alerts.</p>\n'
  fi
  printf '</div>\n'
  exit 0
fi

# ---- Render: terminal -----------------------------------------------------

if [ -z "$rows" ]; then
  echo "No open PRs."
  echo
else
  print_section FIX     "Fixer PRs (claude/*) - review and merge/close"
  print_section MAJOR   "Dependabot majors - your call (weekly triage verdict in brackets)"
  print_section STALLED "Stalled group PRs - run with --nudge to retrigger CI"
  print_section OTHER   "Other open PRs"
fi

if [ -n "$issue_rows" ]; then
  echo "== Automation issues - decide or delegate =="
  printf '%s' "$issue_rows" | while IFS=$'\t' read -r repo number labels title; do
    printf '  %-19s #%-4s %-16s %s\n' "$repo" "$number" "[$labels]" "$title"
    printf '      https://github.com/%s/%s/issues/%s\n' "$OWNER" "$repo" "$number"
  done
  echo
fi

echo "== Automation health (7-day sweep) =="
if [ -n "$health_rows" ]; then
  printf '%s' "$health_rows" | awk -F'\t' '{ if ($1 != prev) { print "  " $1; prev = $1 } print "      " $2 }'
else
  echo "  All clear: no failed scheduled runs, disabled workflows, or open security alerts."
fi
