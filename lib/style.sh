# shellcheck shell=bash
# One palette for everything orgami prints. Restrained 256-colour: structure in
# grey, one blue accent, and evidence dimmed so a claim reads louder than its
# citation.
#
# Colour is on when stdout is a terminal, off when it is a pipe, and forced by
# ORGAMI_COLOR=1 — which is how the fzf preview pane, whose stdout is a pipe,
# still gets colour. NO_COLOR wins over all of it.

# shellcheck disable=SC2034  # the S_* palette is read by every other lib
style_init() {
  local on=0
  if [[ -n ${NO_COLOR-} ]]; then
    on=0
  elif [[ ${ORGAMI_COLOR-} == 1 ]]; then
    on=1
  elif [[ -t 1 ]]; then
    on=1
  fi

  if [[ $on == 0 ]]; then
    S_R='' S_B='' S_D='' S_ACCENT='' S_MUTED='' S_FAINT=''
    S_RULE='' S_OK='' S_WARN='' S_ERR='' S_SEL=''
    return 0
  fi

  S_R=$'\033[0m'
  S_B=$'\033[1m'
  S_D=$'\033[2m'
  S_ACCENT=$'\033[38;5;39m'
  S_MUTED=$'\033[38;5;244m'
  S_FAINT=$'\033[38;5;240m'
  S_RULE=$'\033[38;5;238m'
  S_OK=$'\033[38;5;71m'
  S_WARN=$'\033[38;5;179m'
  S_ERR=$'\033[38;5;167m'
  S_SEL=$'\033[38;5;255m'
}

# The kinds in the graph each get one colour, used everywhere they appear so a
# host reads as a host in the list, in the card and in the query output.
style_kind_color() {
  case $1 in
    repo) printf '%s' $'\033[38;5;39m' ;;
    host) printf '%s' $'\033[38;5;173m' ;;
    tool) printf '%s' $'\033[38;5;108m' ;;
    service) printf '%s' $'\033[38;5;140m' ;;
    vendor) printf '%s' $'\033[38;5;168m' ;;
    lang) printf '%s' $'\033[38;5;244m' ;;
    *) printf '%s' $'\033[38;5;244m' ;;
  esac
}

style_kind_icon() {
  case $1 in
    repo) printf '%s' '▪' ;;
    host) printf '%s' '◆' ;;
    tool) printf '%s' '◈' ;;
    service) printf '%s' '▣' ;;
    vendor) printf '%s' '◉' ;;
    lang) printf '%s' '·' ;;
    note) printf '%s' '✎' ;;
    recap) printf '%s' '▤' ;;
    *) printf '%s' '·' ;;
  esac
}

style_cols() {
  local c=${FZF_PREVIEW_COLUMNS:-${FZF_COLUMNS:-${COLUMNS:-0}}}
  [[ $c -gt 0 ]] || c=$(tput cols 2>/dev/null || echo 80)
  echo "$c"
}

style_rule() {
  local w=${1:-$(style_cols)} i out=''
  ((w > 0)) || return 0
  for ((i = 0; i < w; i++)); do out+='─'; done
  printf '%s%s%s\n' "$S_RULE" "$out" "$S_R"
}

# A heading the eye can find without shouting: uppercase, muted, spaced.
style_section() { printf '%s%s%s\n' "$S_MUTED$S_B" "$1" "$S_R"; }

# Visible width of a string, ANSI escapes discounted. Bash pattern removal
# cannot express "shortest match", so the escapes come off one at a time.
style_width() {
  local s=$1 esc
  while [[ $s =~ $'\033'\[[0-9\;]*m ]]; do
    esc=${BASH_REMATCH[0]}
    s=${s//"$esc"/}
  done
  printf '%s' "${#s}"
}
