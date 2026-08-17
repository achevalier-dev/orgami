# shellcheck shell=bash
# Shared helpers: paths, config access, company selection.

ORGAMI_HOME="${ORGAMI_HOME:-$HOME/.orgami}"

# --- portability -------------------------------------------------------------
# macOS ships a BSD userland. These are the places it differs from GNU in ways
# that matter here; everything else in orgami is plain POSIX.

if date -u -d @0 +%Y >/dev/null 2>&1; then
  ORGAMI_DATE=gnu
else
  ORGAMI_DATE=bsd
fi

# The absolute path of a file, following symlinks. BSD readlink has no -f.
orgami_realpath() {
  local p=$1 t
  while [[ -L $p ]]; do
    t=$(readlink "$p")
    if [[ $t == /* ]]; then p=$t; else p=$(dirname "$p")/$t; fi
  done
  (cd "$(dirname "$p")" >/dev/null 2>&1 && printf '%s/%s\n' "$PWD" "$(basename "$p")")
}

# date_shift <YYYY-MM-DD> <signed days>
date_shift() {
  if [[ $ORGAMI_DATE == gnu ]]; then
    date -u -d "$1 $2 days" +%Y-%m-%d
  else
    date -u -j -f %Y-%m-%d "$1" -v"$2"d +%Y-%m-%d
  fi
}

# date_fmt <YYYY-MM-DD> <strftime format>
date_fmt() {
  if [[ $ORGAMI_DATE == gnu ]]; then
    date -u -d "$1" +"$2"
  else
    date -u -j -f %Y-%m-%d "$1" +"$2"
  fi
}

# Directories containing a file, without GNU find's -printf.
find_dirs_containing() {
  local root=$1 name=$2 depth=${3:-5}
  find "$root" -maxdepth "$depth" -name "$name" -print 2>/dev/null |
    sed 's|/[^/]*$||'
}

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
# shellcheck disable=SC2034  # ORG is read by the other libs sourced alongside this one
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
  find "$ORGAMI_HOME" -mindepth 2 -maxdepth 2 -name config.json -print 2>/dev/null |
    sed 's|/config.json$||' | while read -r d; do basename "$d"; done | sort
}

iso_week() { date -u +%G-W%V; }

# Monday of the week containing $1 weeks ago (0 = this week). Computed from the
# day of week rather than "last monday", which means different things per date
# implementation and is wrong midweek.
week_start() {
  local weeks=${1:-0} dow back
  dow=$(date -u +%u)
  back=$((dow - 1 + weeks * 7))
  date_shift "$(date -u +%Y-%m-%d)" "-$back"
}

# Turns org/repo#123 into a GitHub link, backticked or bare. Runs over the
# model's output after the fact, so a URL is never invented — the reference has
# to already be there, and the link is derived from it mechanically.
linkify_prs() {
  sed -E \
    -e 's%`([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9][A-Za-z0-9_.-]*)#([0-9]+)`%[\1/\2#\3](https://github.com/\1/\2/pull/\3)%g' \
    -e 's%(^|[[:space:](])([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9][A-Za-z0-9_.-]*)#([0-9]+)%\1[\2/\3#\4](https://github.com/\2/\3/pull/\4)%g'
}

# A model call can die mid-response and hand back an error string. Anything
# stored as content has to look like what was asked for, or it is thrown away.
# $1 the text, $2 a grep -E pattern the text must contain somewhere.
model_output_ok() {
  local text=$1 shape=${2:-.}
  [[ -n ${text// /} ]] || return 1
  grep -qiE '^(API Error|Error:|Execution error|Credit balance|Overloaded)' <<<"$text" && return 1
  grep -qiE 'API Error: (Connection lost|Request timed out|Internal server error)' <<<"$text" && return 1
  grep -qE "$shape" <<<"$text" || return 1
  return 0
}
