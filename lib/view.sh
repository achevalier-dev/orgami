# shellcheck shell=bash
# orgami query — one node as text, rendered by the same code that draws the
# TUI's preview pane, so the two can never say different things. The browser
# itself lives in lib/tui.sh.

# Resolves "api", "repo:api", "host:1.2.3.4" to a node id present in the graph.
resolve_id() {
  local g=$1 want=$2
  jq -r --arg w "$want" '
    [.nodes[] | select(.id == $w or .name == $w
                       or (.id | endswith(":" + $w)))] | .[0].id // empty' "$g"
}

cmd_query() {
  load_company
  style_init
  local g="$DIR/map/graph.json"
  [[ -f $g ]] || die "no map yet — run: orgami scan"
  local want=${1:-}
  [[ -n $want ]] || die "usage: orgami query <repo|host|tool|service>"
  local id
  id=$(resolve_id "$g" "$want")
  [[ -n $id ]] || die "nothing called '$want' in the map — orgami view to browse"
  tui_preview "$id"
}

# Kept because earlier versions bound the fzf preview to it.
cmd_show() {
  load_company
  ORGAMI_COLOR=1 tui_preview "$1"
}

cmd_open() {
  load_company
  tui_open "$1"
}
