# shellcheck shell=bash
# Shared memory for a team. One file per note, so five people writing at once
# never conflict; the docs repo is the sync layer, so there is nothing to host.

notes_author() {
  local a
  a=$(jq -r '.author // empty' "$ORGAMI_HOME/config.json" 2>/dev/null)
  if [[ -z $a ]]; then
    a=$(gh api user --jq .login 2>/dev/null || git config user.name 2>/dev/null || echo "$USER")
    local tmp
    tmp=$(mktemp)
    [[ -f $ORGAMI_HOME/config.json ]] || echo '{}' >"$ORGAMI_HOME/config.json"
    jq --arg a "$a" '.author = $a' "$ORGAMI_HOME/config.json" >"$tmp"
    mv "$tmp" "$ORGAMI_HOME/config.json"
  fi
  echo "$a"
}

# A note is published to a shared repository under the user's name. These are
# the things that must never ride along: credentials, and another client.
notes_screen() {
  local text=$1 company=$2 problems=() warnings=()

  local secret_patterns=(
    '-----BEGIN [A-Z ]*PRIVATE KEY'
    'AKIA[0-9A-Z]{16}'
    'ASIA[0-9A-Z]{16}'
    'gh[pousr]_[A-Za-z0-9]{20,}'
    'github_pat_[A-Za-z0-9_]{20,}'
    'xox[baprs]-[A-Za-z0-9-]{10,}'
    '(sk|rk)_live_[A-Za-z0-9]{10,}'
    'AIza[0-9A-Za-z_-]{30,}'
    'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    '://[^/@[:space:]:]+:[^/@[:space:]]{4,}@'
    '(password|passwd|secret|api[_-]?key|access[_-]?token|private[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]<>"]{8,}'
  )
  local pat
  for pat in "${secret_patterns[@]}"; do
    if grep -qiE -- "$pat" <<<"$text"; then
      problems+=("looks like a credential: $(grep -oiE -- "$pat" <<<"$text" | head -1 | cut -c1-28)…")
    fi
  done

  # Another client's organization must not surface in this one's notes.
  local other org
  while read -r other; do
    [[ -n $other && $other != "$company" ]] || continue
    org=$(jq -r '.org // empty' "$(company_dir "$other")/config.json" 2>/dev/null)
    for pat in "$other" "$org"; do
      [[ -n $pat && ${#pat} -ge 3 ]] || continue
      grep -qiE -- "(^|[^A-Za-z0-9-])$pat([^A-Za-z0-9-]|$)" <<<"$text" &&
        problems+=("mentions another client you have configured here: $pat")
    done
  done < <(companies)

  if grep -qE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-z]{2,}' <<<"$text"; then
    warnings+=("contains an email address")
  fi
  if grep -qE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' <<<"$text"; then
    warnings+=("contains an IP address")
  fi

  local w
  for w in "${warnings[@]}"; do
    [[ -n $w ]] && log "note $w"
  done

  [[ ${#problems[@]} -eq 0 ]] && return 0
  {
    echo "refusing to write this note:"
    printf '  - %s\n' "${problems[@]}"
    echo
    echo "Notes go to a repository the whole team reads. Rewrite it without that,"
    echo "or point at where the value lives instead of quoting it."
  } >&2
  return 1
}

# Everything after the frontmatter. A sed range cannot do this reliably.
notes_body() {
  awk 'f { print } /^---$/ { c++; if (c == 2) f = 1 }' "$1"
}

notes_slug() {
  tr '[:upper:]' '[:lower:]' <<<"$1" |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40
}

# The repo this note is about: an explicit --repo, or the checkout we are in.
notes_repo_here() {
  local guess
  guess=$(card_repo_here 2>/dev/null || true)
  [[ -n $guess ]] || return 0
  if jq -e --arg r "$guess" 'any(.[]; .name == $r)' "$DIR/map/repos.json" >/dev/null 2>&1; then
    echo "$guess"
  fi
  return 0
}

cmd_note() {
  load_company
  source "$ROOT/lib/card.sh"
  mkdir -p "$DIR/notes"

  local repo="" tags=() text="" push=0 supersedes=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --repo | -r) repo=$2; shift 2 ;;
      --tag | -t) tags+=("$2"); shift 2 ;;
      --push) push=1; shift ;;
      --supersede) supersedes=$2; shift 2 ;;
      --) shift; text="$*"; break ;;
      -*) die "unknown flag: $1" ;;
      *) text="$*"; break ;;
    esac
  done

  if [[ -z $text ]]; then
    if command -v gum >/dev/null; then
      text=$(gum write --placeholder "What did you learn? Write it for whoever hits this next." \
        --width 76 --height 8 --header "note for $COMPANY") || return 1
    else
      local f
      f="${TMPDIR:-/tmp}/orgami-note-$$.md"
      "${EDITOR:-vi}" "$f" || true
      text=$(cat "$f")
      rm -f "$f"
    fi
  fi
  [[ -n ${text// /} ]] || die "nothing to record"

  # Standing in one client's checkout while the default company is another is
  # exactly how a note ends up in the wrong repository.
  local here_url here_org
  here_url=$(git -C "$PWD" remote get-url origin 2>/dev/null || true)
  if [[ -n $here_url ]]; then
    here_org=$(sed -E 's|.*[:/]([^/]+)/[^/]+$|\1|' <<<"$here_url")
    local here_lc org_lc
    here_lc=$(printf '%s' "$here_org" | tr '[:upper:]' '[:lower:]')
    org_lc=$(printf '%s' "$ORG" | tr '[:upper:]' '[:lower:]')
    if [[ -n $here_org && $here_lc != "$org_lc" ]]; then
      die "this checkout belongs to '$here_org' but the note would go to '$COMPANY' ($ORG).
     Switch with ORGAMI_COMPANY=<name>, or pass --repo if you meant it."
    fi
  fi

  notes_screen "$text" "$COMPANY" || return 1

  [[ -n $repo ]] || repo=$(notes_repo_here)

  # A tag from this vocabulary files the note into a section of the repo's
  # runbook. Anything else is still a perfectly good note.
  if [[ ${#tags[@]} -eq 0 ]] && command -v gum >/dev/null; then
    source "$ROOT/lib/runbook.sh"
    local picked
    picked=$(printf '%s\n' "${RUNBOOK_TAGS[@]}" "none of these" |
      gum choose --header "File it in the runbook under…" 2>/dev/null || true)
    [[ -n $picked && $picked != "none of these" ]] && tags=("$picked")
  fi

  local author stamp id file
  author=$(notes_author)
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  id="$(date -u +%Y%m%d-%H%M%S)-$author-$(notes_slug "${text%%$'\n'*}")"
  file="$DIR/notes/$id.md"

  {
    echo "---"
    echo "id: $id"
    echo "author: $author"
    echo "date: $stamp"
    [[ -n $repo ]] && echo "repo: $repo"
    [[ -n $supersedes ]] && echo "supersedes: $supersedes"
    [[ ${#tags[@]} -gt 0 ]] && printf 'tags: [%s]\n' "$(
      IFS=,
      echo "${tags[*]}"
    )"
    echo "---"
    echo
    echo "$text"
  } >"$file"

  echo "$file"
  [[ $push == 1 ]] && cmd_sync
  return 0
}

# Frontmatter of every note as one JSON array, body included.
notes_index() {
  local f
  for f in "$DIR"/notes/*.md; do
    [[ -f $f ]] || continue
    awk -v file="$f" '
      BEGIN { inmeta = 0; body = "" }
      NR == 1 && $0 == "---" { inmeta = 1; next }
      inmeta && $0 == "---" { inmeta = 0; next }
      inmeta {
        key = $0; sub(/:.*/, "", key)
        val = $0; sub(/^[^:]*:[ ]*/, "", val)
        meta[key] = val
        next
      }
      { body = body $0 "\n" }
      END {
        gsub(/\\/, "\\\\", body); gsub(/"/, "\\\"", body); gsub(/\n/, "\\n", body)
        printf "{\"id\":\"%s\",\"author\":\"%s\",\"date\":\"%s\",\"repo\":\"%s\",\"tags\":\"%s\",\"supersedes\":\"%s\",\"file\":\"%s\",\"body\":\"%s\"}\n",
          meta["id"], meta["author"], meta["date"], meta["repo"], meta["tags"], meta["supersedes"], file, body
      }' "$f"
  done | jq -s '
    (map(.supersedes) | map(select(. != "")) | unique) as $dead
    | map(select(.id as $i | ($dead | index($i)) | not))
    | sort_by(.date) | reverse'
}

# Every note, including the ones a newer note replaced.
notes_index_all() {
  local f
  for f in "$DIR"/notes/*.md; do
    [[ -f $f ]] || continue
    printf '%s\n' "$f"
  done
}

# Markdown for the notes attached to one repo. Used by the repo card.
notes_for_repo() {
  local repo=$1
  [[ -d $DIR/notes ]] || return 0
  local out
  out=$(notes_index 2>/dev/null | jq -r --arg r "$repo" '
    [.[] | select(.repo == $r)] | .[0:8][]
    | "- " + (.body | gsub("^\\n+"; "") | gsub("\\n+$"; "") | gsub("\\n"; " ")) + "\n  <sub>" + .author + ", " + (.date | .[0:10]) + "</sub>"' 2>/dev/null || true)
  [[ -n $out ]] || return 0
  echo "## What the team has learned"
  echo
  echo "$out"
  echo
}

cmd_notes() {
  load_company
  local repo="" tag="" query="" check=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --repo | -r) repo=$2; shift 2 ;;
      --tag | -t) tag=$2; shift 2 ;;
      --check) check=1; shift ;;
      *) query="$*"; break ;;
    esac
  done

  # Screen every note on disk, including ones that arrived from teammates.
  if [[ $check == 1 ]]; then
    local f bad=0
    for f in "$DIR"/notes/*.md; do
      [[ -f $f ]] || continue
      if ! notes_screen "$(notes_body "$f")" "$COMPANY"; then
        echo "  ^ $(basename "$f")" >&2
        bad=$((bad + 1))
      fi
    done
    if [[ $bad -eq 0 ]]; then
      echo "all notes pass screening"
    else
      echo "$bad note(s) need attention" >&2
      return 1
    fi
    return 0
  fi

  [[ -d $DIR/notes ]] || die "no notes yet — write one with: orgami note \"...\""

  notes_index | jq -r --arg repo "$repo" --arg tag "$tag" --arg q "$query" '
    [.[]
     | select($repo == "" or .repo == $repo)
     | select($tag == "" or (.tags | test($tag; "i")))
     | select($q == "" or ((.body + " " + .repo + " " + .tags) | test($q; "i")))]
    | if length == 0 then "no notes match" else
      .[] | "\(.date[0:10])  \(.author)\(if .repo != "" then "  [" + .repo + "]" else "" end)\(if .tags != "" then "  " + .tags else "" end)\n  \(.body | gsub("^\\n+"; "") | gsub("\\n+$"; "") | gsub("\\n"; "\n  "))\n"
      end'
}

# Notes nobody has touched in a long time: candidates for review or removal.
cmd_stale() {
  load_company
  local days=${1:-120} cutoff
  cutoff=$(date_shift "$(date -u +%Y-%m-%d)" "-$days")
  [[ -d $DIR/notes ]] || die "no notes yet"

  notes_index | jq -r --arg cutoff "$cutoff" --arg days "$days" '
    [.[] | select(.date[0:10] < $cutoff)]
    | if length == 0 then "Nothing older than \($days) days." else
      ["\(length) note(s) older than \($days) days — still true?", ""]
      + (.[] | ["  \(.date[0:10])  \(.author)\(if .repo != "" then "  [" + .repo + "]" else "" end)",
                "    \(.body | gsub("^\\n+"; "") | gsub("\\n+$"; "") | gsub("\\n"; " ") | .[0:120])",
                "    replace: orgami note --supersede \(.id) \"...\"",
                "    remove:  orgami prune --id \(.id)", ""])
      | .[] end'
}

# Superseded notes, and anything named explicitly, move out of the way. They
# stay on disk under notes/archive so nothing is destroyed, and the next sync
# takes them out of the shared repository.
cmd_prune() {
  load_company
  local id="" superseded=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --id) id=$2; shift 2 ;;
      --superseded) superseded=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [[ -n $id || $superseded == 1 ]] ||
    die "usage: orgami prune --id <note-id> | orgami prune --superseded"

  mkdir -p "$DIR/notes/archive"
  local moved=0 f base

  if [[ $superseded == 1 ]]; then
    local dead
    dead=$(grep -h '^supersedes:' "$DIR"/notes/*.md 2>/dev/null | sed 's/^supersedes:[[:space:]]*//' | sort -u)
    while read -r d; do
      [[ -n $d ]] || continue
      f="$DIR/notes/$d.md"
      [[ -f $f ]] || continue
      mv "$f" "$DIR/notes/archive/"
      moved=$((moved + 1))
      echo "archived $d"
    done <<<"$dead"
  fi

  if [[ -n $id ]]; then
    f="$DIR/notes/$id.md"
    [[ -f $f ]] || die "no note with id '$id' — orgami notes"
    mv "$f" "$DIR/notes/archive/"
    moved=$((moved + 1))
    echo "archived $id"
  fi

  echo "$moved archived to $DIR/notes/archive"
  [[ -n $(cfg docs_repo) ]] && log "run 'orgami sync' to take them out of the shared repo"
  return 0
}

# Screen note files without needing a configured company. This is what runs in
# CI on a pull request, so a note nobody looked at closely still cannot merge.
cmd_screen() {
  local bad=0 f
  [[ $# -gt 0 ]] || die "usage: orgami screen <file>..."
  for f in "$@"; do
    [[ -f $f ]] || continue
    if notes_screen "$(notes_body "$f")" "${ORGAMI_COMPANY:-}"; then
      echo "ok   $f"
    else
      echo "FAIL $f" >&2
      bad=$((bad + 1))
    fi
  done
  [[ $bad -eq 0 ]] || {
    echo >&2
    echo "$bad note(s) cannot be published. Rewrite them and push again." >&2
    return 1
  }
  echo "all notes clean"
}

# Review the open notes pull requests without leaving the terminal.
cmd_review() {
  load_company
  need gh

  local install=0 auto=0 merge=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --install-check) install=1; shift ;;
      --auto) auto=1; shift ;;
      --merge) merge=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [[ $(cfg notes_auto_merge false) == true ]] && merge=1

  local repo path work
  repo=$(cfg docs_repo)
  path=$(cfg docs_path orgami)
  [[ -n $repo ]] || die "no docs_repo configured — nothing to review"
  work="$DIR/cache/docs"
  [[ -d $work/.git ]] || git clone --quiet --depth 1 "$repo" "$work" || die "cannot clone $repo"

  [[ $install == 1 ]] && { review_install_check "$work"; return; }

  local prs
  prs=$(cd "$work" && gh pr list --state open --json number,title,author,headRefName,createdAt \
    --jq '[.[] | select(.headRefName | startswith("orgami-notes/"))]' 2>/dev/null || echo '[]')

  [[ $(jq 'length' <<<"$prs") -gt 0 ]] || { echo "no notes waiting for review"; return 0; }

  local n
  while read -r n; do
    [[ -n $n ]] || continue

    if [[ $auto == 1 ]]; then
      review_auto "$work" "$n" "$merge"
      continue
    fi

    echo
    printf '\033[1m#%s — %s\033[0m\n' "$n" \
      "$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .title' <<<"$prs")"
    printf '\033[2mby %s · %s\033[0m\n\n' \
      "$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .author.login' <<<"$prs")" \
      "$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .createdAt[0:10]' <<<"$prs")"

    # Show the notes themselves, not a diff.
    (cd "$work" && gh pr diff "$n" 2>/dev/null) |
      awk '/^\+\+\+ b\// { file = $2; sub("^b/", "", file) }
           /^\+/ && !/^\+\+\+/ { line = substr($0, 2)
             if (line !~ /^(id|author|date|repo|tags|supersedes|---)/ && line != "")
               print "  " line }' | head -30

    echo
    if command -v gum >/dev/null; then
      local choice
      choice=$(gum choose --header "#$n" "merge it" "leave it open" "open in the browser" "close it") ||
        continue
      case $choice in
        "merge it")
          (cd "$work" && gh pr merge "$n" --squash --delete-branch) &&
            echo "merged #$n — teammates get it on their next 'orgami sync'"
          ;;
        "open in the browser") (cd "$work" && gh pr view "$n" --web) ;;
        "close it") (cd "$work" && gh pr close "$n" --delete-branch) && echo "closed #$n" ;;
      esac
    else
      echo "  merge: gh pr merge $n --squash --delete-branch --repo $(basename "${repo%.git}")"
    fi
  done < <(jq -r '.[].number' <<<"$prs")
}

# A second reader, when there is no second person. Judges the notes waiting for
# review against everything already recorded, comments on the pull request, and
# merges only if every note passes.
review_auto() {
  local work=$1 n=$2 merge=$3
  need claude

  local files bodies
  files=$( (cd "$work" && gh pr diff "$n" --name-only 2>/dev/null) | grep '/notes/.*\.md$' || true)
  [[ -n $files ]] || { log "#$n adds no notes"; return 0; }

  # The notes under review, straight from the branch — fetched once, not per file.
  local head f
  head=$(cd "$work" && gh pr view "$n" --json headRefName --jq .headRefName 2>/dev/null)
  [[ -n $head ]] || { log "could not resolve the branch for #$n"; return 0; }
  git -C "$work" fetch --quiet origin "$head" 2>/dev/null || true

  bodies=$(mktemp)
  while read -r f; do
    [[ -n $f ]] || continue
    # A pull request that prunes a note lists a file that is not on the branch.
    local content
    content=$(git -C "$work" show "FETCH_HEAD:$f" 2>/dev/null || true)
    [[ -n $content ]] || continue
    jq -Rns --arg file "$f" --arg text "$content" '{file: $file, text: $text}'
  done <<<"$files" | jq -s '.' >"$bodies"

  [[ $(jq 'length' "$bodies") -gt 0 ]] || { log "could not read the notes on #$n"; return 0; }

  # Everything already known, genuinely minus the notes under review — they are
  # already on this machine, so without this every note looks like its own duplicate.
  local existing under_review
  under_review=$(jq -r '[.[] | .text | capture("id: (?<id>[^\n]+)").id] // []' "$bodies" 2>/dev/null || echo '[]')
  existing=$(mktemp)
  {
    notes_index 2>/dev/null |
      jq -r --argjson under "$under_review" '
        [.[] | select(.id as $i | ($under | index($i)) | not)][]
        | "- [\(.id)] \(.repo // "org"): \(.body | gsub("\\n"; " ") | .[0:240])"'
    if [[ -f $DIR/map/DECISIONS.md ]]; then
      echo
      echo "Decisions already recorded:"
      grep -E '^- ' "$DIR/map/DECISIONS.md" | head -40
    fi
  } >"$existing"

  local model verdicts raw
  raw=$(mktemp)
  model=$(cfg report_model claude-sonnet-5)
  log "reading #$n with $model"
  {
    cat "$ROOT/prompts/note-review.md"
    printf '\n\nNEW_NOTES\n```json\n'
    cat "$bodies"
    printf '\n```\n\nEXISTING\n```\n'
    cat "$existing"
    printf '\n```\n'
  } | claude -p --model "$model" --output-format text >"$raw" 2>/dev/null || true

  # Everything from the first brace onwards, code fences stripped.
  verdicts=$(sed -e '/^[[:space:]]*```/d' "$raw" |
    sed -n '/^[[:space:]]*{/,$p' | jq -c '.' 2>/dev/null || true)
  [[ -n $verdicts ]] || log "reviewer did not return JSON: $(head -c 100 "$raw")"
  rm -f "$bodies" "$existing" "$raw"

  if [[ -z $verdicts ]]; then
    log "the reviewer did not return usable JSON — leaving #$n for a person"
    return 0
  fi

  local body
  body=$(jq -r '
    "**orgami reviewed these notes.** " + (.summary // "") + "\n\n"
    + ([.verdicts[]
        | "- " + (if .verdict == "approve" then "✅" elif .verdict == "revise" then "✏️" else "🚫" end)
          + " `" + .id + "` — " + .reason
          + (if (.supersedes // "") != "" then "\n  Supersede instead: `orgami note --supersede " + .supersedes + " \"...\"`" else "" end)]
       | join("\n"))
    + "\n\n<sub>A judgement, not a gate. The credential screening above is the gate.</sub>"' <<<"$verdicts")

  (cd "$work" && gh pr comment "$n" --body "$body") >/dev/null &&
    echo "commented on #$n"

  local bad
  bad=$(jq '[.verdicts[] | select(.verdict != "approve")] | length' <<<"$verdicts")
  jq -r '.verdicts[] | "  " + (if .verdict == "approve" then "approve" else .verdict end) + "  " + .id' <<<"$verdicts"

  if [[ $bad -gt 0 ]]; then
    echo "$bad note(s) need work — #$n left open"
    return 0
  fi

  if [[ $merge == 1 ]]; then
    (cd "$work" && gh pr merge "$n" --squash --delete-branch) &&
      echo "merged #$n"
  else
    echo "#$n is clean — merge it with: orgami review --auto --merge"
  fi
}

# The check that makes review mean something: it runs on every pull request.
review_install_check() {
  local work=$1
  local wf="$work/.github/workflows/orgami-notes.yml"
  mkdir -p "$(dirname "$wf")"
  cat >"$wf" <<'YML'
name: orgami notes

# Screens every note added in a pull request for credentials before it can
# reach the team. Generated by `orgami review --install-check`.

on:
  pull_request:
    paths:
      - "**/notes/*.md"

jobs:
  screen:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Collect the notes this pull request adds
        run: |
          git diff --name-only --diff-filter=AM "origin/${{ github.base_ref }}...HEAD" -- "*notes/*.md" > changed.txt
          echo "changed:"
          cat changed.txt

      - name: Screen them
        run: |
          git clone --depth 1 https://github.com/achevalier-dev/orgami /tmp/orgami
          status=0
          while read -r f; do
            [ -n "$f" ] || continue
            /tmp/orgami/bin/orgami screen "$f" || status=1
          done < changed.txt
          exit $status
YML

  git -C "$work" add .github/workflows/orgami-notes.yml
  if git -C "$work" diff --cached --quiet; then
    echo "the check is already installed"
    return 0
  fi
  git -C "$work" commit --quiet -m "ci(orgami): screen notes on every pull request"
  git -C "$work" push --quiet origin HEAD || die "could not push the workflow"
  echo "installed .github/workflows/orgami-notes.yml in $(cfg docs_repo)"

  # A check nobody is required to pass is only advice. Make it required, if the
  # repository's plan allows branch protection.
  local slug branch
  slug=$(git -C "$work" remote get-url origin |
    sed -E 's|.*[:/]([^/]+/[^/]+?)(\.git)?$|\1|')
  branch=$(gh api "repos/$slug" --jq .default_branch 2>/dev/null || echo main)
  if gh api "repos/$slug/branches/$branch/protection" -X PUT \
    -H "Accept: application/vnd.github+json" \
    --input - >/dev/null 2>&1 <<PROT
{"required_status_checks": {"strict": false, "contexts": ["screen"]},
 "enforce_admins": false, "required_pull_request_reviews": null, "restrictions": null}
PROT
  then
    echo "the screen check is now required to merge into $branch"
  else
    log "could not require the check on $branch — branch protection needs a paid plan on private repos"
    log "the check still runs and shows on every pull request"
  fi
}

# Two-way: take what the team wrote, hand over what you wrote.
# shellcheck disable=SC2120  # flags come from the dispatcher, not a caller here
cmd_sync() {
  load_company
  need git

  local review=-1
  while [[ $# -gt 0 ]]; do
    case $1 in
      --pr | --review) review=1; shift ;;
      --no-pr | --direct) review=0; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  if [[ $review == -1 ]]; then
    [[ $(cfg notes_review false) == true ]] && review=1 || review=0
  fi

  local repo path
  repo=$(cfg docs_repo)
  path=$(cfg docs_path orgami)
  [[ -n $repo ]] || die "no docs_repo configured — nothing to sync with"

  local work="$DIR/cache/docs"
  if [[ -d $work/.git ]]; then
    git -C "$work" fetch --quiet origin || die "cannot reach $repo"
    git -C "$work" reset --hard --quiet \
      "origin/$(git -C "$work" rev-parse --abbrev-ref origin/HEAD | sed 's|origin/||')"
  else
    git clone --quiet --depth 1 "$repo" "$work" || die "cannot clone $repo"
  fi

  local remote="$work/$path/notes"
  mkdir -p "$remote" "$DIR/notes"

  # Anything archived locally comes out of the shared repository too.
  local removed=0
  if [[ -d $DIR/notes/archive ]]; then
    for f in "$DIR"/notes/archive/*.md; do
      [[ -f $f ]] || continue
      base=$(basename "$f")
      if [[ -f $remote/$base ]]; then
        rm -f "$remote/$base"
        removed=$((removed + 1))
      fi
    done
  fi

  local pulled=0 pushed=0 f base
  for f in "$remote"/*.md; do
    [[ -f $f ]] || continue
    base=$(basename "$f")
    [[ -f $DIR/notes/$base ]] && continue
    cp "$f" "$DIR/notes/$base"
    pulled=$((pulled + 1))
  done

  # Last check before anything leaves this machine. A note written by hand, or
  # by an older version, gets the same screening as one written by the CLI.
  local blocked=0
  for f in "$DIR"/notes/*.md; do
    [[ -f $f ]] || continue
    base=$(basename "$f")
    [[ -f $remote/$base ]] && continue
    if ! notes_screen "$(notes_body "$f")" "$COMPANY" 2>/dev/null; then
      log "not syncing $base — it does not pass screening; run: orgami notes --check"
      blocked=$((blocked + 1))
      continue
    fi
    cp "$f" "$remote/$base"
    pushed=$((pushed + 1))
  done
  [[ $blocked -gt 0 ]] && log "$blocked note(s) held back"

  if [[ -n $(git -C "$work" status --porcelain) ]]; then
    local msg
    msg="notes($COMPANY): $pushed from $(notes_author)"
    [[ $removed -gt 0 ]] && msg="$msg, $removed removed"
    git -C "$work" add -A "$path/notes"

    if [[ $review == 1 ]]; then
      need gh
      # One branch per author, reused. Syncing twice before anyone reviews adds
      # to the open pull request instead of opening a second one.
      local branch base existing
      branch="orgami-notes/$(notes_author)"
      if git -C "$work" fetch --quiet origin "$branch" 2>/dev/null; then
        git -C "$work" checkout --quiet -B "$branch" FETCH_HEAD
      else
        git -C "$work" checkout --quiet -B "$branch"
      fi
      git -C "$work" add -A "$path/notes"
      git -C "$work" commit --quiet -m "$msg" || true
      git -C "$work" push --quiet -u origin "$branch" || die "could not push $branch"

      base=$(git -C "$work" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|origin/||')
      [[ -n $base ]] || base=main
      existing=$(cd "$work" && gh pr list --head "$branch" --state open \
        --json number --jq '.[0].number // empty' 2>/dev/null || true)

      if [[ -n $existing ]]; then
        log "updated pull request #$existing"
      else
        local reviewers=()
        while read -r r; do [[ -n $r ]] && reviewers+=(--reviewer "$r"); done \
          < <(jq -r '(.notes_reviewers // [])[]' "$DIR/config.json" 2>/dev/null)
        ( cd "$work" && gh pr create --head "$branch" --base "$base" --title "$msg" \
            "${reviewers[@]}" \
            --body "Notes written with \`orgami note\`. Merging publishes them to everyone on $COMPANY.

Review for: anything that should not be shared, anything already stale, anything better fixed in the code than written down." ) ||
          log "branch pushed, but the pull request was not created — open it by hand"
      fi
      git -C "$work" checkout --quiet -
    else
      git -C "$work" commit --quiet -m "$msg"
      git -C "$work" push --quiet origin HEAD || die "could not push — pull and retry"
    fi
  fi

  local mode="direct"
  [[ $review == 1 ]] && mode="pull request"
  echo "$pulled in, $pushed out$([[ $removed -gt 0 ]] && echo ", $removed removed") · $mode · \
$(find "$DIR/notes" -maxdepth 1 -name '*.md' | wc -l) notes live"
}

# Everything a teammate needs, without cloning forty repositories.

JOIN_PATHS=(orgami docs/orgami engineering/orgami .orgami .)

# Repos in an org that already hold a published map. One line: repo<TAB>path
join_discover() {
  local org=$1 repos path
  repos=$(gh api "orgs/$org/repos?per_page=100" --paginate --jq '.[].name' 2>/dev/null ||
    gh api "users/$org/repos?per_page=100" --paginate --jq '.[].name' 2>/dev/null) || return 0
  [[ -n $repos ]] || return 0

  for path in "${JOIN_PATHS[@]}"; do
    local found
    found=$(ORG_PROBE=$org PATH_PROBE=$path xargs -P12 -I{} bash -c '
      target="$PATH_PROBE/graph.json"
      [[ $PATH_PROBE == "." ]] && target="graph.json"
      gh api "repos/$ORG_PROBE/{}/contents/$target" --jq .sha >/dev/null 2>&1 &&
        printf "%s\t%s\n" "{}" "$PATH_PROBE"' <<<"$repos")
    if [[ -n $found ]]; then
      echo "$found"
      return 0
    fi
  done
}

# Pulls a published map into a new company directory.
join_from_repo() {
  local company=$1 repo=$2 path=$3
  local dir
  dir=$(company_dir "$company")
  [[ -f $dir/config.json ]] && die "'$company' already exists — orgami list"
  mkdir -p "$dir"/{cache/prs,cache/repos,cache/src,reports,map,notes}

  local work="$dir/cache/docs"
  rm -rf "$work"
  git clone --quiet --depth 1 "$repo" "$work" || die "cannot clone $repo"
  local src="$work/$path"
  [[ -d $src ]] || die "$repo has no $path/ — is that the right docs repo?"

  cp -f "$src"/*.md "$src"/*.json "$dir/map/" 2>/dev/null || true
  [[ -d $src/repos ]] && cp -r "$src/repos" "$dir/map/" 2>/dev/null
  [[ -d $src/reports ]] && cp -f "$src/reports/"*.md "$dir/reports/" 2>/dev/null
  [[ -d $src/notes ]] && cp -f "$src/notes/"*.md "$dir/notes/" 2>/dev/null

  local org
  org=$(jq -r '.org // empty' "$dir/map/graph.json" 2>/dev/null)
  [[ -n $org ]] || die "no graph.json in $repo:$path — has anyone run 'orgami scan' yet?"

  jq -n --arg company "$company" --arg org "$org" --arg repo "$repo" --arg path "$path" \
    '{company: $company, org: $org, docs_repo: $repo, docs_path: $path,
      exclude: [], include: [], report_model: "claude-sonnet-5"}' >"$dir/config.json"

  mkdir -p "$ORGAMI_HOME"
  [[ -f $ORGAMI_HOME/config.json ]] || echo '{}' >"$ORGAMI_HOME/config.json"
  local tmp
  tmp=$(mktemp)
  jq --arg c "$company" '.default = (.default // $c)' "$ORGAMI_HOME/config.json" >"$tmp"
  mv "$tmp" "$ORGAMI_HOME/config.json"

  echo "joined $company ($org) — $(find "$dir/map/repos" -name '*.md' 2>/dev/null | wc -l) repo cards, \
$(find "$dir/reports" -name '*.md' 2>/dev/null | wc -l) reports, \
$(find "$dir/notes" -name '*.md' 2>/dev/null | wc -l) notes, no scan needed"
}

cmd_join() {
  local company=${1:-} repo="" path="orgami"

  # Flag form, for scripts: orgami join <company> --repo <url> [--path <dir>]
  if [[ -n $company && $company != -* ]]; then
    shift
    while [[ $# -gt 0 ]]; do
      case $1 in
        --repo) repo=$2; shift 2 ;;
        --path) path=$2; shift 2 ;;
        *) die "unknown flag: $1" ;;
      esac
    done
    [[ -n $repo ]] || die "usage: orgami join <company> --repo <docs-repo-url> [--path <dir>]"
    join_from_repo "$company" "$repo" "$path"
    return
  fi

  # Bare `orgami join`: pick the org, find the map that is already there.
  source "$ROOT/lib/ui.sh"
  ui_need_gum || die "usage: orgami join <company> --repo <docs-repo-url>"
  need gh
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

  echo
  ui_title "Join an organization someone has already mapped"
  ui_dim "Pulls their map, cards, decisions and team notes. No scan, no clones."
  echo

  local org
  org=$(ui_pick_org) || return 1
  [[ -n $org ]] || return 1
  if [[ $org == "type another…" ]]; then
    org=$(gum input --placeholder "github organization login" --prompt "org: ") || return 1
  fi
  [[ -n $org ]] || return 1

  local found
  found=$(gum spin --show-output --spinner dot \
    --title "looking for a published map in $org…" -- \
    bash -c "source '$ROOT/lib/common.sh'; source '$ROOT/lib/notes.sh'; join_discover '$org'")

  if [[ -z $found ]]; then
    gum style --foreground 3 "No orgami map published in $org yet."
    ui_dim "Someone with the repos checked out runs: orgami init"
    return 1
  fi

  local choice
  if [[ $(wc -l <<<"$found") -gt 1 ]]; then
    choice=$(awk -F'\t' '{printf "%s  (%s/)\n", $1, $2}' <<<"$found" |
      gum choose --header "Which one?") || return 1
    choice=${choice%%  (*}
    path=$(awk -F'\t' -v r="$choice" '$1 == r {print $2}' <<<"$found" | head -1)
    repo=$choice
  else
    repo=$(cut -f1 <<<"$found")
    path=$(cut -f2 <<<"$found")
    gum style --foreground 2 "✓ found $org/$repo ($path/)"
  fi

  local suggested
  suggested=$(gh api "repos/$org/$repo/contents/$path/graph.json" \
    -H "Accept: application/vnd.github.raw" 2>/dev/null |
    jq -r '.company // empty' 2>/dev/null)
  [[ -n $suggested ]] || suggested=$org

  company=$(gum input --prompt "short name for this org: " --value "$suggested") || return 1
  company=${company// /-}
  [[ -n $company ]] || return 1

  join_from_repo "$company" "git@github.com:$org/$repo.git" "$path"
}
