# Which repos keep changing together. Read out of the cached pull requests,
# so it grows sharper every week the timer runs. Nothing static can see this.

BOT_AUTHORS='dependabot|renovate|github-actions|snyk-bot|-bot$|\[bot\]'

cmd_coupling() {
  load_company

  local weeks
  weeks=$(find "$DIR/cache/prs" -name '*.json' -not -name '*.stats.json' 2>/dev/null | sort)
  [[ -n $weeks ]] || die "no cached pull requests — run: orgami pull"

  local out="$DIR/map/coupling.json"

  # Same author, same week, more than one repo: those repos moved together.
  # Bots are excluded — a dependency bump across ten repos is not coupling.
  echo "$weeks" | xargs cat | jq -s --arg bots "$BOT_AUTHORS" '
    def combos($rs; $bucket; $author):
      [range(0; ($rs | length)) as $i
       | range($i + 1; ($rs | length)) as $j
       | {a: $rs[$i], b: $rs[$j], bucket: $bucket, author: $author}];

    [.[] | .week as $w | (.prs // [])[]
     | select((.author.login // "unknown") | test($bots; "i") | not)
     | select(.mergedAt != null)
     | {week: $w, day: .mergedAt[0:10],
        author: (.author.login // "unknown"), repo: .repository.name}] as $ev

    | ([$ev | group_by(.author + "|" + .day)[]
        | combos(([.[].repo] | unique); .[0].day; .[0].author)] | add // []) as $dayp
    | ([$ev | group_by(.author + "|" + .week)[]
        | combos(([.[].repo] | unique); .[0].week; .[0].author)] | add // []) as $weekp
    | ($dayp | group_by(.a + "|" + .b)
       | map({key: (.[0].a + "|" + .[0].b), value: ([.[].bucket] | unique | length)})
       | from_entries) as $days

    | {generated: (now | todate),
       weeks_observed: ([$ev[].week] | unique | length),
       pairs: ($weekp | group_by(.a + "|" + .b)
         | map({a: .[0].a, b: .[0].b,
                weeks: ([.[].bucket] | unique | length),
                days: ($days[(.[0].a + "|" + .[0].b)] // 0),
                authors: ([.[].author] | unique)})
         | sort_by(-.weeks, -.days, .a))}' >"$out"

  local pairs
  pairs=$(jq '.pairs | length' "$out")
  echo "$out  ($pairs pairs over $(jq -r .weeks_observed "$out") week(s) of history)"

  # Only pairs seen in more than one week are stable enough for the graph.
  local graph="$DIR/map/graph.json" tmp
  if [[ -f $graph ]]; then
    tmp=$(mktemp)
    jq -s '.[0] as $g | .[1] as $c
      | $g
      | .edges = ((.edges + [$c.pairs[] | select(.weeks > 1 or .days > 1)
          | {from: ("repo:" + .a), to: ("repo:" + .b), kind: "changes-with",
             evidence: ((.weeks | tostring) + " weeks / " + (.days | tostring)
                        + " days, " + (.authors | join(", ")))}])
          | unique)' "$graph" "$out" >"$tmp"
    mv "$tmp" "$graph"
  fi
}
