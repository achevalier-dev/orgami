# shellcheck shell=bash
# orgami depth — the symbol layer, parsed rather than pattern-matched.
#
# `orgami scan` reads what a repository declares about itself and stops at the
# door: manifests, deploy configuration, the URLs it writes down. That is the
# right altitude for an organization map, it costs nothing but grep, and it is
# what makes the map the same for everyone. It also cannot tell you which repo
# defines `chargeCustomer`, and the only way it can find an import is to grep
# for a name — which matches a comment, a changelog and a variable just as
# happily as an import statement.
#
# This pass parses. tree-sitter gives a definition node and an import node and
# the line the parser landed on, which is better evidence than the scan can
# produce, not worse. So what it contributes to the graph is `extracted`.
#
# It is a separate command for the same reason `orgami live` is: it needs
# something orgami otherwise does not — Python and a set of compiled grammars.
# Those go into their own virtualenv under ~/.orgami, nothing else in orgami
# looks at them, and every other command works exactly as well without it.

DEPTH_PACKAGES=(tree-sitter tree-sitter-language-pack)

depth_venv() { echo "$ORGAMI_HOME/.venv/depth"; }

depth_python() {
  local venv
  venv=$(depth_venv)
  echo "$venv/bin/python"
}

# True when an interpreter can already parse. Checked rather than assumed:
# somebody may have the grammars in their own environment, and reinstalling
# them into a private venv to find that out is rude.
depth_ready() {
  local py=$1
  [[ -x $py ]] || return 1
  "$py" -c 'import tree_sitter_language_pack' >/dev/null 2>&1
}

# Builds the virtualenv. Says what it is doing and where, because it is the one
# thing orgami installs that is not on the promise on the front page.
depth_setup() {
  local venv py
  venv=$(depth_venv)
  py=$(depth_python)

  need python3
  log "installing the tree-sitter grammars into $venv"
  log "(nothing else in orgami uses them; delete that directory to undo it)"

  mkdir -p "$(dirname "$venv")"
  python3 -m venv "$venv" >/dev/null 2>&1 ||
    die "could not create a virtualenv at $venv — install python3-venv and try again"

  "$venv/bin/pip" install --quiet --disable-pip-version-check "${DEPTH_PACKAGES[@]}" ||
    die "could not install ${DEPTH_PACKAGES[*]} — install them yourself and pass --python <interpreter>"

  depth_ready "$py" || die "the grammars installed but will not import — try: rm -rf $venv && orgami depth --setup"
  log "ready"
}

# --- reading it back ----------------------------------------------------------

depth_file() { echo "$DIR/map/depth.json"; }

# One line for a repo card and for the session-start injection: how much of this
# repo has been parsed, and how much of it is surface.
depth_brief() {
  local repo=$1 f
  f=$(depth_file)
  [[ -f $f ]] || return 0
  jq -re --arg r "$repo" '.repos[] | select(.name == $r)
    | select(.parsed > 0)
    | "parsed: \(.parsed) files, \(.symbol_count) definitions, "
      + "\(.exported_count) exported, \(.external_modules) external packages"' \
    "$f" 2>/dev/null || return 0
}

