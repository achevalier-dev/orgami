# shellcheck shell=bash
# orgami pull — cache merged PRs for a week from the GitHub GraphQL search API.
# Re-running the same week overwrites its cache file; nothing else is touched.

# One search query, every page of it, as a JSON array of pull requests on stdout.
# `orgami daily` runs the same query shape over a single day.
pull_search() {
  local q=$1 after="null" page=0 nodes tmp all
  all=$(mktemp)
  echo '[]' >"$all"

  while :; do
    if [[ $after == "null" ]]; then
      nodes=$(gh api graphql -F query="@$ROOT/lib/prs.graphql" -f q="$q")
    else
      nodes=$(gh api graphql -F query="@$ROOT/lib/prs.graphql" -f q="$q" -f after="$after")
    fi

    page=$((page + 1))
    tmp=$(mktemp)
    jq --slurpfile new <(jq '[.data.search.nodes[] | select(.number != null)]' <<<"$nodes") \
      '. + $new[0]' "$all" >"$tmp"
    mv "$tmp" "$all"

    [[ $(jq -r '.data.search.pageInfo.hasNextPage' <<<"$nodes") == "true" ]] || break
    after=$(jq -r '.data.search.pageInfo.endCursor' <<<"$nodes")
    [[ $page -lt 20 ]] || { log "stopping at 1000 results (GitHub search cap) — narrow the range"; break; }
  done

  cat "$all"
  rm -f "$all"
}

cmd_pull() {
  load_company
  need gh

  local weeks_ago=0 since="" until=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --last) weeks_ago=$2; shift 2 ;;
      --since) since=$2; shift 2 ;;
      --until) until=$2; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  if [[ -z $since ]]; then
    since=$(week_start "$weeks_ago")
    until=$(date_shift "$since" +6)
  fi
  [[ -n $until ]] || until=$(date -u +%Y-%m-%d)

  local label
  label=$(date_fmt "$since" %G-W%V)
  local out="$DIR/cache/prs/$label.json"

  local q="org:$ORG is:pr is:merged merged:$since..$until"
  log "$COMPANY: $q"

  local after="null" page=0 total=0
  local nodes tmp all
  all=$(mktemp)
  echo '[]' >"$all"

  while :; do
    if [[ $after == "null" ]]; then
      nodes=$(gh api graphql -F query="@$ROOT/lib/prs.graphql" -f q="$q")
    else
      nodes=$(gh api graphql -F query="@$ROOT/lib/prs.graphql" -f q="$q" -f after="$after")
    fi

    page=$((page + 1))
    total=$(jq -r '.data.search.issueCount' <<<"$nodes")

    tmp=$(mktemp)
    jq --slurpfile new <(jq '[.data.search.nodes[] | select(.number != null)]' <<<"$nodes") \
      '. + $new[0]' "$all" >"$tmp"
    mv "$tmp" "$all"

    [[ $(jq -r '.data.search.pageInfo.hasNextPage' <<<"$nodes") == "true" ]] || break
    after=$(jq -r '.data.search.pageInfo.endCursor' <<<"$nodes")
    [[ $page -lt 20 ]] || { log "stopping at 1000 PRs (GitHub search cap) — narrow the range"; break; }
  done

  jq -n --arg company "$COMPANY" --arg org "$ORG" --arg week "$label" \
    --arg since "$since" --arg until "$until" --argjson total "$total" \
    --slurpfile prs "$all" \
    '{company: $company, org: $org, week: $week, since: $since, until: $until,
      issue_count: $total, prs: $prs[0]}' >"$out"
  rm -f "$all"

  echo "$out  ($(jq '.prs | length' "$out") merged PRs, $since..$until)"
}
