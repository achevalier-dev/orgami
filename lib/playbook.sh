# shellcheck shell=bash
# The half of a team's memory a note cannot hold: the procedure. A note records
# one thing that is true. A playbook records how a kind of work is done here —
# the shape the failure takes, the steps that worked the last three times, and
# the traps between them. It is what makes the fourth fetcher cheaper than the
# first.
#
# Playbooks are the one derived file a model writes. Runbooks are quoted and
# computed and say so; a procedure cannot be computed, only read out of what the
# repeated instances had in common. So everything the model was handed is
# printed underneath what it wrote, and a claim can always be walked back to the
# note or the pull request it came from.

PLAYBOOK_MIN_INSTANCES=${ORGAMI_PLAYBOOK_MIN:-2}

playbook_dir() { echo "$DIR/map/playbooks"; }
playbook_file() { echo "$(playbook_dir)/$1--$2.md"; }

# Words worth searching pull requests for. One- and two-letter fragments and the
# handful of words every repository uses match everything, which is the same as
# matching nothing.
playbook_keywords() {
  tr '-' '\n' <<<"$1" |
    grep -vxE '(the|and|for|with|from|into|that|this|when|all|new|fix|fixes|fixing|add|adds|update|updates|make|makes|run|runs|why|how|not|its|our|one|two|off|out|use|uses|using)' |
    grep -E '^.{3,}$' | head -6
}

playbook_regex() {
  local w out=""
  while read -r w; do
    [[ -n $w ]] || continue
    out+="${out:+|}$(sed -E 's/[][\\.^$*+?(){}|]/\\&/g' <<<"$w")"
  done < <(playbook_keywords "$1")
  echo "$out"
}