# The "Public surface" block on a repo page. What another repository could
# actually reach for, with the file:line the parser reported.
depth_section() {
  local repo=$1 f rows
  f=$(depth_file)
  [[ -f $f ]] || return 0
  jq -e --arg r "$repo" '.repos[] | select(.name == $r and .exported_count > 0)' \
    "$f" >/dev/null 2>&1 || return 0

  echo "## Public surface"
  echo
  jq -r --arg r "$repo" '.repos[] | select(.name == $r)
    | "\(.exported_count) exported definitions across \(.parsed) parsed files"
      + " (" + ([.languages | to_entries[] | "\(.key) \(.value)"] | join(", ")) + ")."
      + (if .symbols_truncated then " The first of them are listed; the count is exact." else "" end)' "$f"
  echo

  rows=$(jq -r --arg r "$repo" '[.repos[] | select(.name == $r) | .symbols[]
      | select(.exported)] | .[0:25][]
    | "| `" + .name + "` | " + .kind + " | `" + .file + ":" + (.line | tostring) + "` |"' "$f")
  if [[ -n $rows ]]; then
    echo "| Name | Kind | Defined at |"
    echo "|---|---|---|"
    echo "$rows"
    echo
  fi

  local pkgs
  pkgs=$(jq -r --arg r "$repo" '[.repos[] | select(.name == $r) | .imports[]
      | select(.n > 1)] | .[0:14] | map("`" + .module + "`") | join(", ")' "$f")
  [[ -n $pkgs && $pkgs != "null" && $pkgs != "" ]] && {
    echo "**Imports most:** $pkgs"
    echo
  }

  echo "Parsed with tree-sitter by \`orgami depth\` — every line here is the one the"
  echo "parser reported, not a pattern match."
  echo
  return 0
}

# --- the graph ----------------------------------------------------------------

# Cross-repo edges the scan could not see, or could only guess at.
#
# An import statement is extracted — it sat at that line in that file and the
# parser says so. Whether the module it names *is* a sibling repository is a
# second question, and the honest answer differs by case: a specifier carrying
# the organization (`github.com/org/repo`, `@org/repo`) resolves to exactly one
# repository and nothing else, so the edge is extracted. A bare name that
# happens to equal a repository name resolves by resemblance — real
# organizations have a `services/tracking/trackhome.js` importing `trackhome`
# and meaning the file next door — so that edge is inferred, and says so.
depth_merge_graph() {
  local graph="$DIR/map/graph.json" f tmp
  f=$(depth_file)
  [[ -f $graph && -f $f ]] || return 0

  tmp=$(mktemp)
  jq -s --arg org "$ORG" '
    .[0] as $g | .[1] as $d
    | ($org | ascii_downcase) as $o
    | ([$g.nodes[] | select(.kind == "repo") | .name]) as $repos
    | ([$repos[] | select(length >= 4)]) as $named

    | [ $d.repos[] | .name as $r | .imports[]
        | select(.module | type == "string")
        # `../shared` ends in the name of a repository and means the directory
        # next door. A path is never a cross-repo reference.
        | select(.module | test("^[./]") | not)
        | { r: $r, raw: .module, m: (.module | ascii_downcase),
            ev: (.file + ":" + (.line | tostring)) } ] as $rows

    # `github.com/org/repo`, `@org/repo`, `ghcr.io/org/repo` — the specifier
    # carries the organization, so it resolves to one repository and nothing
    # else. Extracted: the line is real and so is the resolution.
    | ([ $rows[] as $x
         | $repos[] as $p
         | select($x.m | test("(^|[/@])" + ($o | gsub("[^a-z0-9]"; "."))
                              + "/" + (($p | ascii_downcase) | gsub("[^a-z0-9]"; ".")) + "($|/)"))
         | select($p != $x.r)
         | {from: ("repo:" + $x.r), to: ("repo:" + $p), kind: "imports",
            evidence: ($x.ev + " — " + $x.raw), confidence: "extracted"} ]) as $exact

    # A bare specifier that happens to equal a repository name. The import is
    # real; that it means *that repo* is a guess, and a wrong one often enough
    # to matter. Inferred, and the evidence says what was matched.
    | ([ $rows[] as $x
         | $named[] as $p
         | ($p | ascii_downcase) as $pl
         | select($x.m == $pl or ($x.m | endswith("/" + $pl)))
         | select($p != $x.r)
         | {from: ("repo:" + $x.r), to: ("repo:" + $p), kind: "imports",
            evidence: ($x.ev + " — imports \"" + $x.raw + "\", which is also a repo name"),
            confidence: "inferred"} ]) as $byname

    | ($exact | map({key: (.from + "|" + .to), value: true}) | from_entries) as $have
    | $g
    | .edges = ((.edges
                 + $exact
                 + [$byname[] | select($have[(.from + "|" + .to)] | not)])
                | unique)' "$graph" "$f" >"$tmp" || { rm -f "$tmp"; return 0; }

  mv "$tmp" "$graph"
}

