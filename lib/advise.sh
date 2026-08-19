# shellcheck shell=bash
# orgami advise — where the map says money is being spent twice.
#
# Read-only, and offline in the strongest sense: it never talks to a provider,
# never reads a credential, and has never seen an invoice. Everything it says is
# already in the local cache — the vendor nodes in map/graph.json, the `uses`
# edges that carry the file:line each vendor was matched on, the last push date
# the repo listing records, and the DNS reading in map/dns.json if somebody has
# taken one. So it cannot tell anyone what a subscription costs. It can tell
# them where two vendors are doing the same job, where one is wired into a
# single repository, where a vendor is wired into code nobody has touched in
# half a year, and where public DNS proves an account no repository accounts for.
#
# The two evidence sources are unioned rather than merged. Code names what the
# organization *calls*; DNS names what it has an *account* with, and at the top
# of a bill those are almost disjoint sets. Every row keeps a `code` or `dns`
# tag through to the rendered table, because a proposal resting only on a DNS
# record is a different kind of claim from one resting on a file:line.
#
# The half that makes it worth running twice is the suppression loop. A proposal
# a human answers "no, deliberately" to must never come back, or this is a
# linter that cries wolf every Monday until the report goes unread. Rejecting one
# writes an ordinary note — the id in a marker, the human's reason as the body —
# and the reason is the valuable half: it lands in the team memory every agent
# reads at session start, next to the repo it concerns. The report shrinks over
# time, and that shrinking is the signal it is working.
#
# Every number in the rendered report is computed by lib/advise.jq. Nothing here
# is written by a model.

ADVISE_STALE_DAYS=180

# The marker that carries a machine-readable proposal id inside a human note.
# Same shape as the `<!-- orgami review: -->` marker the review flow already
# writes, for the same reason: notes are markdown, and a comment is the only
# thing that can ride along without showing up on the rendered page.
ADVISE_MARK_RE='<!-- orgami advise: suppressed ([^ >]+) -->'

advise_mark() { printf '<!-- orgami advise: suppressed %s -->' "$1"; }

