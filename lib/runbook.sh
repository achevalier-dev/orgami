# shellcheck shell=bash
# The operational half of the map: how a repo runs, how it ships, what breaks,
# and what the team has already learned the hard way. Everything here is derived
# or quoted — no model writes any of it.

# Tags that place a note into a runbook section. Anything else stays a plain note.
RUNBOOK_TAGS=(setup deploy rollback incident alert gotcha oncall)

runbook_tag_heading() {
  case $1 in
    setup) echo "Getting it running" ;;
    deploy) echo "Deploying it" ;;
    rollback) echo "Rolling it back" ;;
    incident) echo "When it broke before" ;;
    alert) echo "When an alert fires" ;;
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

# Everything the weekly recaps recorded as broken in this repo, verbatim and
# newest first. They are already written as symptom, real cause, and the pull
# request that fixed it — which is what a runbook entry is.
runbook_seen_before() {
  local repo=$1 f week
  for f in $(find "$DIR/reports" -maxdepth 1 -name '*.md' 2>/dev/null | sort -r); do
    week=$(basename "$f" .md)
    sed -n '/^## What got fixed/,/^## [A-Z]/p;/^## Security/,/^## [A-Z]/p' "$f" 2>/dev/null |
      grep '^- ' | grep -- "/$repo#" |
      sed "s|^- |- |; s|\$| <sub>$week</sub>|"
  done | head -20
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
     ($p.frameworks | if length > 0 then join(", ") else empty end),
     (if ($p.meta.private // false) then "private" else "public" end)]
    | map(select(. != null and . != "")) | join(" · ")' <<<'{}'
  echo
  jq -r --argjson p "$prof" '
    if ($p.meta.description // "") == "" then empty
    else ($p.meta.description, "") end' <<<'{}'
  echo "<sub>Derived from the scan of $(jq -r '.generated | .[0:10]' "$g"). Nothing here was written by a model.</sub>"
  echo

  # ---------------------------------------------------------------- run it
  #
  # A runbook is read by someone who needs one command, not a catalogue. The
  # four that matter go first, under the role they play; everything else the
  # repository declares is kept, folded away.
  echo "## Run it"
  echo
  jq -r --argjson p "$prof" '
    def install:
      { pnpm: "pnpm install", yarn: "yarn install", npm: "npm ci", bun: "bun install",
        bundler: "bundle install", poetry: "poetry install", pip: "pip install -r requirements.txt",
        uv: "uv sync", cargo: "cargo fetch", go: "go mod download", composer: "composer install",
        mix: "mix deps.get" }[$p.commands.package_manager // ""] // "";

    # The first script whose name matches each role, in the order a person needs
    # them. Anything not claimed here is still listed, just not first.
    def pick($names): ($p.commands.scripts // {}) | to_entries
      | map(select(.key as $k | $names | index($k))) | .[0];

    (pick(["dev", "start", "serve", "run"])) as $run
    | (pick(["test"])) as $test
    | (pick(["build", "compile"])) as $build
    | (pick(["typecheck", "lint", "check"])) as $check
    | [$run, $test, $build, $check] as $first
    | [$first[] | select(. != null) | .key] as $claimed

    | (if ($p.commands.runtime // "") != "" or ($p.commands.package_manager // "") != ""
       then ["Needs " + ([($p.commands.runtime // empty), ($p.commands.package_manager // empty)]
             | map(select(. != null and . != "")) | join(", ")) + ".", ""]
       else [] end)

      + (if install != "" then ["First time here:", "", "```bash", install, "```", ""] else [] end)

      + (if ($first | map(select(. != null)) | length) > 0
         then ($first | map(select(. != null))
               | map("- **" + (if .key | test("^(dev|start|serve|run)$") then "run"
                               elif .key == "test" then "test"
                               elif .key | test("^(build|compile)$") then "build"
                               else "check" end)
                     + "** — `" + .value + "`"))
              + [""]
         else [] end)

      + (($p.commands.scripts // {}) | to_entries
         | map(select(.key as $k | ($claimed | index($k)) | not))
         | if length == 0 then [] else
             ["<details><summary>" + (length | tostring) + " more script"
              + (if length == 1 then "" else "s" end) + " the repository declares</summary>", ""]
             + map("- `" + .key + "` — `" + .value + "`")
             + ["", "</details>", ""]
           end)

      + (if (($p.commands.scripts // {}) | length) == 0
         then ["No run or test command is declared in the repository.", ""] else [] end)

      + (if (($p.commands.procfile // []) | length) > 0
         then ["Processes: `" + ($p.commands.procfile | join("`, `")) + "`", ""]
         else [] end)
    | .[]' <<<'{}'

  # What it reads. Naming the variables is the useful part; sorting them into
  # "points somewhere" and "does not" only earned a line that said nothing.
  local envcount
  envcount=$(jq -r --argjson p "$prof" '$p.env | length' <<<'{}')
  if [[ ${envcount:-0} -gt 0 ]]; then
    jq -r --argjson p "$prof" '
      ([$p.env[] | select(test("_(URL|HOST|ENDPOINT|BASE|BUCKET|QUEUE|TOPIC|DSN)$"))]) as $ext
      | ["It reads " + ($p.env | length | tostring) + " environment variable"
         + (if ($p.env | length) == 1 then "" else "s" end) + ": `"
         + ($p.env | join("`, `")) + "`.", ""]
        + (if ($ext | length) > 0
           then ["Of those, `" + ($ext | join("`, `")) + "` "
                 + (if ($ext | length) == 1 then "points" else "point" end)
                 + " at something outside this repository.", ""]
           else [] end)
      | .[]' <<<'{}'
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

  # What must be green before anything merges. Same data, different question.
  jq -r --argjson p "$prof" '
    [$p.workflows[]? | select((.deploys | not) and ((.on // []) | index("pull_request")))] as $ci
    | if ($ci | length) == 0 then empty
      else ["Before a merge, these run: "
            + ($ci | map("**" + .name + "**") | join(", ")) + "."]
      end | .[]' <<<'{}'
  echo

  runbook_section "$repo" deploy

  # Rolling back is derived from how it ships, and says so. A note tagged
  # rollback overrides it, because a person who has done it knows better.
  local rollback_note
  rollback_note=$(runbook_notes_tagged "$repo" rollback)
  if [[ -n $rollback_note ]]; then
    echo "## Rolling it back"
    echo
    echo "$rollback_note"
    echo
  else
    jq -r --argjson p "$prof" '
      [$p.workflows[]? | select(.deploys)] as $d
      | if ($d | length) == 0 then empty
        else
          ["## Rolling it back", ""]
          + (if ($d[0].on // []) | index("push") then
               ["Shipping runs on push, so the way back is a revert: put the previous state on the"
                + " default branch and the same workflow (`" + $d[0].file + "`) ships it."]
             elif ($d[0].on // []) | index("release") then
               ["Shipping runs on a release, so a rollback is another release of the previous tag"
                + " — `" + $d[0].file + "` runs again with it."]
             elif ($d[0].on // []) | index("workflow_dispatch") then
               ["`" + $d[0].file + "` can be dispatched by hand, so the previous ref can be shipped"
                + " again without touching the branch."]
             else
               ["How to undo a deploy is not visible in `" + $d[0].file + "`."]
             end)
          + ["", "Derived from the workflow, not from anyone having done it. Once you have, record"
             + " it with `orgami note --tag rollback` and this section becomes what you wrote.", ""]
        end | .[]' <<<'{}'
  fi

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

  local ships
  ships=$(jq -r --argjson p "$prof" '[$p.workflows[]? | select(.deploys)] | length' <<<'{}')
  if [[ -n $health || -n $obs || ${ships:-0} -gt 0 ]]; then
    echo "## Is it alive"
    echo
    if [[ -z $health && ${ships:-0} -gt 0 ]]; then
      echo "Nothing in the committed source answers on a health, status or readiness path, and this repository ships. Whatever tells you it is up lives somewhere this scan cannot see — \`orgami note --tag oncall\` puts it here."
      echo
    fi
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
    [.edges[] | select((.kind == "calls" or .kind == "references")
                       and (.from == $id or .to == $id)
                       and ((.from | startswith("repo:")) and (.to | startswith("repo:"))))
     | (if .kind == "calls" then ["calls", "called by"] else ["references", "referenced by"] end) as $v
     | if .from == $id
       then $v[0] + " **" + (.to | sub("^repo:"; "")) + "**"
            + (if (.evidence // "") == "" then "" else " (`" + .evidence + "`)" end)
       else $v[1] + " **" + (.from | sub("^repo:"; "")) + "**"
            + (if (.evidence // "") == "" then "" else " (`" + .evidence + "`)" end) end]
    | unique | .[0:14] | .[] | "- " + .' "$g" 2>/dev/null)
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

  local seen
  seen=$(runbook_seen_before "$repo")
  if [[ -n $seen ]]; then
    echo "## Seen before"
    echo
    echo "$seen"
    echo
    echo "Straight out of the weekly recaps — symptom, cause, and the pull request that fixed it. If one of these recurs, start here."
    echo
  fi

  runbook_section "$repo" incident
  runbook_section "$repo" alert
  runbook_section "$repo" gotcha
  runbook_section "$repo" oncall

  # ------------------------------------------------------------ who and how
  local authors
  authors=$(find "$DIR/cache/prs" -name '*.json' -not -name '*.stats.json' 2>/dev/null |
    sort | tail -8 | tr '\n' '\0' | xargs -0 cat 2>/dev/null |
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
      constraints=$(cat "$DIR/map/decisions"/*.md 2>/dev/null | grep '^- ' | head -20 || true)
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

# The page you open while something is broken: what pages you, what has broken
# before and what it turned out to be, and where the fires keep starting.
runbook_incidents_page() {
  local out="$DIR/map/INCIDENTS.md"
  local profiles="$DIR/map/repos.json" f week

  {
    echo "# $COMPANY — incidents"
    echo
    echo "What pages you, what has broken before, and what it turned out to be."
    echo "Assembled from the weekly recaps and what the team has recorded. Every"
    echo "entry carries the pull request that fixed it."
    echo

    echo "## What pages you"
    echo
    echo "| Repo | Alerting through | Health endpoint |"
    echo "|---|---|---|"
    jq -r '.[] | .name as $n
      | ([.env[]? | (match("SENTRY|BETTERSTACK|DATADOG|NEW_?RELIC|LOGTAIL|ROLLBAR|GRAFANA|HONEYCOMB|BUGSNAG") | .string)] | unique) as $a
      | ([.routes[]? | select(test("/(health|healthz|status|ping|ready|live)"; "i"))] | .[0]) as $h
      | select(($a | length) > 0 or $h != null)
      | "| [" + $n + "](runbooks/" + $n + ".md) | "
        + (if ($a | length) > 0 then ($a | join(", ")) else "—" end) + " | "
        + (if $h != null then "`" + $h + "`" else "—" end) + " |"' "$profiles"
    echo

    local silent
    silent=$(jq -r '.[] | select([.env[]? | select(test("SENTRY|BETTERSTACK|DATADOG|NEW_?RELIC|LOGTAIL|ROLLBAR|GRAFANA|HONEYCOMB|BUGSNAG"))] | length == 0)
      | select([.routes[]? | select(test("/(health|healthz|status|ping|ready|live)"; "i"))] | length == 0)
      | .name' "$profiles" | sort | paste -sd, - | sed 's/,/, /g' || true)
    if [[ -n $silent ]]; then
      echo "**Nothing reports on these:** $silent"
      echo
      echo "No alerting provider configured and no health endpoint served. If one of"
      echo "them breaks, you find out from a person."
      echo
    fi

    echo "## Where the fires start"
    echo
    while IFS= read -r -d '' f; do
      sed -n '/^## What got fixed/,/^## [A-Z]/p;/^## Security/,/^## [A-Z]/p' "$f" | grep '^- '
    done < <(find "$DIR/reports" -maxdepth 1 -name '*.md' -print0 2>/dev/null) | grep -oE '/[A-Za-z0-9_.-]+#[0-9]+' | sed -E 's|/([^#]+)#.*|\1|' |
      sort | uniq -c | sort -rn | head -10 |
      awk '{printf "- **%s** — named in %d recorded failures\n", $2, $1}'
    echo

    echo "## Everything recorded so far"
    echo
    for f in $(find "$DIR/reports" -maxdepth 1 -name '*.md' 2>/dev/null | sort -r); do
      week=$(basename "$f" .md)
      local fixes
      fixes=$(sed -n '/^## What got fixed/,/^## [A-Z]/p' "$f" | grep '^- ')
      local sec
      sec=$(sed -n '/^## Security/,/^## [A-Z]/p' "$f" | grep '^- ')
      [[ -n $fixes || -n $sec ]] || continue
      echo "### $week"
      echo
      [[ -n $fixes ]] && { echo "$fixes"; echo; }
      if [[ -n $sec ]]; then
        echo "Security:"
        echo
        echo "$sec"
        echo
      fi
    done

    echo "## What the team has recorded"
    echo
    local recorded
    recorded=$(notes_index 2>/dev/null | jq -r '
      [.[] | select((.tags // "") | gsub("[\\[\\] ]"; "") | split(",")
        | any(. == "incident" or . == "alert" or . == "gotcha"))]
      | .[]
      | "- " + (if (.repo // "") != "" then "**" + .repo + "** — " else "" end)
        + (.body | gsub("^\\n+"; "") | gsub("\\n+$"; "") | gsub("\\n"; " "))
        + " <sub>" + .author + ", " + (.date | .[0:10]) + "</sub>"' 2>/dev/null || true)
    if [[ -n $recorded ]]; then
      echo "$recorded"
      echo
    else
      echo "Nothing yet."
      echo
    fi
    echo "Next time you chase one down, leave it here for whoever gets paged next:"
    echo
    echo '```bash'
    echo "orgami note --repo <repo> --tag incident   # what broke and what it turned out to be"
    echo "orgami note --repo <repo> --tag alert      # what to do when this alert fires"
    echo '```'
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
  runbook_incidents_page
  echo "$(jq 'length' "$DIR/map/repos.json") runbooks in $DIR/map/runbooks/"
}
