# Shared helpers: paths, config access, company selection.

ORGAMI_HOME="${ORGAMI_HOME:-$HOME/.orgami}"

die() {
  echo "orgami: $*" >&2
  exit 1
}

log() { echo "  $*" >&2; }

need() {
  command -v "$1" >/dev/null || die "$1 is not on PATH${2:+ ($2)}"
}

company_dir() { echo "$ORGAMI_HOME/$1"; }

current_company() {
  if [[ -n ${ORGAMI_COMPANY:-} ]]; then
    echo "$ORGAMI_COMPANY"
    return
  fi
  local root="$ORGAMI_HOME/config.json"
  [[ -f $root ]] || die "no company selected — run: orgami init <company> --org <github-org>"
  jq -re '.default' "$root" 2>/dev/null ||
    die "no default company — run: orgami use <company>"
}

# Sets COMPANY, DIR, ORG for the rest of a subcommand.
load_company() {
  COMPANY=$(current_company)
  DIR=$(company_dir "$COMPANY")
  [[ -f $DIR/config.json ]] || die "unknown company '$COMPANY' — orgami list"
  ORG=$(cfg org)
  mkdir -p "$DIR"/{cache/prs,cache/repos,cache/src,reports,map}
}

# cfg <jq-path> [default]
cfg() {
  local val
  val=$(jq -r --arg d "${2-}" ".$1 // \$d" "$DIR/config.json")
  echo "$val"
}

companies() {
  [[ -d $ORGAMI_HOME ]] || return 0
  find "$ORGAMI_HOME" -mindepth 2 -maxdepth 2 -name config.json -printf '%h\n' |
    xargs -r -n1 basename | sort
}

iso_week() { date -u +%G-W%V; }

# Monday 00:00 UTC of the week containing $1 weeks ago (0 = this week).
week_start() {
  date -u -d "monday - ${1:-0} week" +%Y-%m-%d
}

# Turns org/repo#123 into a GitHub link, backticked or bare. Runs over the
# model's output after the fact, so a URL is never invented — the reference has
# to already be there, and the link is derived from it mechanically.
linkify_prs() {
  sed -E \
    -e 's%`([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9][A-Za-z0-9_.-]*)#([0-9]+)`%[\1/\2#\3](https://github.com/\1/\2/pull/\3)%g' \
    -e 's%(^|[[:space:](])([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9][A-Za-z0-9_.-]*)#([0-9]+)%\1[\2/\3#\4](https://github.com/\2/\3/pull/\4)%g'
}
