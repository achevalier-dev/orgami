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

notes_slug() {
  tr '[:upper:]' '[:lower:]' <<<"$1" |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40
}

# The repo this note is about: an explicit --repo, or the checkout we are in.
notes_repo_here() {
  local guess
  guess=$(card_repo_here 2>/dev/null || true)
  [[ -n $guess ]] || return 0
  jq -e --arg r "$guess" 'any(.[]; .name == $r)' "$DIR/map/repos.json" >/dev/null 2>&1 &&
    echo "$guess"
}

cmd_note() {
  load_company
  source "$ROOT/lib/card.sh"
  mkdir -p "$DIR/notes"

  local repo="" tags=() text="" push=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --repo | -r) repo=$2; shift 2 ;;
      --tag | -t) tags+=("$2"); shift 2 ;;
      --push) push=1; shift ;;
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
      f=$(mktemp --suffix=.md)
      "${EDITOR:-vi}" "$f" || true
      text=$(cat "$f")
      rm -f "$f"
    fi
  fi
  [[ -n ${text// /} ]] || die "nothing to record"

  [[ -n $repo ]] || repo=$(notes_repo_here)

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
        printf "{\"id\":\"%s\",\"author\":\"%s\",\"date\":\"%s\",\"repo\":\"%s\",\"tags\":\"%s\",\"file\":\"%s\",\"body\":\"%s\"}\n",
          meta["id"], meta["author"], meta["date"], meta["repo"], meta["tags"], file, body
      }' "$f"
  done | jq -s 'sort_by(.date) | reverse'
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
  local repo="" tag="" query=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --repo | -r) repo=$2; shift 2 ;;
      --tag | -t) tag=$2; shift 2 ;;
      *) query="$*"; break ;;
    esac
  done

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

# Two-way: take what the team wrote, hand over what you wrote.
cmd_sync() {
  load_company
  need git

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

  local pulled=0 pushed=0 f base
  for f in "$remote"/*.md; do
    [[ -f $f ]] || continue
    base=$(basename "$f")
    [[ -f $DIR/notes/$base ]] && continue
    cp "$f" "$DIR/notes/$base"
    pulled=$((pulled + 1))
  done

  for f in "$DIR"/notes/*.md; do
    [[ -f $f ]] || continue
    base=$(basename "$f")
    [[ -f $remote/$base ]] && continue
    cp "$f" "$remote/$base"
    pushed=$((pushed + 1))
  done

  if [[ -n $(git -C "$work" status --porcelain) ]]; then
    git -C "$work" add -A "$path/notes"
    git -C "$work" commit --quiet -m "notes($COMPANY): $pushed from $(notes_author)"
    git -C "$work" push --quiet origin HEAD || die "could not push — pull and retry"
  fi

  echo "$pulled in, $pushed out · $(find "$DIR/notes" -name '*.md' | wc -l) notes total"
}

# Everything a teammate needs, without cloning forty repositories.
cmd_join() {
  local company=${1:-} repo="" path="orgami"
  shift || true
  while [[ $# -gt 0 ]]; do
    case $1 in
      --repo) repo=$2; shift 2 ;;
      --path) path=$2; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [[ -n $company && -n $repo ]] ||
    die "usage: orgami join <company> --repo <docs-repo-url> [--path <dir>]"

  local dir
  dir=$(company_dir "$company")
  [[ -f $dir/config.json ]] && die "'$company' already exists — orgami list"
  mkdir -p "$dir"/{cache/prs,cache/repos,cache/src,reports,map,notes}

  local work="$dir/cache/docs"
  git clone --quiet --depth 1 "$repo" "$work" || die "cannot clone $repo"
  local src="$work/$path"
  [[ -d $src ]] || die "$repo has no $path/ — is that the right docs repo?"

  cp -r "$src"/*.md "$src"/*.json "$dir/map/" 2>/dev/null || true
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
$(find "$dir/notes" -name '*.md' 2>/dev/null | wc -l) notes, no scan needed"
}
