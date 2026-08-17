# orgami doc — render map/graph.json into map/ARCHITECTURE.md.
# Deterministic. --narrate adds one Claude-written intro on top of the same facts.

cmd_doc() {
  load_company
  local narrate=0 model=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --narrate) narrate=1; shift ;;
      --model) model=$2; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  local g="$DIR/map/graph.json"
  [[ -f $g ]] || die "no graph — run: orgami scan"
  local out="$DIR/map/ARCHITECTURE.md"

  {
    echo "# $COMPANY architecture"
    echo
    echo "GitHub organization \`$ORG\` · $(jq -r '[.nodes[] | select(.kind=="repo")] | length' "$g") active repos · \
mapped $(jq -r '.generated | .[0:10]' "$g")"
    echo

    if [[ $narrate == 1 ]]; then
      need claude
      [[ -n $model ]] || model=$(cfg report_model claude-sonnet-5)
      log "narrating with $model"
      {
        cat <<'PROMPT'
Below is a dependency graph of an engineering organization, built by static
inspection of every repository. Write a short "How this fits together" section:
three to six paragraphs, GitHub-flavored markdown, no heading of its own.

Describe the shape of the system: which repos are central, which are leaves,
what the deployment story is, where the coupling is, and what looks fragile or
inconsistent (two deploy tools for the same kind of service, a repo nothing
references, a host reached from many repos). Only state what the graph supports;
edges carry file:line evidence, use it. Say plainly when the graph is too sparse
to conclude something. No praise, no filler.
PROMPT
        printf '\nGRAPH\n```json\n'
        cat "$g"
        printf '\n```\n'
      } | claude -p --model "$model" --output-format text || die "claude failed"
      echo
    fi

    echo "## Repositories"
    echo
    echo "| Repo | Language | Deployed with | Depends on | Reaches |"
    echo "|---|---|---|---|---|"
    jq -r '
      . as $g
      | [$g.nodes[] | select(.kind == "repo")] | sort_by(.name)[]
      | .name as $n
      | ("repo:" + $n) as $id
      | [
          "[" + $n + "](" + (.meta.url // "") + ")",
          (.meta.language // "—"),
          ([$g.edges[] | select(.from == $id and .kind == "uses")
            | .to | sub("^tool:"; "")] | unique | join(", ") | if . == "" then "—" else . end),
          ([$g.edges[] | select(.from == $id and .kind == "depends-on")
            | .to | sub("^service:"; "")] | unique | join(", ") | if . == "" then "—" else . end),
          ([$g.edges[] | select(.from == $id and .kind == "references")
            | .to | sub("^repo:"; "")] | unique | join(", ") | if . == "" then "—" else . end)
        ] | "| " + join(" | ") + " |"' "$g"
    echo

    local links
    links=$(jq -r '[.edges[] | select(.kind == "references")] | length' "$g")
    echo "## How the repositories reference each other"
    echo
    if [[ $links -gt 0 ]]; then
      echo '```mermaid'
      echo "graph LR"
      jq -r '.edges[] | select(.kind == "references")
             | "  " + (.from | sub("^repo:"; "") | gsub("[^a-zA-Z0-9]"; "_"))
               + "[" + (.from | sub("^repo:"; "")) + "] --> "
               + (.to | sub("^repo:"; "") | gsub("[^a-zA-Z0-9]"; "_"))
               + "[" + (.to | sub("^repo:"; "")) + "]"' "$g" | sort -u
      echo '```'
      echo
      echo "<details><summary>Evidence for each edge</summary>"
      echo
      jq -r '.edges[] | select(.kind == "references")
             | "- `" + (.from | sub("^repo:"; "")) + "` → `"
               + (.to | sub("^repo:"; "")) + "` — `" + .evidence + "`"' "$g" | sort -u
      echo
      echo "</details>"
    else
      echo "No repository references another by URL, container image, or package name."
      echo "Either the services are genuinely independent, or they find each other"
      echo "through configuration this scan cannot see (runtime environment variables,"
      echo "service discovery, a shared gateway)."
    fi
    echo

    echo "## Deployment"
    echo
    jq -r '
      . as $g
      | [$g.nodes[] | select(.kind == "tool")] | sort_by(.name)[]
      | .name as $t
      | "### " + $t + "\n\n"
        + ([$g.edges[] | select(.to == ("tool:" + $t) and .kind == "uses")
            | "- `" + (.from | sub("^repo:"; "")) + "` — `" + .evidence + "`"]
           | unique | join("\n"))
        + "\n"' "$g"

    echo "## Hosts and endpoints"
    echo
    local hosts
    hosts=$(jq -r '[.nodes[] | select(.kind == "host")] | length' "$g")
    if [[ $hosts -gt 0 ]]; then
      echo "| Host | Reached from | Evidence |"
      echo "|---|---|---|"
      jq -r '
        . as $g
        | [$g.nodes[] | select(.kind == "host")] | sort_by(.name)[]
        | .name as $h
        | [$g.edges[] | select(.to == ("host:" + $h))] as $in
        | "| `" + $h + "` | "
          + ([$in[] | .from | sub("^repo:"; "")] | unique | join(", ")) + " | `"
          + ([$in[] | .evidence] | unique | join("`, `")) + "` |"' "$g"
      echo
      echo "> Hosts are extracted from deployment configuration by pattern match."
      echo "> Check the evidence column before trusting one."
    else
      echo "No hosts found in deployment configuration."
    fi
    echo

    echo "## Backing services"
    echo
    jq -r '
      . as $g
      | [$g.nodes[] | select(.kind == "service")] as $svc
      | if ($svc | length) == 0 then
          "No databases, queues, or caches are declared in committed configuration. They may still exist — provisioned by hand, or wired in at runtime."
        else ($svc | sort_by(.name)[]
          | .name as $s
          | "- **" + $s + "** — "
            + ([$g.edges[] | select(.to == ("service:" + $s)) | .from | sub("^repo:"; "")]
               | unique | join(", ")))
        end' "$g"
    echo

    echo "## Unconnected repositories"
    echo
    jq -r '
      . as $g
      | [$g.nodes[] | select(.kind == "repo") | .name as $n | ("repo:" + $n) as $id
         | select([$g.edges[] | select(.kind == "references" and (.from == $id or .to == $id))] | length == 0)
         | select([$g.edges[] | select(.kind == "uses" and .from == $id)] | length == 0)
         | $n] as $orphans
      | if ($orphans | length) == 0 then "Every repository is connected to something."
        else "These repos reference no other repo and declare no deployment tooling — libraries, archives, or scratch:\n\n"
             + ($orphans | map("- `" + . + "`") | join("\n"))
        end' "$g"
    echo
    echo "---"
    echo
    echo "<sub>Generated by [orgami](https://github.com/achevalier-dev/orgami). \
Every edge carries \`file:line\` evidence — verify before acting on it.</sub>"
  } >"$out"

  echo "$out"
}
