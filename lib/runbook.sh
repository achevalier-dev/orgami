# The operational half of the map: how a repo runs, how it ships, what breaks,
# and what the team has already learned the hard way. Everything here is derived
# or quoted — no model writes any of it.

# Tags that place a note into a runbook section. Anything else stays a plain note.
RUNBOOK_TAGS=(setup deploy rollback incident gotcha oncall)

runbook_tag_heading() {
  case $1 in
    setup) echo "Getting it running" ;;
    deploy) echo "Deploying it" ;;
    rollback) echo "Rolling it back" ;;
    incident) echo "When it broke before" ;;
    gotcha) echo "Traps" ;;
    oncall) echo "Who to reach" ;;
    *) echo "$1" ;;
  esac
}

# Notes for a repo carrying one tag, quoted with their author and date.
runbook_notes_tagged() {
  local repo=$1 tag=$2
  notes_index 2>/dev/null | jq -r --arg r "$repo" --arg t "$tag" '
    [.[] | select(.repo == $r)
     | select((.tags // "") | gsub("[\\[\\] ]"; "") | split(",") | index($t))]
    | .[]
    | "- " + (.body | gsub("^\\n+"; "") | gsub("\\n+$"; "") | gsub("\\n"; "\n  "))
      + "\n  <sub>" + .author + ", " + (.date | .[0:10]) + "</sub>"' 2>/dev/null || true
}

# Decision and action-required lines that name this repo, quoted verbatim.
runbook_constraints() {
  local repo=$1 f
  {
    [[ -d $DIR/map/decisions ]] &&
      grep -h -- "/$repo#" "$DIR/map/decisions"/*.md 2>/dev/null
    for f in "$DIR"/reports/*.md; do
      [[ -f $f ]] || continue
      sed -n '/^## Action required/,/^## /p' "$f" 2>/dev/null | grep -- "/$repo#" || true
    done
  } 2>/dev/null | sed 's/^- //' | sort -u | head -12
}

runbook_render() {
  local repo=$1
  local profiles="$DIR/map/repos.json" g="$DIR/map/graph.json"
  local prof
  prof=$(jq -c --arg r "$repo" '.[] | select(.name == $r)' "$profiles" 2>/dev/null)
  [[ -n $prof ]] || return 1

  echo "# $repo — runbook"
  echo
  jq -r --argjson p "$prof" '
    [($p.meta.language // empty),
     ($p.frameworks | if length > 0 then join(", ") else empty end)]
    | map(select(. != null and . != "")) | join(" · ")' <<<'{}'
  echo
  echo "<sub>Derived from the scan of $(jq -r '.generated | .[0:10]' "$g"). Nothing here was written by a model.</sub>"
  echo

  # ---------------------------------------------------------------- run it
  echo "## Run it"
  echo
  jq -r --argjson p "$prof" '
    ($p.commands.scripts | to_entries) as $s
    | (if ($p.commands.runtime // "") != "" or ($p.commands.package_manager // "") != ""
       then ["Needs " + ([($p.commands.runtime // empty), ($p.commands.package_manager // empty)]
             | map(select(. != null and . != "")) | join(", ")) + ".", ""]
       else [] end)
      + (if ($s | length) > 0
         then ($s | map("- `" + .key + "` — `" + .value + "`")) + [""]
         else ["No run or test command is declared in the repository.", ""] end)
      + (if ($p.commands.procfile | length) > 0
         then ["Processes: `" + ($p.commands.procfile | join("`, `")) + "`", ""]
         else [] end)
    | .[]' <<<'{}'

  local envcount
  envcount=$(jq -r --argjson p "$prof" '$p.env | length' <<<'{}')
  if [[ ${envcount:-0} -gt 0 ]]; then
    echo "It reads $envcount environment variables. The ones that point somewhere:"
    echo
    jq -r --argjson p "$prof" '
      [$p.env[] | select(test("_(URL|HOST|ENDPOINT|BASE|BUCKET|QUEUE|TOPIC|DSN)$"))]
      | if length == 0 then ["- none obviously external"] else map("- `" + . + "`") end
      | .[]' <<<'{}'
    echo
  fi

  runbook_section "$repo" setup

  # -------------------------------------------------------------- shipping
  echo "## How it ships"
  echo
  jq -r --argjson p "$prof" '
    [$p.workflows[]? | select(.deploys)] as $d
    | if ($d | length) == 0 then
        (if ($p.workflows | length) == 0
         then ["There is no CI in this repository at all. How it reaches production is not recorded here — if you know, record it with `orgami note --tag deploy`."]
         else ["No workflow in this repository deploys. CI runs "
               + ([$p.workflows[].name] | join(", "))
               + ", but shipping happens somewhere this scan cannot see — record it with `orgami note --tag deploy`."] end)
      else
        ($d | map("- **" + .name + "** — `" + .file + "`"
                  + (if (.on | length) > 0 then ", on " + (.on | join(" / ")) else "" end)
                  + (if (.environment // "") != "" then ", environment `" + .environment + "`" else "" end)))
      end
    | .[]' <<<'{}'
  echo

  runbook_section "$repo" deploy
  runbook_section "$repo" rollback

  # ------------------------------------------------------------ where it is
  local hosts services
  hosts=$(jq -r --arg id "repo:$repo" '
    [.edges[] | select(.from == $id and (.kind == "deploys-to" or .kind == "reaches")) | .to | sub("^host:"; "")]
    + [.nodes[] | select(.id == $id) | empty]
    | unique | .[]' "$g" 2>/dev/null | head -12)
  services=$(jq -r --arg id "repo:$repo" '
    [.edges[] | select(.from == $id and .kind == "depends-on") | .to | sub("^service:"; "")]
    | unique | .[]' "$g" 2>/dev/null)

  if [[ -n $hosts || -n $services ]]; then
    echo "## Where it lives"
    echo
    jq -r --argjson p "$prof" '$p.serves[]? | "- serves `" + . + "`"' <<<'{}'
    [[ -n $hosts ]] && sed 's/^/- reaches `/; s/$/`/' <<<"$hosts"
    [[ -n $services ]] && sed 's/^/- backed by /' <<<"$services"
    echo
  fi

  # ------------------------------------------------------- is it alive
  local health obs
  health=$(jq -r --argjson p "$prof" '
    [$p.routes[]? | select(test("/(health|healthz|status|ping|ready|live)"; "i"))] | .[]' <<<'{}')
  obs=$(jq -r --argjson p "$prof" '
    [$p.env[]? | select(test("SENTRY|BETTERSTACK|DATADOG|NEWRELIC|NEW_RELIC|LOGTAIL|ROLLBAR|GRAFANA|HONEYCOMB|BUGSNAG|PROMETHEUS"))] | .[]' <<<'{}')

  if [[ -n $health || -n $obs ]]; then
    echo "## Is it alive"
    echo
    if [[ -n $health ]]; then
      echo "Health endpoints it serves:"
      echo
      sed 's/^/- `/; s/$/`/' <<<"$health"
      echo
    fi
    if [[ -n $obs ]]; then
      echo "Wired to: $(grep -oE "SENTRY|BETTERSTACK|DATADOG|NEW_?RELIC|LOGTAIL|ROLLBAR|GRAFANA|HONEYCOMB|BUGSNAG|PROMETHEUS" <<<"$obs" | sort -u | paste -sd, - | sed 's/,/, /g')"
      echo
      echo "<details><summary>the variables that configure it</summary>"
      echo
      echo "\`$(paste -sd, - <<<"$obs" | sed 's/,/`, `/g')\`"
      echo
      echo "</details>"
      echo
    fi
  fi

  # ------------------------------------------------------- what it drags
  local blast
  blast=$(jq -r --arg id "repo:$repo" '
    [.edges[] | select(.kind == "calls" and (.from == $id or .to == $id))
     | if .from == $id then "calls **" + (.to | sub("^repo:"; "")) + "** (`" + .evidence + "`)"
       else "called by **" + (.from | sub("^repo:"; "")) + "** (`" + .evidence + "`)" end]
    | unique | .[] | "- " + .' "$g" 2>/dev/null)
  local coupled=""
  [[ -f $DIR/map/coupling.json ]] && coupled=$(jq -r --arg r "$repo" '
    [.pairs[] | select(.a == $r or .b == $r)]
    | sort_by(-.days) | .[0:5][]
    | "- **" + (if .a == $r then .b else .a end) + "** — merged the same day \(.days)× by "
      + (.authors | join(", "))' "$DIR/map/coupling.json" 2>/dev/null || true)

  if [[ -n $blast || -n $coupled ]]; then
    echo "## What it drags with it"
    echo
    [[ -n $blast ]] && { echo "$blast"; echo; }
    if [[ -n $coupled ]]; then
      echo "$coupled"
      echo
      echo "Co-change comes from merged pull requests, not from the code. It is a hint about blast radius, not a dependency."
      echo
    fi
  fi

  # ------------------------------------------------------------ constraints
  local constraints
  constraints=$(runbook_constraints "$repo")
  if [[ -n $constraints ]]; then
    echo "## Do not"
    echo
    sed 's/^/- /' <<<"$constraints"
    echo
    echo "Lifted from the weekly recaps and \`DECISIONS.md\`. Each carries the pull request it came from."
    echo
  fi

  runbook_section "$repo" incident
  runbook_section "$repo" gotcha
  runbook_section "$repo" oncall

  # ------------------------------------------------------------ who and how
  local authors
  authors=$(find "$DIR/cache/prs" -name '*.json' -not -name '*.stats.json' 2>/dev/null |
    sort | tail -8 | xargs -r cat 2>/dev/null |
    jq -sr --arg r "$repo" '[.[].prs[]? | select(.repository.name == $r) | .author.login // "unknown"]
      | group_by(.) | map({a: .[0], n: length}) | sort_by(-.n) | .[0:5][]
      | "- \(.a) — \(.n) merged"' 2>/dev/null || true)
  if [[ -n $authors ]]; then
    echo "## Who has been in here"
    echo
    echo "$authors"
    echo
    echo "From merged pull requests in the cached weeks. Recent activity, not ownership."
    echo
  fi

  jq -r --argjson p "$prof" '
    $p.agent_docs as $d
    | if ($d | length) == 0 then empty
      else ["## House rules", ""]
           + ($d | map("- [`" + . + "`](" + ($p.meta.url // "") + "/blob/"
                       + ($p.meta.default_branch // "main") + "/" + . + ")"))
           + [""] | .[] end' <<<'{}'

  echo "---"
  echo
  echo "Something here wrong or missing? \`orgami note --repo $repo --tag gotcha\` and it lands in this file next time."
}

# One tagged-note section, printed only when there is something to print.
runbook_section() {
  local repo=$1 tag=$2 body
  body=$(runbook_notes_tagged "$repo" "$tag")
  [[ -n $body ]] || return 0
  echo "## $(runbook_tag_heading "$tag")"
  echo
  echo "$body"
  echo
}

runbook_org() {
  local out="$DIR/map/RUNBOOK.md"
  local profiles="$DIR/map/repos.json" g="$DIR/map/graph.json"

  {
    echo "# $COMPANY — operations"
    echo
    echo "$(jq 'length' "$profiles") repositories in \`$ORG\`, scanned $(jq -r '.generated | .[0:10]' "$g")."
    echo "Per-repo runbooks are in \`runbooks/\`. Everything here is derived from the"
    echo "repositories, the merged pull requests, and what the team has recorded."
    echo

    echo "## How things ship"
    echo
    echo "| Repo | Deploys from | Trigger | Environment |"
    echo "|---|---|---|---|"
    jq -r '.[] | .name as $n | (.workflows[]? | select(.deploys)
      | "| [" + $n + "](runbooks/" + $n + ".md) | `" + .file + "` | "
        + (.on | join(" / ")) + " | " + (if (.environment // "") == "" then "—" else "`" + .environment + "`" end) + " |")' \
      "$profiles"
    echo

    local nodeploy
    nodeploy=$(jq -r '.[] | select([.workflows[]?|select(.deploys)] | length == 0) | .name' "$profiles" |
      sort | paste -sd, - | sed 's/,/, /g')
    if [[ -n $nodeploy ]]; then
      echo "**No deploying workflow:** $nodeploy"
      echo
      echo "These either do not ship, or ship by a route this scan cannot see. Where you know the answer, record it: \`orgami note --repo <repo> --tag deploy\`."
      echo
    fi

    echo "## Shared services"
    echo
    jq -r '. as $g | [$g.nodes[] | select(.kind == "service")] | sort_by(.name)[]
      | .name as $s
      | "- **" + $s + "** — "
        + ([$g.edges[] | select(.to == ("service:" + $s)) | .from | sub("^repo:"; "")] | unique | join(", "))' "$g"
    echo

    echo "## Health endpoints"
    echo
    jq -r '.[] | .name as $n | [.routes[]? | select(test("/(health|healthz|status|ping|ready|live)"; "i"))]
      | if length == 0 then empty else "- **" + $n + "** — `" + .[0] + "`" end' "$profiles"
    echo

    echo "## Where the alerts go"
    echo
    jq -r '.[] | .name as $n
      | [.env[]? | (match("SENTRY|BETTERSTACK|DATADOG|NEW_?RELIC|LOGTAIL|ROLLBAR|GRAFANA|HONEYCOMB|BUGSNAG|PROMETHEUS") | .string)] | unique
      | if length == 0 then empty else "- **" + $n + "** — " + join(", ") end' "$profiles"
    echo

    local constraints=""
    [[ -d $DIR/map/decisions ]] &&
      constraints=$(cat "$DIR/map/decisions"/*.md 2>/dev/null | grep '^- ' | head -20)
    if [[ -n $constraints ]]; then
      echo "## Standing constraints"
      echo
      echo "$constraints"
      echo
      echo "The full record, week by week, is in \`DECISIONS.md\`."
      echo
    fi

    local recorded
    recorded=$(notes_index 2>/dev/null | jq -r '
      [.[] | select((.tags // "") != "")] | length' 2>/dev/null || echo 0)
    echo "## What the team has recorded"
    echo
    if [[ ${recorded:-0} -gt 0 ]]; then
      notes_index | jq -r '
        [.[] | select((.tags // "") != "")]
        | group_by((.tags // "") | gsub("[\\[\\] ]"; "") | split(",")[0])[]
        | "### " + (.[0].tags | gsub("[\\[\\] ]"; "") | split(",")[0]) + "\n"
          + ([.[] | "- " + (if (.repo // "") != "" then "**" + .repo + "** — " else "" end)
              + (.body | gsub("^\\n+"; "") | gsub("\\n+$"; "") | gsub("\\n"; " "))
              + " <sub>" + .author + ", " + (.date | .[0:10]) + "</sub>"] | join("\n"))'
      echo
    else
      echo "Nothing recorded yet. The first person to lose an afternoon to something"
      echo "should write it down:"
      echo
      echo '```bash'
      echo "orgami note --repo <repo> --tag gotcha"
      echo '```'
      echo
      echo "Tags that land a note in a runbook section: \`${RUNBOOK_TAGS[*]}\`."
      echo
    fi
  } >"$out"

  echo "$out" >&2
}

cmd_runbook() {
  load_company
  source "$ROOT/lib/notes.sh" 2>/dev/null || true
  [[ -f $DIR/map/repos.json ]] || die "no map yet — run: orgami scan"

  local repo=${1:-}
  if [[ -n $repo ]]; then
    runbook_render "$repo" || die "'$repo' is not in the map — orgami view to browse"
    return 0
  fi

  mkdir -p "$DIR/map/runbooks"
  local n
  while read -r n; do
    [[ -n $n ]] || continue
    runbook_render "$n" >"$DIR/map/runbooks/$n.md" 2>/dev/null || true
  done < <(jq -r '.[].name' "$DIR/map/repos.json")
  runbook_org
  echo "$(jq 'length' "$DIR/map/repos.json") runbooks in $DIR/map/runbooks/"
}
