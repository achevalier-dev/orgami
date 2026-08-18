# shellcheck shell=bash
# orgami daily — what the organization did in one day. Same split as the weekly
# recap: lib/daily.jq computes every number, the model writes the sentences
# around them, and a day with nothing in it produces no file at all.
#
# A day is not a week in miniature. Most of a day's work has not merged yet, so
# this reads three things: what merged, what opened, and what is sitting open
# with nobody on it — plus commits, which catch the work that never became a
# pull request.

daily_cache() {
  local date=$1
  local out="$DIR/cache/daily/$date.json"
  mkdir -p "$DIR/cache/daily"

  local merged opened open commits
  log "$COMPANY: $ORG on $date"

  merged=$(pull_search "org:$ORG is:pr is:merged merged:$date")
  opened=$(pull_search "org:$ORG is:pr created:$date")
  open=$(pull_search "org:$ORG is:pr is:open updated:$date")

  # One REST search for the whole org. Commits are what a weekly recap built on
  # merges cannot see: a branch that has not opened a pull request yet.
  commits=$(gh search commits --owner "$ORG" --author-date "$date" --limit 100 \
    --json repository,sha,commit,author 2>/dev/null || echo '[]')
  [[ -n ${commits// /} ]] || commits='[]'

  jq -n --arg org "$ORG" --arg company "$COMPANY" --arg date "$date" \
    --argjson merged "$merged" --argjson opened "$opened" \
    --argjson open "$open" --argjson commits "$commits" \
    '{company: $company, org: $org, date: $date,
      merged: $merged, opened: $opened, open: $open,
      commits: [$commits[] | {
        repository: {name: .repository.name},
        author: {login: (.author.login // .commit.author.name // "unknown")},
        message: (.commit.message | split("\n")[0]),
        sha: (.sha | .[0:7]),
        at: .commit.author.date,
        pull_request: (.commit.message | capture("\\(#(?<n>[0-9]+)\\)") | .n // null)
      }]}' >"$out"

  echo "$out"
}

# What the model is allowed to see: intent, not diffs, and no review threads.
daily_digest() {
  local src=$1
  jq '{
    merged: [.merged[] | {repo: .repository.name, number, title,
                          author: (.author.login // "unknown"),
                          body: (.bodyText // "" | .[0:400]),
                          labels: [.labels.nodes[].name],
                          additions, deletions, changedFiles}],
    opened: [.opened[] | {repo: .repository.name, number, title,
                          author: (.author.login // "unknown"),
                          body: (.bodyText // "" | .[0:200])}],
    waiting_on_review: [.open[]
      | select([.reviews.nodes[] | select(.state == "APPROVED"
                or .state == "CHANGES_REQUESTED")] | length == 0)
      | {repo: .repository.name, number, title,
         author: (.author.login // "unknown"), opened: .createdAt}],
    commits_without_pull_request: [.commits[] | select(.pull_request == null)
      | {repo: .repository.name, author: .author.login, message, sha}]
  }' "$src"
}

cmd_daily() {
  load_company
  need jq
  need gh

  local date="" model="" stats_only=0 refetch=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --date) date=$2; shift 2 ;;
      --yesterday) date=$(date_shift "$(date -u +%Y-%m-%d)" -1); shift ;;
      --model) model=$2; shift 2 ;;
      --stats-only) stats_only=1; shift ;;
      --refetch) refetch=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [[ -n $date ]] || date=$(date -u +%Y-%m-%d)
  [[ $date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date wants YYYY-MM-DD, got '$date'"

  local src="$DIR/cache/daily/$date.json"
  if [[ $refetch == 1 || ! -f $src ]]; then
    src=$(daily_cache "$date")
  fi

  local stats
  stats=$(jq -f "$ROOT/lib/daily.jq" "$src")

  if [[ $stats_only == 1 ]]; then
    echo "$stats"
    return 0
  fi

  # A quiet day is a real answer. Writing "nothing happened" every weekend is
  # how a digest teaches people to stop opening it.
  local landed
  landed=$(jq -r '.merged + .commits_outside_prs + .opened' <<<"$stats")
  if [[ $landed -eq 0 ]]; then
    log "nothing landed in $ORG on $date — no digest written"
    return 0
  fi

  need claude "the digest's prose is written by Claude Code in headless mode"
  [[ -n $model ]] || model=$(cfg model "sonnet")

  local body
  body=$( {
    cat "$ROOT/prompts/daily.md"
    printf '\n\nSTATS\n```json\n%s\n```\n' "$stats"
    printf '\nACTIVITY\n```json\n'
    daily_digest "$src"
    printf '\n```\n'
  } | claude -p --model "$model" --output-format text 2>/dev/null || true)

  model_output_ok "$body" '^## ' ||
    die "the model call did not complete — nothing written. Numbers are still there: orgami daily --date $date --stats-only"

  mkdir -p "$DIR/reports/daily"
  local out="$DIR/reports/daily/$date.md"
  {
    printf '# %s · %s\n\n' "$ORG" "$(date_fmt "$date" '%A %-d %B %Y')"
    linkify_prs <<<"$body" | linkify_repo_prs "$ORG" "$DIR/map/graph.json"
    printf '\n---\n\n'
    printf '%s merged · %s opened · %s repos · %s people' \
      "$(jq -r .merged <<<"$stats")" "$(jq -r .opened <<<"$stats")" \
      "$(jq -r .repos_touched <<<"$stats")" "$(jq -r .authors <<<"$stats")"
    local loose
    loose=$(jq -r .commits_outside_prs <<<"$stats")
    [[ $loose -gt 0 ]] && printf ' · %s commits outside a pull request' "$loose"
    printf '\n'
    printf '\n<!-- orgami daily · generated %s -->\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$out"

  echo "$out"
}
