# shellcheck shell=bash
# Notes nobody had to remember to write. A session ends, what was said is read
# back, and anything durable is drafted for review. Drafts never reach the team
# until a person keeps them.

AUTONOTE_DAILY_CAP=${ORGAMI_AUTONOTE_CAP:-5}

# The conversation, minus the noise: what was asked, and what was answered.
# Tool calls and their output are left out — they are already in git.
autonote_digest() {
  local transcript=$1
  jq -r '
    select(.type == "user" or .type == "assistant")
    | .message.content
    | if type == "string" then .
      else ([.[]? | select(.type == "text") | .text] | join("\n"))
      end' "$transcript" 2>/dev/null |
    grep -v '^$' |
    # Anything that looks like a credential never leaves this machine.
    sed -E 's/(sk|ghp|gho|ghs|ghu|xox[abps])-[A-Za-z0-9_-]{8,}/[redacted]/g;
            s/AKIA[0-9A-Z]{12,}/[redacted]/g;
            s/(Bearer|Authorization:)[[:space:]]+[A-Za-z0-9._-]{12,}/\1 [redacted]/g;
            s/([A-Z0-9_]*(PASSWORD|SECRET|TOKEN|APIKEY|API_KEY|PRIVATE_KEY)[A-Z0-9_]*)[=:][[:space:]]*\S+/\1=[redacted]/g;
            s|(mongodb\+srv\|postgres\|postgresql\|mysql\|redis)://[^[:space:]]+|\1://[redacted]|g' |
    tail -c 60000
}

# Cheap test for whether a session was substantive enough to be worth a model
# call: real work happened, or something went wrong.
autonote_worth_reading() {
  local transcript=$1
  [[ -f $transcript ]] || return 1
  [[ $(wc -l <"$transcript") -ge 40 ]] || return 1
  grep -qiE '"name":"(Edit|Write|Bash|NotebookEdit)"' "$transcript" || return 1
  return 0
}

autonote_cap_reached() {
  local stamp
  stamp="$DIR/cache/autonote-$(date -u +%Y-%m-%d).count"
  local n=0
  [[ -f $stamp ]] && n=$(<"$stamp")
  [[ $n -lt $AUTONOTE_DAILY_CAP ]] || return 0
  echo $((n + 1)) >"$stamp"
  return 1
}

