# orgami publish — commit the reports and the map into the configured docs repo.

cmd_publish() {
  load_company
  need git

  local yes=0 dry=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --yes|-y) yes=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  local repo path
  repo=$(cfg docs_repo)
  path=$(cfg docs_path orgami)
  [[ -n $repo ]] || die "no docs_repo in $DIR/config.json — set it, or read the files in $DIR"

  local work="$DIR/cache/docs"
  if [[ -d $work/.git ]]; then
    git -C "$work" fetch --quiet origin
    git -C "$work" reset --hard --quiet "origin/$(git -C "$work" rev-parse --abbrev-ref origin/HEAD | sed 's|origin/||')"
  else
    git clone --quiet --depth 1 "$repo" "$work" || die "cannot clone $repo"
  fi

  local dest="$work/$path"
  mkdir -p "$dest/reports"
  cp -f "$DIR/reports/"*.md "$dest/reports/" 2>/dev/null || true
  cp -f "$DIR/map/ARCHITECTURE.md" "$dest/" 2>/dev/null || true
  cp -f "$DIR/map/graph.json" "$dest/" 2>/dev/null || true

  if [[ -z $(git -C "$work" status --porcelain) ]]; then
    echo "nothing to publish — docs repo already matches"
    return
  fi

  git -C "$work" add -A "$path"
  echo "changes to publish in $repo:$path"
  git -C "$work" --no-pager diff --cached --stat

  [[ $dry == 1 ]] && { git -C "$work" reset --quiet; return; }

  if [[ $yes == 0 ]]; then
    read -rp "push to $repo? [y/N] " ans
    [[ ${ans,,} == y* ]] || { git -C "$work" reset --quiet; die "aborted"; }
  fi

  local msg
  msg="docs(orgami): $COMPANY $(iso_week) recap and map"
  git -C "$work" commit --quiet -m "$msg"
  git -C "$work" push --quiet origin HEAD
  echo "pushed: $msg"
}

# orgami weekly — the whole loop, for the systemd timer.
cmd_weekly() {
  load_company
  cmd_pull --last 0
  cmd_report
  cmd_scan
  cmd_doc
  if [[ -n $(cfg docs_repo) ]]; then
    cmd_publish --yes
  else
    log "no docs_repo configured — report left in $DIR/reports"
  fi
}