# --- the step-1 vendor catalogue, behind one accessor --------------------------
#
# lib/vendors.tsv is written by the scanner side of this feature. If it is not
# there yet, or its columns move, this is the one place that has to change: the
# graph is the real input, and the catalogue only fills in a display name and a
# category for a vendor whose node did not carry them.
advise_catalog() {
  local f="$ROOT/lib/vendors.tsv"
  [[ -f $f ]] || { echo '[]'; return 0; }
  jq -Rs 'split("\n")
          | map(select((length > 0) and (startswith("#") | not)))
          | map(split("\t"))
          | map(select(length >= 3))
          | map({id: .[0], name: (.[1] // .[0]), category: (.[2] // ""),
                 signals: (.[3] // ""), portal: (.[4] // "")})
          | map(select(.id != "id" and .id != ""))' "$f"
}

# --- suppression, read out of the notes the team already keeps -----------------
#
# Not a parallel store. A rejection is a note like any other: it syncs to the
# docs repo, it is screened for credentials, it shows up in the repo's page, and
# a teammate who disagrees can supersede it with `orgami note --supersede`.
advise_suppressions() {
  compgen -G "$DIR/notes/*.md" >/dev/null 2>&1 || { echo '[]'; return 0; }
  notes_index 2>/dev/null | jq -c --arg re "$ADVISE_MARK_RE" '
    [.[] | . as $n
     | (.body | [scan($re)] | flatten)[]?
     | {id: .,
        reason: ($n.body | gsub("<!-- orgami advise:[^>]*-->"; "")
                 | gsub("^\\s+"; "") | gsub("\\s+$"; "") | gsub("\\s*\\n\\s*"; " ")),
        author: $n.author,
        date: ($n.date[0:10]),
        note: $n.id}]
    | group_by(.id) | map(sort_by(.date) | last)' 2>/dev/null || echo '[]'
}

# --- the artifact --------------------------------------------------------------

# Two inputs, not one. map/graph.json is what the code names; map/dns.json is
# what the organization's public DNS says it has an account with. A vendor in
# both is one vendor with two independent pieces of evidence, and a vendor in
# only the second is the whole reason `orgami dns` exists — no repository was
# ever going to name Google Workspace. /dev/null stands in for a reading nobody
# has taken, which is the state every organization starts in.
advise_compute() {
  local out=$1 stale=$2
  local g="$DIR/map/graph.json" p="$DIR/map/repos.json" d="$DIR/map/dns.json"
  [[ -f $p ]] || p=/dev/null
  [[ -f $d ]] || d=/dev/null
  local tmp
  tmp=$(mktemp)
  jq -f "$ROOT/lib/advise.jq" \
    --slurpfile profiles "$p" \
    --slurpfile dns "$d" \
    --argjson cat "$(advise_catalog)" \
    --argjson sup "$(advise_suppressions)" \
    --argjson now "$(date -u +%s)" \
    --argjson stale "$stale" \
    --argjson dns_stale "${DNS_STALE_DAYS:-90}" \
    --arg company "$COMPANY" \
    --arg org "$ORG" \
    "$g" >"$tmp" || { rm -f "$tmp"; die "could not read $g — run: orgami scan"; }
  mv "$tmp" "$out"
}

# --- the report ----------------------------------------------------------------
#
# One ranked list, not one section per kind: the question a reader has is "what
# should I look at first", and confidence-then-blast-radius is the only ordering
# this step can honestly offer. Money would order it better; there is none here.
advise_render() {
  local a=$1 show_all=$2

  {
    echo "# $COMPANY — vendor advisories"
    echo

    jq -r '
      "Read out of the map of \(.scanned // "an earlier scan"): \(.counts.vendors) vendor"
      + (if .counts.vendors == 1 then "" else "s" end)
      + " across \(.counts.repos) repositor"
      + (if .counts.repos == 1 then "y" else "ies" end) + "."' "$a"
    echo

    # Whether a DNS reading exists changes what an absence means, so it is said
    # before anything is claimed rather than left for the reader to infer.
    jq -r '
      if .dns == null then
        "No DNS reading has been taken. `orgami dns` reads the public DNS"
        + " of this organization and finds the vendors code cannot see — the workspace suite,"
        + " the applicant tracker, the e-signature seats. Without one, everything"
        + " below knows only what the code names."
      else
        "\(.counts.vendors_from_code) of them was found in committed code,"
        + " \(.counts.vendors_from_dns) in public DNS"
        + (if .counts.vendors_from_both > 0
           then ", and \(.counts.vendors_from_both) in both" else "" end)
        + ". The DNS reading covers \(.dns.domains | join(", "))"
        + (if .dns.age_days == null then ""
           else " and is \(.dns.age_days) day" + (if .dns.age_days == 1 then "" else "s" end) + " old"
           end)
        + "."
        + (if .dns.stale
           then " That is past \(.dns.stale_days) days — re-run `orgami dns` before acting on it."
           else "" end)
      end' "$a"
    echo
    cat <<'EOF'
This has seen no invoice, no contract and no seat count, so it cannot say what
anything costs. It can say where the map has two vendors doing the same job,
where one is wired into a single repository, where a subscription is implied by
code nobody has pushed to in a long time, and where public DNS shows an account
no repository accounts for. Every count below is computed from `map/graph.json`
and `map/dns.json`; every claim carries the `file:line` or the DNS record it was
matched on, and the table says which. A vendor that does not appear here was
**not found in committed configuration** and not found in public DNS, which is
not the same fact as not being in use.
EOF
    echo

    if [[ $(jq -r '.counts.vendors' "$a") == 0 ]]; then
      echo "The map has no vendor nodes. Either nothing this organization commits"
      echo "matches the vendor catalogue, or the map predates it — \`orgami scan\`"
      echo "rebuilds it."
      echo
    elif [[ $(jq -r '.counts.proposals' "$a") == 0 ]]; then
      jq -r '"Nothing to propose. No two vendors share a category, none is wired into a"
             + " single repository, none belongs to a repository quiet for more than"
             + " \(.stale_days) days, none is matched by an environment variable alone,"
             + " and public DNS shows no account the code does not already account for."' "$a"
      echo
    else
      jq -r '
        "\(.counts.proposals) proposal"
        + (if .counts.proposals == 1 then "" else "s" end)
        + " — \(.counts.high) high confidence, \(.counts.medium) medium."' "$a"
      echo
      jq -r '
        (.vendors | map({key: .id, value: .name}) | from_entries) as $name
        | [.proposals[]
           | "### \(.rank). \(.claim)",
             "",
             "`\(.id)` · **\(.confidence)** confidence · "
               + (if .repo_count > 0
                  then "\(.repo_count) repositor" + (if .repo_count == 1 then "y" else "ies" end)
                  else ((.domains // []) | length) as $d
                       | "\($d) domain" + (if $d == 1 then "" else "s" end)
                  end)
               + (if ((.sources // []) | length) > 1
                  then " · the code and the DNS agree" else "" end),
             "",
             "| Vendor | Source | Where | Found in |",
             "|---|---|---|---|",
             ((.evidence
               | map(. + {where: (if .source == "dns" then (.domain // "") else (.repo // "") end)})
               | group_by(.vendor + " " + (.source // "code") + " " + .where)
               | sort_by(.[0].vendor, (.[0].source // "code"), .[0].where))[]
              | .[0].vendor as $v | (.[0].source // "code") as $s | .[0].where as $w
              | ([.[] | select(.at != "")
                  | if $s == "dns" then "`\(.at)`" else "`\($w)/\(.at)`" end]
                 | unique) as $paths
              | "| \($name[$v] // $v) | \($s) | \($w) | "
                + (if ($paths | length) == 0 then "_no path recorded on the edge_"
                   else ($paths[0:6] | join(", "))
                        + (if ($paths | length) > 6
                           then " +\(($paths | length) - 6) more" else "" end)
                   end)
                + " |"),
             "",
             "<sub>Deliberate? `orgami advise --reject \(.id) \"why\"` — the reason goes"
               + " into the team notes and the proposal does not come back.</sub>",
             ""]
        | .[]' "$a"
    fi

    local hidden
    hidden=$(jq -r '.counts.suppressed' "$a")
    if [[ ${hidden:-0} -gt 0 ]]; then
      if [[ $show_all == 1 ]]; then
        echo "## Suppressed"
        echo
        echo "Answered already. Kept here so the answer is not lost with the proposal."
        echo
        jq -r '.suppressed[]
               | "- `\(.id)` — \(.suppression.reason)\n  <sub>\(.suppression.author), \(.suppression.date)</sub>"' "$a"
        echo
      else
        echo "<sub>$hidden proposal(s) the team has already answered are not shown —"
        echo "\`orgami advise --all\` for those and the reasons given.</sub>"
        echo
      fi
    fi
  }
}

# --- rejecting -----------------------------------------------------------------

advise_reject() {
  local a=$1 id=$2 reason=$3

  jq -e --arg i "$id" '[(.proposals + .suppressed)[] | select(.id == $i)] | length > 0' \
    "$a" >/dev/null ||
    die "no proposal with id '$id' — run: orgami advise --all to see the ids"

  # A rejection that concerns one repository is filed against it, so the reason
  # reaches that repo's page and runbook rather than only the org-wide list.
  local repo args=()
  repo=$(jq -r --arg i "$id" '
    [(.proposals + .suppressed)[] | select(.id == $i)][0]
    | if (.repos | length) == 1 then .repos[0] else "" end' "$a")
  [[ -n $repo ]] && args=(--repo "$repo")

  cmd_note "${args[@]}" --tag advise-suppressed -- \
    "$reason

$(advise_mark "$id")"
}

cmd_advise() {
  load_company

  local show_all=0 as_json=0 reject="" reason="" stale=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --all | -a) show_all=1; shift ;;
      --json) as_json=1; shift ;;
      --stale-days) stale=$2; shift 2 ;;
      --reject) reject=$2; shift 2 ;;
      --) shift; reason="$*"; break ;;
      -*) die "unknown flag: $1" ;;
      *) reason="$*"; break ;;
    esac
  done

  [[ -f $DIR/map/graph.json ]] || die "no map yet — run: orgami scan"
  [[ -n $stale ]] || stale=$(cfg advise_stale_days "$ADVISE_STALE_DAYS")
  [[ $stale =~ ^[0-9]+$ ]] || die "--stale-days takes a number of days, not '$stale'"

  local artifact="$DIR/map/advise.json"
  advise_compute "$artifact" "$stale"

  # ADVISE.md sits beside ARCHITECTURE.md and RUNBOOK.md, the other pages
  # rendered out of the map. `orgami publish` copies a fixed list of filenames
  # and does not know about this one yet — until it does, the page is local.
  local page="$DIR/map/ADVISE.md"

  # A rejection's result is the note it wrote, and nothing else: whoever runs it
  # wants the file they can go and edit, not a report they just asked to shrink.
  if [[ -n $reject ]]; then
    [[ -n ${reason// /} ]] ||
      die "say why — orgami advise --reject $reject \"the reason\".
     The reason is the half worth keeping: it goes into the team's notes."
    advise_reject "$artifact" "$reject" "$reason"
    log "suppressed $reject"
    advise_compute "$artifact" "$stale"
    advise_render "$artifact" "$show_all" >"$page"
    return 0
  fi

  advise_render "$artifact" "$show_all" >"$page"

  if [[ $as_json == 1 ]]; then
    cat "$artifact"
    return 0
  fi

  log "$artifact"
  log "$page"
  cat "$page"
}
