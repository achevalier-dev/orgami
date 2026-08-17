# One page per repo, and the bundle an agent reads before touching it.

# Recent merged PRs for a repo, newest first, out of the cached weeks.
card_recent_prs() {
  local repo=$1 limit=${2:-6}
  find "$DIR/cache/prs" -name '*.json' -not -name '*.stats.json' 2>/dev/null |
    sort | tail -8 | xargs -r cat 2>/dev/null |
    jq -sr --arg r "$repo" --argjson n "$limit" \
      '[.[].prs[]? | select(.repository.name == $r)]
       | sort_by(.mergedAt) | reverse | .[0:$n][]
       | "- #\(.number) \(.title) — \(.author.login // "unknown"), \(.mergedAt[0:10])"' 2>/dev/null || true
}

card_render() {
  local repo=$1
  local g="$DIR/map/graph.json" p="$DIR/map/repos.json"
  local prof
  prof=$(jq -c --arg r "$repo" '.[] | select(.name == $r)' "$p" 2>/dev/null)
  [[ -n $prof ]] || return 1

  jq -r --argjson prof "$prof" --arg repo "$repo" '
    . as $g
    | ("repo:" + $repo) as $id
    | $prof.meta as $m
    | [
        "# " + $repo,
        "",
        ([($m.language // empty),
          ($prof.frameworks | if length > 0 then join(", ") else empty end),
          (if $m.private then "private" else "public" end),
          ("pushed " + ($m.pushed_at // "")[0:10])]
         | map(select(. != null and . != "")) | join(" · ")),
        ($m.url // ""),
        ""
      ]
      + (if ($m.description // "") != "" then [$m.description, ""] else [] end)

      + (($prof.commands.scripts | to_entries) as $s
         | if ($s | length) == 0 and ($prof.commands.runtime // "") == "" then []
           else ["## Run it", ""]
                + ($s | map("- `" + .key + "` — `" + .value + "`"))
                + ([[($prof.commands.package_manager // empty),
                     ($prof.commands.runtime // empty),
                     ($prof.commands.procfile | if length > 0 then "Procfile: " + join(", ") else empty end)]
                    | map(select(. != null and . != "")) | join(" · ")]
                   | map(select(. != "")) | map("", .))
                + [""]
           end)

      + ([$g.edges[] | select(.from == $id and (.kind | IN("calls", "references", "shares-config")))
          | "- " + (if .kind == "calls" then "calls" elif .kind == "references" then "references" else "shares config with" end)
            + " **" + (.to | sub("^repo:"; "")) + "** — `" + .evidence + "`"]
         + [$g.edges[] | select(.to == $id and (.kind | IN("calls", "references", "shares-config")))
            | "- " + (if .kind == "calls" then "called by" elif .kind == "references" then "referenced by" else "shares config with" end)
              + " **" + (.from | sub("^repo:"; "")) + "** — `" + .evidence + "`"]
         | unique
         | if length == 0 then
             ["## Talks to", "", "Nothing links this repo to another in committed configuration. That is not proof it stands alone — runtime wiring leaves no trace here.", ""]
           else ["## Talks to", ""] + . + [""] end)

      + ($prof.serves as $sv
         | if ($sv | length) == 0 then []
           else ["## Serves", ""] + ($sv | map("- `" + . + "`")) + [""] end)

      + ($prof.routes as $rt
         | if ($rt | length) == 0 then []
           else ["## Endpoints", "",
                 "<details><summary>" + (($rt | length) | tostring) + " found</summary>", ""]
                + ($rt | .[0:40] | map("- `" + . + "`"))
                + ["", "</details>", ""]
           end)

      + ([$g.edges[] | select(.from == $id and .kind == "uses") | .to | sub("^tool:"; "")] as $tools
         | [$g.edges[] | select(.from == $id and .kind == "deploys-to") | .to | sub("^host:"; "")] as $hosts
         | [$g.edges[] | select(.from == $id and .kind == "depends-on") | .to | sub("^service:"; "")] as $svc
         | if ($tools + $hosts + $svc | length) == 0 then []
           else ["## Runs on", ""]
                + (if ($tools | length) > 0 then ["- deployed with " + ($tools | unique | join(", "))] else [] end)
                + (if ($hosts | length) > 0 then ["- hosts " + ($hosts | unique | map("`" + . + "`") | join(", "))] else [] end)
                + (if ($svc | length) > 0 then ["- backed by " + ($svc | unique | join(", "))] else [] end)
                + [""]
           end)

      + ($prof.env as $e
         | if ($e | length) == 0 then []
           else ["## Configuration", "",
                 "<details><summary>" + (($e | length) | tostring) + " environment variables</summary>", "",
                 "`" + ($e | join("`, `")) + "`", "", "</details>", ""]
           end)

      + ($prof.agent_docs as $d
         | if ($d | length) == 0 then []
           else ["## Already written for agents", ""]
                + ($d | map("- [`" + . + "`](" + ($m.url // "") + "/blob/" + ($m.default_branch // "main") + "/" + . + ")"))
                + [""]
           end)
      | .[]' "$g"

  local prs
  prs=$(card_recent_prs "$repo")
  if [[ -n $prs ]]; then
    echo "## Recent merged work"
    echo
    echo "$prs"
    echo
  fi
}

cmd_card() {
  load_company
  local repo=${1:-}
  [[ -n $repo ]] || die "usage: orgami card <repo>"
  [[ -f $DIR/map/repos.json ]] || die "no profiles — run: orgami scan"
  card_render "$repo" || die "no repo called '$repo' in the map"
}

# Resolves a repo from an argument, or from the git remote of the directory
# the agent is standing in.
card_repo_here() {
  local dir=${1:-$PWD} url name
  url=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  if [[ -n $url ]]; then
    name=${url##*/}
    echo "${name%.git}"
    return 0
  fi
  # No usable remote — a worktree, a half-synced checkout, a plain directory.
  # The directory name is a fair guess; the caller checks it against the map.
  basename "$dir"
}

context_overview() {
  local missed=${1:-}
  local g="$DIR/map/graph.json"

  [[ -n $missed ]] &&
    echo "<!-- '$missed' is not a repo in this map; here is the organization instead -->"
  echo "# $COMPANY — $ORG"
  echo
  echo "$(jq '[.nodes[] | select(.kind == "repo")] | length' "$g") repositories, mapped $(jq -r '.generated | .[0:10]' "$g")."
  echo

  echo "## Where things are"
  echo
  echo "- \`$DIR/map/ARCHITECTURE.md\` — the whole org: repos, deployment, hosts, services"
  echo "- \`$DIR/map/repos/<repo>.md\` — one page per repo, or \`orgami context <repo>\`"
  [[ -f $DIR/map/CONVENTIONS.md ]] &&
    echo "- \`$DIR/map/CONVENTIONS.md\` — every AGENTS.md and CLAUDE.md committed in the org"
  [[ -f $DIR/map/DECISIONS.md ]] &&
    echo "- \`$DIR/map/DECISIONS.md\` — durable decisions mined from merged pull requests"
  echo "- \`$DIR/reports/\` — the weekly recaps"
  echo

  local links
  links=$(jq -r '.edges[] | select(.kind == "calls" or .kind == "references")
    | "- **" + (.from | sub("^repo:"; "")) + "** "
      + (if .kind == "calls" then "calls" else "references" end)
      + " **" + (.to | sub("^repo:"; "")) + "** — `" + .evidence + "`"' "$g" | sort -u)
  if [[ -n $links ]]; then
    echo "## How the repos connect"
    echo
    echo "$links"
    echo
  fi

  if [[ -f $DIR/map/coupling.json ]]; then
    local pairs
    pairs=$(jq -r '.pairs | sort_by(-.days, -.weeks) | .[0:8][]
      | "- **\(.a)** + **\(.b)** — same day \(.days)×, same week \(.weeks)×"' \
      "$DIR/map/coupling.json" 2>/dev/null || true)
    if [[ -n $pairs ]]; then
      echo "## What changes together"
      echo
      echo "$pairs"
      echo
      echo "From merged pull requests, not from the code — a hint about blast radius."
      echo
    fi
  fi

  echo "## Biggest repos by recent work"
  echo
  find "$DIR/cache/prs" -name '*.json' -not -name '*.stats.json' 2>/dev/null |
    sort | tail -8 | xargs -r cat 2>/dev/null |
    jq -sr '[.[].prs[]? | .repository.name] | group_by(.) | map({r: .[0], n: length})
            | sort_by(-.n) | .[0:8][] | "- \(.r) — \(.n) merged"' 2>/dev/null || true
  echo
  echo "Ask for one by name: \`orgami context <repo>\`."
}

cmd_context() {
  local want=${1:-}
  local guessed=""

  if [[ -z $want ]]; then
    guessed=$(card_repo_here) || true
    want=$guessed
  fi

  # Point the company at whichever config owns this repo's org.
  if [[ -n $want && -z ${ORGAMI_COMPANY:-} ]]; then
    local url org c
    url=$(git -C "$PWD" remote get-url origin 2>/dev/null || true)
    if [[ -n $url ]]; then
      org=$(sed -E 's|.*[:/]([^/]+)/[^/]+$|\1|' <<<"$url")
      while read -r c; do
        [[ -n $c ]] || continue
        if [[ $(jq -r .org "$(company_dir "$c")/config.json") == "$org" ]]; then
          export ORGAMI_COMPANY="$c"
          break
        fi
      done < <(companies)
    fi
  fi

  load_company
  [[ -f $DIR/map/repos.json ]] || die "no map yet — run: orgami scan"

  # Not standing in a checkout: describe the org instead of refusing.
  if [[ -z $want ]] || ! jq -e --arg r "$want" 'any(.[]; .name == $r)' "$DIR/map/repos.json" >/dev/null; then
    context_overview "$want"
    return 0
  fi

  echo "<!-- orgami · $COMPANY ($ORG) · map generated $(jq -r '.generated | .[0:10]' "$DIR/map/graph.json") -->"
  echo
  card_render "$want" || die "'$want' is not in the map — orgami view to browse"

  local coupled
  if [[ -f $DIR/map/coupling.json ]]; then
    coupled=$(jq -r --arg r "$want" '
      [.pairs[] | select(.a == $r or .b == $r)
       | {other: (if .a == $r then .b else .a end), weeks: .weeks, days: .days, authors: .authors}]
      | sort_by(-.days, -.weeks) | .[0:6][]
      | "- **\(.other)** — same day \(.days)×, same week \(.weeks)× (\(.authors | join(", ")))"' \
      "$DIR/map/coupling.json" 2>/dev/null || true)
    if [[ -n $coupled ]]; then
      echo "## Usually changes with"
      echo
      echo "$coupled"
      echo
      echo "From merged pull request history, not from the code. Treat it as a hint about blast radius."
      echo
    fi
  fi

  echo "---"
  echo
  echo "More: \`orgami query <name>\` for one node, \`$DIR/map/ARCHITECTURE.md\` for the whole org."
}