# orgami note-auto <transcript> [<cwd>] — runs detached from the hook.
cmd_note_auto() {
  local transcript=${1:-} where=${2:-$PWD}
  [[ -f $transcript ]] || die "usage: orgami note-auto <transcript> [<dir>]"

  source "$ROOT/lib/card.sh"
  context_pick_company "$(card_repo_here "$where" 2>/dev/null || true)" 2>/dev/null || true
  load_company 2>/dev/null || return 0

  autonote_worth_reading "$transcript" || return 0
  autonote_cap_reached && return 0

  need claude
  local model
  model=$(cfg note_model claude-sonnet-5)

  local digest out
  digest=$(autonote_digest "$transcript")
  [[ ${#digest} -gt 400 ]] || return 0

  out=$( {
    cat "$ROOT/prompts/autonote.md"
    printf '\n\nTHE SESSION\n"""\n%s\n"""\n' "$digest"
  } | claude -p --model "$model" --output-format text 2>/dev/null || true)

  [[ $out == NONE* ]] && return 0
  model_output_ok "$out" '^NOTE:' || return 0

  local repo tag body
  repo=$(sed -n 's/^REPO:[[:space:]]*//p' <<<"$out" | head -1 | tr -d ' ')
  tag=$(sed -n 's/^TAG:[[:space:]]*//p' <<<"$out" | head -1 | tr -d ' ')
  body=$(sed -n '/^NOTE:/,$p' <<<"$out" | tail -n +2 | sed '/^```$/d' | sed '/^$/d')

  [[ -n ${body// /} ]] || return 0

  # The same screen that guards anything published by hand. A drafted note that
  # cannot pass it is thrown away rather than left for someone to find.
  notes_screen "$body" "$COMPANY" >/dev/null 2>&1 || return 0
  [[ $repo == "-" ]] && repo=""
  # A repository the map has never heard of is a hallucinated one.
  if [[ -n $repo ]] && ! jq -e --arg r "$repo" 'any(.[]; .name == $r)' \
    "$DIR/map/repos.json" >/dev/null 2>&1; then
    repo=""
  fi
  case $tag in
    gotcha | incident | setup | deploy | rollback | alert) ;;
    *) tag=gotcha ;;
  esac

  source "$ROOT/lib/notes.sh"

  # notes_autopublish sends what was drafted straight to the team. Off by
  # default: a note carries the user's name, so publishing one unattended is
  # their call to make, not the tool's.
  local publish=0 dest="$DIR/notes/draft"
  if [[ $(cfg notes_autopublish false) == true ]]; then
    publish=1
    dest="$DIR/notes"
  fi
  mkdir -p "$dest"

  local author stamp id file
  author=$(notes_author)
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  id="$(date -u +%Y%m%d-%H%M%S)-$author-$(notes_slug "$(head -1 <<<"$body")")"
  file="$dest/$id.md"

  {
    echo "---"
    echo "id: $id"
    echo "author: $author"
    echo "date: $stamp"
    [[ -n $repo ]] && echo "repo: $repo"
    echo "tags: [$tag]"
    echo "auto: true"
    echo "---"
    echo
    echo "$body"
  } >"$file"

  echo "$file"

  # Straight out to the docs repo — as a pull request when the company asks for
  # review, as a push when it does not.
  [[ $publish == 1 ]] || return 0
  cmd_sync --quiet >/dev/null 2>&1 || true
}

autonote_pending() {
  [[ -d $DIR/notes/draft ]] || return 1
  compgen -G "$DIR/notes/draft/*.md" >/dev/null 2>&1
}

# orgami drafts — keep or discard what was drafted while you worked.
cmd_drafts() {
  load_company

  if [[ ${1:-} == --count ]]; then
    local n=0
    autonote_pending && n=$(find "$DIR/notes/draft" -name '*.md' | wc -l)
    echo "$n"
    return 0
  fi

  autonote_pending || {
    echo "nothing waiting"
    return 0
  }

  local f n=0 kept=0 dropped=0
  for f in "$DIR/notes/draft"/*.md; do
    [[ -f $f ]] || continue
    n=$((n + 1))
    echo
    if command -v gum >/dev/null; then
      gum style --foreground 4 --bold "$(sed -n 's/^repo: //p' "$f" | head -1) · $(sed -n 's/^tags: //p' "$f" | head -1)"
    else
      echo "--- $(basename "$f") ---"
    fi
    sed -n '/^---$/,/^---$/!p' "$f" | sed '/^$/d'
    echo

    local choice
    if command -v gum >/dev/null; then
      choice=$(gum choose --header "" "keep it" "throw it away" "leave it for later" "stop here") || choice="stop here"
    else
      read -rp "keep / drop / skip / stop? " choice
    fi

    case $choice in
      keep*) mv "$f" "$DIR/notes/$(basename "$f")" && kept=$((kept + 1)) ;;
      throw* | drop*) rm -f "$f" && dropped=$((dropped + 1)) ;;
      stop*) break ;;
      *) : ;;
    esac
  done

  echo
  echo "$kept kept, $dropped discarded"
  [[ $kept -gt 0 ]] &&
    echo "they land in the runbooks at the next 'orgami doc', and reach the team at the next 'orgami sync'"
  return 0
}

# orgami autonote [on|off|publish|drafts] — how much of this happens by itself.
cmd_autonote() {
  load_company
  local want=${1:-}
  local tmp

  case $want in
    "")
      local on="on" mode="drafts for review"
      [[ ${ORGAMI_AUTONOTE:-1} == 0 ]] && on="off (ORGAMI_AUTONOTE=0)"
      [[ $(cfg notes_autopublish false) == true ]] && mode="published straight to the team"
      echo "$COMPANY: $on, $mode"
      return 0
      ;;
    publish)
      tmp=$(mktemp)
      jq '.notes_autopublish = true' "$DIR/config.json" >"$tmp" && mv "$tmp" "$DIR/config.json"
      echo "notes written at the end of a session now go to the team without review."
      [[ $(cfg notes_review false) == true ]] &&
        echo "They open as pull requests, because notes_review is on." ||
        echo "They are pushed directly. Turn on notes_review to have them open as pull requests instead."
      ;;
    drafts | review)
      tmp=$(mktemp)
      jq '.notes_autopublish = false' "$DIR/config.json" >"$tmp" && mv "$tmp" "$DIR/config.json"
      echo "notes now wait in 'orgami drafts' until you keep them."
      ;;
    on)
      echo "on by default — nothing to do. ORGAMI_AUTONOTE=0 in the environment turns it off."
      ;;
    off)
      echo "set ORGAMI_AUTONOTE=0 in your shell profile to stop reading sessions back."
      ;;
    *) die "usage: orgami autonote [publish|drafts|off]" ;;
  esac
}