# --- looking one up -----------------------------------------------------------

# Which repository defines a name, and where. The question `orgami scan` could
# never answer, and the first thing anybody asks of an unfamiliar organization.
depth_symbol() {
  local want=$1 f hits
  f=$(depth_file)
  [[ -f $f ]] || die "nothing parsed yet — run: orgami depth"

  hits=$(jq -r --arg q "$want" '
    ($q | ascii_downcase) as $l
    | [ .repos[] | .name as $r | .symbols[]
        | select((.name | ascii_downcase) == $l
                 or ((.name | ascii_downcase) | contains($l)))
        | {r: $r, name, kind, file, line, exported} ]
    | sort_by((.name | ascii_downcase) != $l, .r, .file)
    | .[0:40][]
    | "  \(.r)  \(.name)  [\(.kind)\(if .exported then "" else ", internal" end)]  \(.file):\(.line)"' \
    "$f")

  [[ -n $hits ]] || {
    echo "nothing exported under that name in $(jq -r '.totals.exported' "$f") definitions" >&2
    echo "(only exported definitions are indexed — orgami depth --stats)" >&2
    return 1
  }
  echo "$hits"
}

depth_stats() {
  local f
  f=$(depth_file)
  [[ -f $f ]] || die "nothing parsed yet — run: orgami depth"
  jq -r '
    "parsed \(.generated[0:10]) with \(.parser) in \(.seconds)s",
    "",
    "  \(.totals.repos) repos · \(.totals.files_parsed) files · \(.totals.symbols) definitions"
    + " · \(.totals.exported) exported · \(.totals.external_modules) external packages",
    "",
    (.repos[] | select(.parsed > 0)
     | "  \(.name)"
       + (" " * (if (28 - (.name | length)) > 1 then (28 - (.name | length)) else 1 end))
       + "\(.parsed) files  \(.exported_count)/\(.symbol_count) exported"),
    "",
    (if (.unparsed_extensions | length) > 0
     then "not parsed (no grammar): "
          + ([.unparsed_extensions | to_entries[] | "\(.key) ×\(.value)"] | join(", "))
     else empty end)' "$f"
}

# --- the command --------------------------------------------------------------

cmd_depth() {
  load_company

  local only="" jobs=4 py="" setup=0 symbol="" stats=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --only) only=$2; shift 2 ;;
      --jobs | -j) jobs=$2; shift 2 ;;
      --python) py=$2; shift 2 ;;
      --setup) setup=1; shift ;;
      --symbol) symbol=$2; shift 2 ;;
      --stats) stats=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  [[ $stats == 1 ]] && { depth_stats; return 0; }
  [[ -n $symbol ]] && { depth_symbol "$symbol"; return $?; }

  [[ -n $py ]] || py=$(depth_python)
  if [[ $setup == 1 ]]; then
    depth_setup
    py=$(depth_python)
  elif ! depth_ready "$py"; then
    depth_setup
    py=$(depth_python)
  fi

  local src="$DIR/cache/src"
  [[ -d $src ]] || die "no checkouts to parse — run: orgami scan"

  local out="$DIR/map/depth.json"
  local args=(--src "$src" --out "$out" --jobs "$jobs")
  [[ -n $only ]] && args+=(--only "$only")
  "$py" "$ROOT/lib/depth.py" "${args[@]}" || die "the parse failed"

  depth_merge_graph

  local added
  added=$(jq '[.edges[] | select(.kind == "imports")] | length' "$DIR/map/graph.json" 2>/dev/null || echo 0)
  jq -r '"'"$out"'  (\(.totals.files_parsed) files, \(.totals.symbols) definitions, "
         + "\(.totals.exported) exported, \(.seconds)s)"' "$out"
  echo "  $added import edges in the graph"
}