# The instances: every pattern note on this repo under this topic, oldest first,
# because a procedure is read in the order it was learned.
playbook_notes() {
  local repo=$1 topic=$2
  notes_index 2>/dev/null | jq -r --arg r "$repo" --arg t "$topic" --arg tag "$PLAYBOOK_TAG" '
    [.[] | select(.repo == $r) | select(.topic == $t)
     | select((.tags // "") | gsub("[\\[\\] ]"; "") | split(",") | index($tag))]
    | sort_by(.date) | .[]
    | "- [" + .id + "] " + .author + ", " + (.date | .[0:10]) + "\n  "
      + (.body | gsub("^\\n+"; "") | gsub("\\n+$"; "") | gsub("\\n"; "\n  "))' 2>/dev/null || true
}

# Standing facts about the same repo that share a word with the topic. A trap
# recorded as a gotcha months ago belongs in the procedure that keeps hitting it.
playbook_related_notes() {
  local repo=$1 topic=$2 re
  re=$(playbook_regex "$topic")
  [[ -n $re ]] || return 0
  notes_index 2>/dev/null | jq -r --arg r "$repo" --arg re "$re" --arg tag "$PLAYBOOK_TAG" '
    [.[] | select(.repo == $r)
     | select(((.tags // "") | gsub("[\\[\\] ]"; "") | split(",") | index($tag)) | not)
     | select(.body | test($re; "i"))]
    | .[0:6][]
    | "- [" + .id + "] " + (.tags // "note") + " · " + .author + ", " + (.date | .[0:10]) + "\n  "
      + (.body | gsub("^\\n+"; "") | gsub("\\n+$"; "") | gsub("\\n"; " "))' 2>/dev/null || true
}

# The work itself: merged pull requests on this repo whose title or body names
# the topic. These are the instances the team never wrote a note about.
playbook_prs() {
  local repo=$1 topic=$2 re
  re=$(playbook_regex "$topic")
  [[ -n $re ]] || return 0
  find "$DIR/cache/prs" -name '*.json' -not -name '*.stats.json' 2>/dev/null |
    sort | tr '\n' '\0' | xargs -0 cat 2>/dev/null |
    jq -sr --arg r "$repo" --arg re "$re" '
      [.[].prs[]? | select(.repository.name == $r)
       | select(((.title // "") + " " + (.bodyText // "")) | test($re; "i"))]
      | sort_by(.mergedAt) | reverse | .[0:12][]
      | "- \(.repository.name)#\(.number) — \(.title) <sub>\(.author.login // "unknown"), \((.mergedAt // .createdAt)[0:10])</sub>"
        + (if ((.bodyText // "") | length) > 0
           then "\n  " + ((.bodyText | gsub("\\s+"; " "))[0:400])
           else "" end)
        + ((([.reviewThreads.nodes[]?.comments.nodes[]?.path] | map(select(. != null)) | unique)) as $f
           | if ($f | length) > 0 then "\n  files reviewed: " + ($f | join(", ")) else "" end)' \
      2>/dev/null || true
}

# How the repo is run and tested, so a procedure can end in a check rather than
# in a hope. Straight out of the scan.
playbook_commands() {
  local repo=$1
  [[ -f $DIR/map/repos.json ]] || return 0
  jq -r --arg r "$repo" '.[] | select(.name == $r)
    | [ (if (.meta.language // "") != "" then "language: " + .meta.language else empty end),
        (if ((.frameworks // []) | length) > 0 then "frameworks: " + (.frameworks | join(", ")) else empty end),
        (if (.commands.package_manager // "") != "" then "package manager: " + .commands.package_manager else empty end),
        (.commands.scripts // {} | to_entries[] | "script " + .key + ": " + .value) ]
    | .[]' "$DIR/map/repos.json" 2>/dev/null || true
}

playbook_topics() {
  local repo=$1
  notes_index 2>/dev/null | jq -r --arg r "$repo" --arg tag "$PLAYBOOK_TAG" '
    [.[] | select(.repo == $r) | select(.topic != "" and .topic != null)
     | select((.tags // "") | gsub("[\\[\\] ]"; "") | split(",") | index($tag))
     | .topic] | unique | .[]' 2>/dev/null || true
}

playbook_instance_count() {
  local repo=$1 topic=$2
  notes_index 2>/dev/null | jq --arg r "$repo" --arg t "$topic" --arg tag "$PLAYBOOK_TAG" '
    [.[] | select(.repo == $r) | select(.topic == $t)
     | select((.tags // "") | gsub("[\\[\\] ]"; "") | split(",") | index($tag))] | length' 2>/dev/null || echo 0
}

# Everything the model is allowed to write from, in one block.
playbook_evidence() {
  local repo=$1 topic=$2 block

  echo "REPOSITORY: $repo"
  echo "TOPIC: $topic"
  echo

  block=$(playbook_commands "$repo")
  if [[ -n $block ]]; then
    echo "HOW THE REPOSITORY RUNS"
    echo "$block"
    echo
  fi

  echo "THE INSTANCES — notes recorded while this work was done, oldest first"
  block=$(playbook_notes "$repo" "$topic")
  echo "${block:-none}"
  echo

  block=$(playbook_related_notes "$repo" "$topic")
  if [[ -n $block ]]; then
    echo "STANDING FACTS ABOUT THE SAME REPOSITORY"
    echo "$block"
    echo
  fi

  block=$(playbook_prs "$repo" "$topic")
  if [[ -n $block ]]; then
    echo "MERGED PULL REQUESTS THAT LOOK LIKE THE SAME WORK"
    echo "$block"
    echo
  fi
}

# Write one playbook. Returns 1 without touching anything when there is not
# enough to write from — a procedure invented from a single instance is a guess
# with a heading on it.
playbook_write() {
  local repo=$1 topic=$2 force=${3:-0}
  local out n
  out=$(playbook_file "$repo" "$topic")

  n=$(playbook_instance_count "$repo" "$topic")
  if [[ ${n:-0} -lt $PLAYBOOK_MIN_INSTANCES && $force == 0 ]]; then
    log "$repo/$topic: $n instance(s) recorded, $PLAYBOOK_MIN_INSTANCES needed"
    return 1
  fi

  need claude
  local model evidence written
  model=$(cfg playbook_model "$(cfg report_model claude-opus-5)")
  evidence=$(playbook_evidence "$repo" "$topic")

  written=$( {
    cat "$ROOT/prompts/playbook.md"
    printf '\n\nTHE EVIDENCE\n"""\n%s\n"""\n' "$evidence"
  } | claude -p --model "$model" --output-format text 2>/dev/null || true)

  model_output_ok "$written" '^## ' || {
    log "$repo/$topic: the model returned nothing usable — playbook not written"
    return 1
  }

  mkdir -p "$(playbook_dir)"
  {
    echo "# $repo — $(tr '-' ' ' <<<"$topic")"
    echo
    echo "<sub>Written by \`$model\` on $(date -u +%Y-%m-%d) from $n recorded"
    echo "instance(s) and the merged pull requests that match. Unlike the rest of"
    echo "the map, the prose below was not derived — the evidence it was written"
    echo "from is printed at the end, and disagreement between the two means the"
    echo "evidence is right.</sub>"
    echo
    printf '%s\n' "$written" | linkify_prs
    echo
    echo "---"
    echo
    echo "## What this was written from"
    echo
    echo '```'
    printf '%s\n' "$evidence"
    echo '```'
    echo
    echo "Wrong, or out of date? \`orgami note --repo $repo --tag $PLAYBOOK_TAG --topic $topic \"…\"\`"
    echo "records the next instance, and \`orgami playbook $repo --topic $topic\` rewrites this."
  } >"$out"

  echo "$out"
}

# What exists for one repository, for the repo card.
playbook_section() {
  local repo=$1 f topic any=0
  compgen -G "$(playbook_dir)/$repo--*.md" >/dev/null 2>&1 || return 0
  for f in "$(playbook_dir)/$repo--"*.md; do
    [[ -f $f ]] || continue
    if [[ $any == 0 ]]; then
      echo "## How this kind of work is done here"
      echo
      any=1
    fi
    topic=$(basename "$f" .md)
    topic=${topic#*--}
    echo "- **$(tr '-' ' ' <<<"$topic")** — \`orgami playbook $repo --topic $topic\`"
  done
  [[ $any == 1 ]] && echo
  return 0
}

# The same, on one line, for the few hundred words a session starts with.
playbook_brief() {
  local repo=$1 f topics=""
  compgen -G "$(playbook_dir)/$repo--*.md" >/dev/null 2>&1 || return 0
  for f in "$(playbook_dir)/$repo--"*.md; do
    [[ -f $f ]] || continue
    topics+="${topics:+, }$(basename "$f" .md | sed 's/^.*--//')"
  done
  [[ -n $topics ]] || return 0
  echo "playbooks for this repo: $topics — orgami playbook $repo --topic <one>"
}

# The index. Cheap, mechanical, and rewritten on every `orgami doc`.
playbook_index() {
  local out="$DIR/map/PLAYBOOKS.md" f repo topic any=0
  [[ -d $(playbook_dir) ]] || return 0

  {
    echo "# $COMPANY — how this kind of work is done"
    echo
    echo "A runbook says how one repository is run and shipped. A playbook says"
    echo "how one *kind of change* is made in it — written from the instances the"
    echo "team recorded while making it, and rewritten whenever another lands."
    echo
    echo "| Repository | Topic | Instances | Written |"
    echo "|---|---|---|---|"
    for f in "$(playbook_dir)"/*.md; do
      [[ -f $f ]] || continue
      any=1
      repo=$(basename "$f" .md); topic=${repo#*--}; repo=${repo%%--*}
      printf '| %s | [%s](playbooks/%s) | %s | %s |\n' \
        "$repo" "$(tr '-' ' ' <<<"$topic")" "$(basename "$f")" \
        "$(playbook_instance_count "$repo" "$topic")" \
        "$(sed -n 's/.*on \([0-9-]\{10\}\) from.*/\1/p' "$f" | head -1)"
    done
    echo
    echo "Record the next instance while it is fresh:"
    echo
    echo '```bash'
    echo "orgami note --repo <repo> --tag $PLAYBOOK_TAG --topic <topic> \"what the shape was, and what worked\""
    echo '```'
  } >"$out"

  [[ $any == 1 ]] || rm -f "$out"
  return 0
}

# Called after a pattern note is written, by hand or by the session reader.
# Builds the playbook the moment the topic has enough instances to have one, and
# rebuilds it when a newer instance has overtaken what is on disk. Silent, and
# never fatal — this runs behind other work.
playbook_maybe() {
  local repo=$1 topic=$2 out newest
  [[ -n $repo && -n $topic ]] || return 0
  out=$(playbook_file "$repo" "$topic")

  if [[ -f $out ]]; then
    newest=$(notes_index 2>/dev/null | jq -r --arg r "$repo" --arg t "$topic" '
      [.[] | select(.repo == $r) | select(.topic == $t) | .file] | .[0] // ""' 2>/dev/null)
    [[ -n $newest && -f $newest ]] || return 0
    [[ $newest -nt $out ]] || return 0
  fi

  playbook_write "$repo" "$topic" >/dev/null 2>&1 || return 0
  playbook_index >/dev/null 2>&1 || true
  return 0
}

# orgami playbook [<repo>] [--topic T] [--all] [--list] [--force]
cmd_playbook() {
  load_company
  source "$ROOT/lib/notes.sh"

  local repo="" topic="" all=0 list=0 force=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --topic | -t) topic=$2; shift 2 ;;
      --all) all=1; shift ;;
      --list | -l) list=1; shift ;;
      --force) force=1; shift ;;
      -*) die "unknown flag: $1" ;;
      *) repo=$1; shift ;;
    esac
  done

  if [[ -z $repo && $list == 0 && $all == 0 ]]; then
    source "$ROOT/lib/card.sh"
    repo=$(card_repo_here 2>/dev/null || true)
    [[ -n $repo ]] || list=1
  fi

  if [[ $list == 1 ]]; then
    playbook_index >/dev/null || true
    if compgen -G "$(playbook_dir)/*.md" >/dev/null 2>&1; then
      local f
      for f in "$(playbook_dir)"/*.md; do
        [[ -f $f ]] || continue
        echo "$(basename "$f" .md | sed 's/--/ · /') — $f"
      done
    else
      echo "no playbooks yet."
      echo
      echo "One is written once a repository has $PLAYBOOK_MIN_INSTANCES recorded instances of the same"
      echo "kind of work. Record them as you go:"
      echo
      echo "  orgami note --repo <repo> --tag $PLAYBOOK_TAG --topic <topic> \"…\""
    fi
    return 0
  fi

  # A single file, printed rather than rebuilt, when it is already there and
  # nothing new has landed since.
  if [[ -n $repo && -n $topic && $force == 0 ]]; then
    local existing
    existing=$(playbook_file "$repo" "$topic")
    if [[ -f $existing ]]; then
      playbook_maybe "$repo" "$topic"
      cat "$existing"
      return 0
    fi
  fi

  local repos=() r t built=0
  if [[ $all == 1 ]]; then
    while read -r r; do [[ -n $r ]] && repos+=("$r"); done < <(jq -r '.[].name' "$DIR/map/repos.json" 2>/dev/null)
  else
    repos=("$repo")
  fi

  for r in "${repos[@]}"; do
    [[ -n $r ]] || continue
    if [[ -n $topic ]]; then
      playbook_write "$r" "$topic" "$force" && built=$((built + 1))
      continue
    fi
    while read -r t; do
      [[ -n $t ]] || continue
      playbook_write "$r" "$t" "$force" && built=$((built + 1))
    done < <(playbook_topics "$r")
  done

  if [[ $built == 0 ]]; then
    echo "nothing to write yet — $PLAYBOOK_MIN_INSTANCES instances of the same topic make a playbook."
    echo "Record one: orgami note --repo ${repo:-<repo>} --tag $PLAYBOOK_TAG --topic <topic> \"…\""
    return 0
  fi

  playbook_index >/dev/null || true
  echo "$built playbook(s) written."
}
