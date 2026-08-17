# shellcheck shell=bash
# orgami view — fzf TUI over the graph. orgami query — the same detail as text.

# Resolves "api", "repo:api", "host:1.2.3.4" to a node id present in the graph.
resolve_id() {
  local g=$1 want=$2
  jq -r --arg w "$want" '
    [.nodes[] | select(.id == $w or .name == $w
                       or (.id | endswith(":" + $w)))] | .[0].id // empty' "$g"
}

node_detail() {
  local g=$1 id=$2 color=${3:-0}
  local b="" d="" r=""
  if [[ $color == 1 ]]; then
    b=$'\033[1m'; d=$'\033[2m'; r=$'\033[0m'
  fi

  jq -r --arg id "$id" --arg b "$b" --arg d "$d" --arg r "$r" '
    . as $g
    | ($g.nodes[] | select(.id == $id)) as $n
    | [
        $b + $n.name + $r + "  " + $d + "(" + $n.kind + ")" + $r,
        ""
      ]
      + (if ($n.meta | length) > 0 then
          [($n.meta | to_entries[] | select(.value != null and .value != "" and .value != [])
            | "  " + $d + (.key | (. + "               ")[0:13]) + $r
              + (.value | if type == "array" then join(", ") else tostring end))]
          + [""]
         else [] end)
      + ([$g.edges[] | select(.from == $id)] | group_by(.kind) | map(
          [$b + (.[0].kind | ascii_upcase) + $r]
          + (map("  " + (.to | sub("^[a-z-]+:"; ""))
                 + (if .evidence == "" then "" else "  " + $d + .evidence + $r end))
             | unique)
          + [""]) | add // [])
      + (([$g.edges[] | select(.to == $id)]) as $in
         | if ($in | length) == 0 then []
           else [$b + "REFERENCED BY" + $r]
                + ($in | map("  " + (.from | sub("^[a-z-]+:"; ""))
                             + "  " + $d + .kind
                             + (if .evidence == "" then "" else " · " + .evidence end) + $r)
                   | unique)
                + [""]
           end)
      | .[]' "$g"
}

cmd_query() {
  load_company
  local g="$DIR/map/graph.json"
  [[ -f $g ]] || die "no graph — run: orgami scan"
  local want=${1:-}
  [[ -n $want ]] || die "usage: orgami query <repo|host|tool|service>"
  local id
  id=$(resolve_id "$g" "$want")
  [[ -n $id ]] || die "nothing called '$want' in the map — orgami view to browse"
  node_detail "$g" "$id" 0
}

# Hidden subcommand: the fzf preview calls back into this.
cmd_show() {
  load_company
  node_detail "$DIR/map/graph.json" "$1" 1
}

cmd_view() {
  load_company
  need fzf
  local g="$DIR/map/graph.json"
  [[ -f $g ]] || die "no graph — run: orgami scan"

  local header
  header=$(printf '%s · %s · %s nodes / %s edges · mapped %s' \
    "$COMPANY" "$ORG" \
    "$(jq '.nodes | length' "$g")" "$(jq '.edges | length' "$g")" \
    "$(jq -r '.generated | .[0:10]' "$g")")

  jq -r '
    def icon: {repo: "▪", host: "◆", tool: "⚙", service: "▣", lang: "·"}[.] // "·";
    .nodes
    | sort_by((.kind == "repo" | not), .kind, .name)[]
    | .id + "\t" + (.kind | icon) + " " + ((.name + "                              ")[0:30])
      + "  " + .kind
      + (if .meta.language then "  " + .meta.language else "" end)
      + (if .meta.description then "  " + (.meta.description[0:60]) else "" end)' "$g" |
    fzf --ansi --delimiter='\t' --with-nth=2.. \
      --header="$header  ·  ctrl-o opens on GitHub  ·  enter prints the node" \
      --header-first \
      --prompt='map> ' \
      --info=inline \
      --preview="ORGAMI_COMPANY=$COMPANY '$ORGAMI_BIN' show {1}" \
      --preview-window='right:62%:wrap' \
      --bind="ctrl-o:execute-silent(ORGAMI_COMPANY=$COMPANY '$ORGAMI_BIN' open {1})" |
    cut -f1 |
    while read -r id; do
      [[ -n $id ]] || continue
      node_detail "$g" "$id" 1
    done
}

# ctrl-o in the TUI: open the node's GitHub page.
cmd_open() {
  load_company
  local url
  url=$(jq -r --arg i "$1" '.nodes[] | select(.id == $i) | .meta.url // empty' \
    "$DIR/map/graph.json")
  [[ -n $url ]] && xdg-open "$url" >/dev/null 2>&1 &
  return 0
}
