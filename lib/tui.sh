# shellcheck shell=bash
# orgami view — the map, the repos, the team's notes and the recaps in one
# screen. fzf draws it; every pane is rendered by a subcommand of this file, so
# the same renderers back `orgami query` and `orgami card` outside the TUI.
#
# State that has to survive a keystroke lives in one file named by
# ORGAMI_TUI_STATE, because fzf runs every binding in a fresh process.

TUI_TABS=(map repos notes recaps)
TUI_TAB_LABELS=(Map Repos Notes Recaps)

tui_tab() {
  local t
  t=$(cat "${ORGAMI_TUI_STATE-}" 2>/dev/null || echo 0)
  [[ $t =~ ^[0-9]+$ ]] || t=0
  echo $((t % ${#TUI_TABS[@]}))
}

tui_tab_name() { echo "${TUI_TABS[$(tui_tab)]}"; }

tui_cycle() {
  local step=${1:-1} cur n
  cur=$(tui_tab)
  n=${#TUI_TABS[@]}
  [[ -n ${ORGAMI_TUI_STATE-} ]] || die "no TUI session here"
  echo $(((cur + step + n) % n)) >"$ORGAMI_TUI_STATE"
}

# ------------------------------------------------------------------- chrome

tui_prompt() { printf '%s › ' "$(tui_tab_name)"; }

# The header and footer are drawn inside the list pane, which is what is left of
# the terminal once the preview has taken its share.
tui_list_cols() {
  local total pct
  total=$(style_cols)
  pct=${ORGAMI_TUI_PREVIEW_PCT:-52}
  echo $((total * (100 - pct) / 100 - 2))
}

# Two lines: who this is, and which tab you are on. The right-hand side of the
# first line is the state a person actually wonders about — how stale the map is
# and whether this week has a recap yet.
tui_header() {
  style_init
  local g="$DIR/map/graph.json" cols
  cols=$(tui_list_cols)

  local edges=0 repos=0 mapped='no map yet'
  if [[ -f $g ]]; then
    read -r edges repos mapped < <(jq -r '
      [(.edges | length),
       ([.nodes[] | select(.kind == "repo")] | length),
       (.generated | .[0:10])] | @tsv' "$g" | tr '\t' ' ')
    mapped="mapped $(tui_age "$(tui_days_since "$mapped")")"
  fi

  local week recap
  week=$(iso_week)
  if [[ -f $DIR/reports/$week.md ]]; then recap="recap $week"; else recap="no recap yet"; fi

  tui_line "${S_ACCENT}${S_B}orgami${S_R}${S_MUTED} · ${S_R}${S_B}${COMPANY}${S_R}${S_MUTED} · ${ORG}${S_R}" \
    "${S_MUTED}${mapped}${S_R}" "$cols"
  tui_line "$(tui_tabbar)" "${S_FAINT}${repos} repos · ${edges} edges · ${recap}${S_R}" "$cols"
}

# The same first line, for screens that are not the browser.
tui_status_line() {
  style_init
  local g="$DIR/map/graph.json" mapped='not mapped yet' repos=0 edges=0 week recap
  if [[ -f $g ]]; then
    read -r repos edges mapped < <(jq -r '
      [([.nodes[] | select(.kind == "repo")] | length), (.edges | length),
       (.generated | .[0:10])] | @tsv' "$g" | tr '\t' ' ')
    mapped="mapped $(tui_age "$(tui_days_since "$mapped")")"
  fi
  week=$(iso_week)
  if [[ -f $DIR/reports/$week.md ]]; then recap="recap $week"; else recap="no recap for $week"; fi
  tui_line "${S_ACCENT}${S_B}orgami${S_R}${S_MUTED} · ${S_R}${S_B}${COMPANY}${S_R}${S_MUTED} · ${ORG}${S_R}" \
    "${S_MUTED}${repos} repos · ${mapped} · ${recap}${S_R}" "$(style_cols)"
}

# Left, then right pushed to the edge — and if the two cannot both fit in the
# pane, the right-hand side is what goes, because it is the part a person can
# live without.
tui_line() {
  local left=$1 right=$2 width=$3 lw rw pad i gap=''
  lw=$(style_width "$left")
  rw=$(style_width "$right")
  if ((lw + rw + 2 > width)); then
    printf '%s\n' "$left"
    return 0
  fi
  pad=$((width - lw - rw))
  for ((i = 0; i < pad; i++)); do gap+=' '; done
  printf '%s%s%s\n' "$left" "$gap" "$right"
}

tui_tabbar() {
  local cur i line=''
  cur=$(tui_tab)
  for i in "${!TUI_TAB_LABELS[@]}"; do
    if [[ $i == "$cur" ]]; then
      line+="${S_ACCENT}${S_B} ${TUI_TAB_LABELS[$i]} ${S_R}"
    else
      line+="${S_FAINT} ${TUI_TAB_LABELS[$i]} ${S_R}"
    fi
    [[ $i -lt $((${#TUI_TAB_LABELS[@]} - 1)) ]] && line+="${S_RULE}│${S_R}"
  done
  printf '%s\n' "$line"
}

tui_footer() {
  style_init
  local k="${S_MUTED}" v="${S_FAINT}" r="${S_R}"
  printf '%stab%s switch %s·%s %stype%s filter %s·%s %senter%s print %s·%s %sctrl-o%s github %s·%s %sctrl-n%s note %s·%s %sesc%s quit\n' \
    "$k" "$r" "$v" "$r" "$k" "$r" "$v" "$r" "$k" "$r" "$v" "$r" \
    "$k" "$r" "$v" "$r" "$k" "$r" "$v" "$r" "$k" "$r"
}

# Whole days between an ISO date and today, without GNU-only date maths.
tui_days_since() {
  local stamp now
  stamp=$(date -u -d "${1}T00:00:00Z" +%s 2>/dev/null ||
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${1}T00:00:00Z" +%s 2>/dev/null || echo 0)
  now=$(date -u +%s)
  [[ $stamp -gt 0 ]] || { echo 0; return; }
  echo $(((now - stamp) / 86400))
}

tui_age() {
  local d=$1
  if ((d <= 0)); then echo "today"
  elif ((d == 1)); then echo "yesterday"
  elif ((d < 14)); then echo "${d}d ago"
  elif ((d < 60)); then echo "$((d / 7))w ago"
  else echo "$((d / 30))mo ago"; fi
}

# --------------------------------------------------------------------- rows
#
# Every row is "<id>\t<what you see>". fzf shows column two and hands column
# one back to the preview and to the key bindings.

tui_colors_json() {
  jq -n --arg repo "$(style_kind_color repo)" --arg host "$(style_kind_color host)" \
    --arg tool "$(style_kind_color tool)" --arg service "$(style_kind_color service)" \
    --arg lang "$(style_kind_color lang)" \
    '{repo:$repo, host:$host, tool:$tool, service:$service, lang:$lang}'
}

tui_icons_json() {
  jq -n --arg repo "$(style_kind_icon repo)" --arg host "$(style_kind_icon host)" \
    --arg tool "$(style_kind_icon tool)" --arg service "$(style_kind_icon service)" \
    --arg lang "$(style_kind_icon lang)" \
    '{repo:$repo, host:$host, tool:$tool, service:$service, lang:$lang}'
}

tui_rows_map() {
  local g="$DIR/map/graph.json"
  [[ -f $g ]] || { tui_empty "no map yet" "orgami scan builds it"; return 0; }
  jq -r --argjson c "$(tui_colors_json)" --argjson i "$(tui_icons_json)" \
    --arg m "$S_MUTED" --arg d "$S_FAINT" --arg r "$S_R" '
    def pad($n): (. + "                                                  ")[0:$n];
    .nodes
    | sort_by((.kind == "repo" | not), .kind, (.name | startswith(".")), (.name | ascii_downcase))[]
    | . as $n
    | (($c[$n.kind]) // $d) as $col
    | (($i[$n.kind]) // "·") as $ico
    | $n.id + "\t" + $col + $ico + " " + $r + ($n.name | pad(24))
      + $m + ($n.kind | pad(8)) + $r
      + $d + (($n.meta.language // "") | pad(12))
      + (($n.meta.description // "") | .[0:48]) + $r' "$g"
}

tui_rows_repos() {
  local g="$DIR/map/graph.json" p="$DIR/map/repos.json"
  [[ -f $g ]] || { tui_empty "no map yet" "orgami scan builds it"; return 0; }
  local profiles='[]'
  [[ -f $p ]] && profiles=$(cat "$p")
  jq -r --argjson prof "$profiles" --arg now "$(date -u +%s)" \
    --arg a "$(style_kind_color repo)" --arg m "$S_MUTED" --arg d "$S_FAINT" --arg r "$S_R" '
    def pad($n): (. + "                                                  ")[0:$n];
    def age($iso): if ($iso // "") == "" then ""
      else ((($now | tonumber) - ($iso | fromdateiso8601)) / 86400 | floor) as $days
        | if $days <= 1 then "today" elif $days < 14 then "\($days)d"
          elif $days < 60 then "\($days / 7 | floor)w" else "\($days / 30 | floor)mo" end
      end;
    . as $g
    | [$g.edges[] | .from] as $out
    | [$g.edges[] | .to] as $in
    | [.nodes[] | select(.kind == "repo")]
    | sort_by((.name | startswith(".")), (.name | ascii_downcase))[]
    | . as $n
    | ($prof[] | select(.name == $n.name)) as $pr
    | (($pr.frameworks // []) | join(", ")) as $fw
    | (([$out[] | select(. == $n.id)] | length) + ([$in[] | select(. == $n.id)] | length)) as $links
    | $n.id + "\t" + $a + "▪ " + $r + ($n.name | pad(22))
      + $d + (($n.meta.language // "") | pad(12)) + $r
      + $m + (($fw | if . == "" then (($pr.commands.runtime // "") | tostring) else . end)
              | .[0:15] | pad(16)) + $r
      + $d + (($links | tostring) + " links" | pad(9))
      + age($n.meta.pushed_at) + $r' "$g"
}

tui_rows_notes() {
  local n="$DIR/notes"
  [[ -d $n ]] && compgen -G "$n/*.md" >/dev/null ||
    { tui_empty "no notes yet" "orgami note records what the map cannot"; return 0; }
  source "$ROOT/lib/notes.sh"
  notes_index | jq -r --arg now "$(date -u +%s)" \
    --arg a "$(style_kind_color repo)" --arg m "$S_MUTED" --arg d "$S_FAINT" --arg r "$S_R" '
    def pad($n): (. + "                                                            ")[0:$n];
    def age($iso): ((($now | tonumber) - ($iso | fromdateiso8601)) / 86400 | floor) as $days
      | if $days <= 1 then "today" elif $days < 14 then "\($days)d ago"
        elif $days < 60 then "\($days / 7 | floor)w ago" else "\($days / 30 | floor)mo ago" end;
    .[]
    | ((.body | split("\n") | map(select(. != "")) | .[0]) // "(empty)") as $first
    | "note:" + .file + "\t" + $a + "✎ " + $r
      + ($first | if length > 46 then (.[0:45] + "…") else . end | pad(47))
      + $m + ((.repo // "org-wide") | .[0:14] | pad(15)) + $r
      + $d + (.author | .[0:12]) + " · " + (age(.date) | sub(" ago$"; "")) + $r'
}

tui_rows_recaps() {
  local d="$DIR/reports" f week first
  [[ -d $d ]] && compgen -G "$d/*.md" >/dev/null ||
    { tui_empty "no recaps yet" "orgami report writes this week's"; return 0; }
  while IFS= read -r f; do
    week=$(basename "$f" .md)
    first=$(grep -m1 -E '^[A-Za-z]' "$f" 2>/dev/null | cut -c1-70)
    printf 'recap:%s\t%s▤ %s%s%s  %s%s%s\n' \
      "$f" "$(style_kind_color repo)" "$S_R" "$(printf '%-12s' "$week")" "$S_R" \
      "$S_FAINT" "$first" "$S_R"
  done < <(find "$d" -maxdepth 1 -name '*.md' | sort -r)
}

# A tab with nothing in it says what would put something there, rather than
# drawing an empty box.
tui_empty() {
  printf 'empty:\t%s%s%s  %s%s%s\n' "$S_MUTED" "$1" "$S_R" "$S_FAINT" "${2-}" "$S_R"
}

tui_rows() {
  style_init
  case $(tui_tab_name) in
    map) tui_rows_map ;;
    repos) tui_rows_repos ;;
    notes) tui_rows_notes ;;
    recaps) tui_rows_recaps ;;
  esac
}

# ------------------------------------------------------------------ preview

# The repo pane. Everything here is read out of the map, and every line that
# claims something carries the file it was read from.
tui_card() {
  local name=$1 g="$DIR/map/graph.json" p="$DIR/map/repos.json" w
  w=$(style_cols)
  local profiles='[]' notes='[]'
  [[ -f $p ]] && profiles=$(cat "$p")
  if compgen -G "$DIR/notes/*.md" >/dev/null 2>&1; then
    source "$ROOT/lib/notes.sh"
    notes=$(notes_index)
  fi

  jq -r --arg name "$name" --argjson prof "$profiles" --argjson notes "$notes" \
    --arg now "$(date -u +%s)" --argjson w "$w" \
    --arg b "$S_B" --arg d "$S_FAINT" --arg m "$S_MUTED" --arg a "$S_ACCENT" \
    --arg ok "$S_OK" --arg warn "$S_WARN" --arg rule "$S_RULE" --arg r "$S_R" '
    def pad($n): (. + "                                                            ")[0:$n];
    def rule: $rule + ("─" * (if $w > 4 then $w - 2 else 20 end)) + $r;
    def age($iso): if ($iso // "") == "" then "" else
      ((($now | tonumber) - ($iso | fromdateiso8601)) / 86400 | floor) as $days
      | if $days <= 1 then "today" elif $days < 14 then "\($days)d ago"
        elif $days < 60 then "\($days / 7 | floor)w ago" else "\($days / 30 | floor)mo ago" end
      end;
    def clip($n): if ($n > 1 and length > $n) then (.[0:($n - 1)] + "…") else . end;
    def elide($n): if length > $n then ("…" + .[(length - $n + 1):]) else . end;
    def field($label; $value): "  " + $m + ($label | pad(18)) + $r + $value;

    (if $w > 74 then 30 elif $w > 56 then 24 else 18 end) as $lw
    | (if $w - $lw - 4 > 12 then $w - $lw - 4 else 12 end) as $ew
    | def evidence($e): if ($e // "") == "" then "" else $d + ($e | elide($ew)) + $r end;
    . as $g
    | ($g.nodes[] | select(.id == "repo:" + $name)) as $n
    | (($prof[] | select(.name == $name)) // {}) as $pr
    | [$g.edges[] | select(.from == "repo:" + $name)] as $out
    | [$g.edges[] | select(.to == "repo:" + $name)] as $in

    | [
        $a + "▪ " + $b + $name + $r + "  " + $m + (($n.meta.language // "unmapped"))
          + (if (($pr.frameworks // []) | length) > 0 then " · " + ($pr.frameworks | join(" · ")) else "" end)
          + (if ($n.meta.private // false) then " · private" else "" end)
          + (if ($n.meta.pushed_at // "") != "" then " · pushed " + age($n.meta.pushed_at) else "" end)
          + $r
      ]
      + (if (($n.meta.description // "") | length) > 0
         then ["  " + $d + ($n.meta.description | clip($w - 4)) + $r] else [] end)
      + [rule]

      + (($pr.commands.scripts // {}) | to_entries
         | if length == 0 then [] else
             [$m + $b + "RUN IT" + $r]
             + (.[0:6] | map(field(.key | clip(17); $d + (.value | clip($w - 24)) + $r)))
           end)
      + (if (($pr.commands.runtime // "") + ($pr.commands.package_manager // "")) == "" then []
         else ["  " + $d + ([($pr.commands.package_manager // ""), ($pr.commands.runtime // "")]
                            | map(select(. != "")) | join(" · ")) + $r] end)

      + (($out + $in) | map(select(.kind == "references" or .kind == "calls" or .kind == "changes-with"))
         | if length == 0 then [] else
             [""] + [$m + $b + "TALKS TO" + $r]
             + (map(
                 (if .from == "repo:" + $name then "→ " + (.to | sub("^[a-z-]+:"; ""))
                  else "← " + (.from | sub("^[a-z-]+:"; "")) end) as $peer
                 | "  " + ($peer | pad($lw)) + evidence(.evidence))
                | unique | .[0:8])
           end)

      + ($out | map(select(.kind == "deploys-to" or .kind == "uses" or .kind == "depends-on"))
         | if length == 0 then
             ["", $m + $b + "RUNS ON" + $r,
              "  " + $d + "nothing committed here says where this deploys" + $r]
           else
             [""] + [$m + $b + "RUNS ON" + $r]
             + (map("  " + ((.to | sub("^[a-z-]+:"; "")) | pad($lw)) + evidence(.evidence))
                | unique | .[0:8])
           end)

      + (($pr.workflows // []) | map(select(.deploys)) | if length == 0 then [] else
           [""] + [$m + $b + "SHIPS" + $r]
           + (.[0:4] | map("  " + (((.name // "workflow")
               + (if ((.on // []) | length) > 0 then " on " + ((.on // []) | join(", ")) else "" end))
               | pad($lw)) + evidence(.file)))
         end)

      + (($pr.routes // []) | if length == 0 then [] else
           [""] + [$m + $b + "SERVES" + $r + $d + "  \(length)" + $r]
           + (.[0:4] | map(
               (. | capture("^(?<f>[^ ]+): (?<verb>[A-Z*]+) (?<path>.*)$") // {f: "", verb: "", path: .}) as $rt
               | "  " + ((($rt.verb + " " + $rt.path) | ltrimstr(" ")) | pad($lw)) + evidence($rt.f)))
         end)

      + (($pr.env // []) | if length == 0 then [] else
           [""] + [$m + $b + "READS" + $r]
           + ["  " + $d + (join(", ") | clip($w - 4)) + $r]
         end)

      + (($notes | map(select(.repo == $name))) | if length == 0 then [] else
           [""] + [$ok + $b + "NOTES" + $r + $d + "  \(length)" + $r]
           + (.[0:3] | map("  " + (((.body | split("\n") | map(select(. != "")) | .[0]) // "")
                                   | clip($w - 22) | pad($w - 20))
                           + $d + .author + $r))
         end)
      | .[]' "$g"
}

# Any other node: what it is, and both directions of every edge that named it.
tui_node() {
  local id=$1 g="$DIR/map/graph.json" w
  w=$(style_cols)
  jq -r --arg id "$id" --argjson w "$w" --argjson c "$(tui_colors_json)" \
    --argjson i "$(tui_icons_json)" \
    --arg b "$S_B" --arg d "$S_FAINT" --arg m "$S_MUTED" --arg rule "$S_RULE" --arg r "$S_R" '
    def pad($n): (. + "                                                            ")[0:$n];
    def rule: $rule + ("─" * (if $w > 4 then $w - 2 else 20 end)) + $r;
    (if $w > 74 then 30 elif $w > 56 then 24 else 18 end) as $lw
    | (if $w - $lw - 4 > 12 then $w - $lw - 4 else 12 end) as $ew
    | def elide($n): if length > $n then ("…" + .[(length - $n + 1):]) else . end;
    def evidence($e): if ($e // "") == "" then "" else $d + ($e | elide($ew)) + $r end;
    . as $g
    | ($g.nodes[] | select(.id == $id)) as $n
    | (($c[$n.kind]) // $d) as $col
    | (($i[$n.kind]) // "·") as $ico
    | [$col + $ico + " " + $b + $n.name + $r + "  " + $m + $n.kind + $r]
      + (($n.meta // {}) | to_entries
         | map(select(.value != null and .value != "" and .value != []))
         | if length == 0 then [] else
             .[0:6] | map("  " + $m + (.key | pad(13)) + $r + $d
                          + (.value | if type == "array" then join(", ") else tostring end
                             | .[0:($w - 18)]) + $r)
           end)
      + [rule]
      + ([$g.edges[] | select(.from == $id)] | group_by(.kind)
         | map([$m + $b + (.[0].kind | ascii_upcase) + $r]
               + (map("  " + ((.to | sub("^[a-z-]+:"; "")) | pad($lw)) + evidence(.evidence))
                  | unique | .[0:10]) + [""]) | add // [])
      + ([$g.edges[] | select(.to == $id)]
         | if length == 0 then [] else
             [$m + $b + "REFERENCED BY" + $r]
             + (map("  " + ((.from | sub("^[a-z-]+:"; "")) | pad($lw)) + evidence(.evidence))
                | unique | .[0:12])
           end)
      | .[]' "$g"
}

tui_preview_note() {
  local f=$1
  [[ -f $f ]] || { printf '%sthe note is gone%s\n' "$S_MUTED" "$S_R"; return 0; }
  local id author date repo tags
  id=$(sed -n 's/^id:[[:space:]]*//p' "$f" | head -1)
  author=$(sed -n 's/^author:[[:space:]]*//p' "$f" | head -1)
  date=$(sed -n 's/^date:[[:space:]]*//p' "$f" | head -1)
  repo=$(sed -n 's/^repo:[[:space:]]*//p' "$f" | head -1)
  tags=$(sed -n 's/^tags:[[:space:]]*//p' "$f" | head -1)

  printf '%s%s✎ %s%s\n' "$S_OK" "$S_B" "${repo:-org-wide}" "$S_R"
  printf '  %s%s · %s%s\n' "$S_MUTED" "$author" "${date:0:10}" "$S_R"
  [[ -n $tags ]] && printf '  %s%s%s\n' "$S_FAINT" "$tags" "$S_R"
  style_rule "$(($(style_cols) - 2))"
  source "$ROOT/lib/notes.sh"
  notes_body "$f" | fold -s -w "$(($(style_cols) - 2))"
  echo
  printf '%s%s%s\n' "$S_FAINT" "$id" "$S_R"
}

tui_preview_recap() {
  local f=$1
  [[ -f $f ]] || { printf '%sthe recap is gone%s\n' "$S_MUTED" "$S_R"; return 0; }
  if command -v glow >/dev/null; then
    glow -s dark -w "$(($(style_cols) - 2))" "$f" 2>/dev/null && return 0
  fi
  # Enough markdown to read it: headings in the accent, bullets kept, the rest
  # wrapped to the pane.
  sed -E "s/^(#{1,6}) (.*)$/$(printf '%s%s' "$S_ACCENT" "$S_B")\2$(printf '%s' "$S_R")/" "$f" |
    fold -s -w "$(($(style_cols) - 2))"
}

# What the pane would show, and the one command that would put something in it.
tui_preview_empty() {
  case $(tui_tab_name) in
    notes) printf '%sNo notes yet.%s\n\n%sorgami note records what the map cannot derive —\nthe cause someone found at 2am, the reason the obvious fix\ndoes not work. Notes attach to the repo you are standing in,\nand reach the team through the docs repo.%s\n' \
      "$S_MUTED$S_B" "$S_R" "$S_FAINT" "$S_R" ;;
    recaps) printf '%sNo recaps yet.%s\n\n%sorgami report writes this week'"'"'s: jq counts every number,\nthe model writes the prose around them.%s\n' \
      "$S_MUTED$S_B" "$S_R" "$S_FAINT" "$S_R" ;;
    *) printf '%sNo map yet.%s\n\n%sorgami scan clones every repo in the org and reads what is\ncommitted — deploy tooling, servers, routes, and what calls what.%s\n' \
      "$S_MUTED$S_B" "$S_R" "$S_FAINT" "$S_R" ;;
  esac
}

tui_preview() {
  style_init
  local id=$1
  case $id in
    repo:*) tui_card "${id#repo:}" ;;
    note:*) tui_preview_note "${id#note:}" ;;
    recap:*) tui_preview_recap "${id#recap:}" ;;
    empty:*) tui_preview_empty ;;
    '') : ;;
    *) tui_node "$id" ;;
  esac
}

# ---------------------------------------------------------------- the app

# fzf grew borders, footers and transform bindings over several releases. The
# app degrades to a plain list rather than refusing to start on an older one.
tui_fzf_modern() {
  local v major minor
  v=$(fzf --version 2>/dev/null | awk '{print $1}')
  major=${v%%.*}
  minor=${v#*.}
  minor=${minor%%.*}
  [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] || return 1
  ((major > 0)) && return 0
  ((minor >= 60))
}

tui_open() {
  local url
  url=$(jq -r --arg i "$1" '.nodes[] | select(.id == $i) | .meta.url // empty' \
    "$DIR/map/graph.json" 2>/dev/null)
  [[ -n $url ]] || return 0
  if command -v xdg-open >/dev/null; then xdg-open "$url" >/dev/null 2>&1 &
  elif command -v open >/dev/null; then open "$url" >/dev/null 2>&1 &
  fi
  return 0
}

# ctrl-n from a repo row writes a note already attached to that repo.
tui_note() {
  local id=${1-}
  case $id in
    repo:*) "$ORGAMI_BIN" note --repo "${id#repo:}" ;;
    *) "$ORGAMI_BIN" note ;;
  esac
  return 0
}

cmd_view() {
  load_company
  need fzf
  local g="$DIR/map/graph.json"
  [[ -f $g ]] || die "no map yet — run: orgami scan"

  style_init
  export ORGAMI_COMPANY="$COMPANY"
  export ORGAMI_COLOR=1
  ORGAMI_TUI_STATE=$(mktemp "${TMPDIR:-/tmp}/orgami-tui-XXXXXX")
  export ORGAMI_TUI_STATE
  echo 0 >"$ORGAMI_TUI_STATE"
  trap 'rm -f "$ORGAMI_TUI_STATE"' RETURN

  local start=${1:-map} i
  for i in "${!TUI_TABS[@]}"; do
    [[ ${TUI_TABS[$i]} == "$start" ]] && echo "$i" >"$ORGAMI_TUI_STATE"
  done

  local b="\"$ORGAMI_BIN\""
  local args=(
    --ansi --delimiter='\t' --with-nth=2..
    --no-multi --cycle --info=inline-right --layout=reverse
    --pointer='▌' --marker='│'
    --prompt="$(tui_prompt)"
    --header="$(tui_header)" --header-first
    --preview="$b _tui preview {1}"
    --preview-window='right:52%:wrap'
    --bind="tab:execute-silent($b _tui cycle 1)+reload($b _tui rows)+transform-header($b _tui header)+transform-prompt($b _tui prompt)+first"
    --bind="btab:execute-silent($b _tui cycle -1)+reload($b _tui rows)+transform-header($b _tui header)+transform-prompt($b _tui prompt)+first"
    --bind="ctrl-r:reload($b _tui rows)+transform-header($b _tui header)"
    --bind="ctrl-o:execute-silent($b _tui open {1})"
    --bind="ctrl-n:execute($b _tui note {1})+reload($b _tui rows)"
    --bind='esc:abort'
    --color='fg:250,bg:-1,hl:39,fg+:255,bg+:236,hl+:81,gutter:-1'
    --color='info:240,prompt:39,pointer:39,marker:71,spinner:39'
    --color='header:244,border:238,label:245,query:255,preview-fg:250'
  )
  if tui_fzf_modern; then
    args+=(
      --footer="$(tui_footer)"
      --preview-border=left --footer-border=horizontal --header-border=bottom
      --input-border=none
    )
  fi

  local picked
  picked=$(tui_rows | fzf "${args[@]}" | cut -f1) || return 0
  [[ -n $picked && $picked != empty:* ]] || return 0

  # Whatever was under the cursor, printed into the scrollback so it can be
  # copied, piped or read after the app closes.
  ORGAMI_COLOR=1 tui_preview "$picked"
}

# Hidden: every fzf binding and the preview pane call back in here.
cmd__tui() {
  load_company
  style_init
  local action=${1:-rows}
  shift || true
  case $action in
    rows) tui_rows ;;
    header) tui_header ;;
    prompt) tui_prompt ;;
    footer) tui_footer ;;
    preview) tui_preview "${1-}" ;;
    open) tui_open "${1-}" ;;
    note) tui_note "${1-}" ;;
    cycle) tui_cycle "${1:-1}" ;;
    *) die "unknown _tui action: $action" ;;
  esac
}
