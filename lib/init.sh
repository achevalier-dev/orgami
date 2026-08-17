# orgami init / use / list — one directory per company.

cmd_init() {
  local company="" org="" docs_repo="" docs_path="orgami"
  company=${1:-}
  shift || true
  while [[ $# -gt 0 ]]; do
    case $1 in
      --org) org=$2; shift 2 ;;
      --docs-repo) docs_repo=$2; shift 2 ;;
      --docs-path) docs_path=$2; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  [[ -n $company ]] || die "usage: orgami init <company> --org <github-org> [--docs-repo <url>]"
  [[ -n $org ]] || die "--org is required (the GitHub organization login)"

  gh api "orgs/$org" >/dev/null 2>&1 ||
    die "cannot read org '$org' with the current gh token — check: gh auth status"

  local dir
  dir=$(company_dir "$company")
  [[ -f $dir/config.json ]] && die "'$company' already exists at $dir"
  mkdir -p "$dir"/{cache/prs,cache/repos,cache/src,reports,map}

  jq -n \
    --arg company "$company" \
    --arg org "$org" \
    --arg docs_repo "$docs_repo" \
    --arg docs_path "$docs_path" \
    '{company: $company, org: $org, docs_repo: $docs_repo, docs_path: $docs_path,
      exclude: [], include: [], report_model: "claude-sonnet-5"}' \
    >"$dir/config.json"

  mkdir -p "$ORGAMI_HOME"
  [[ -f $ORGAMI_HOME/config.json ]] || echo '{}' >"$ORGAMI_HOME/config.json"
  local tmp
  tmp=$(mktemp)
  jq --arg c "$company" '.default = (.default // $c)' "$ORGAMI_HOME/config.json" >"$tmp"
  mv "$tmp" "$ORGAMI_HOME/config.json"

  echo "created $dir"
  echo "next: orgami pull && orgami scan"
}

cmd_use() {
  local company=${1:-}
  [[ -n $company ]] || die "usage: orgami use <company>"
  [[ -f $(company_dir "$company")/config.json ]] || die "unknown company '$company' — orgami list"
  local tmp
  tmp=$(mktemp)
  [[ -f $ORGAMI_HOME/config.json ]] || echo '{}' >"$ORGAMI_HOME/config.json"
  jq --arg c "$company" '.default = $c' "$ORGAMI_HOME/config.json" >"$tmp"
  mv "$tmp" "$ORGAMI_HOME/config.json"
  echo "default company: $company"
}

cmd_list() {
  local default=""
  [[ -f $ORGAMI_HOME/config.json ]] && default=$(jq -r '.default // ""' "$ORGAMI_HOME/config.json")
  local c org
  while read -r c; do
    [[ -n $c ]] || continue
    org=$(jq -r '.org' "$(company_dir "$c")/config.json")
    if [[ $c == "$default" ]]; then
      printf '* %-20s %s\n' "$c" "$org"
    else
      printf '  %-20s %s\n' "$c" "$org"
    fi
  done < <(companies)
}

# orgami claude-project — remember the Claude Project that reads the docs repo,
# so the published front page can link straight to it.
cmd_claude_project() {
  load_company
  local url=${1:-}

  if [[ -z $url ]]; then
    url=$(cfg claude_project)
    [[ -n $url ]] || die "no Claude project saved — orgami claude-project <url>"
    echo "$url"
    return 0
  fi

  [[ $url =~ ^https://claude\.ai/project/[A-Za-z0-9-]+ ]] ||
    die "that is not a Claude project link — open the project and copy the address bar"

  local tmp
  tmp=$(mktemp)
  jq --arg u "$url" '.claude_project = $u' "$DIR/config.json" >"$tmp"
  mv "$tmp" "$DIR/config.json"
  echo "saved for $COMPANY — it will appear on the front page at the next publish"
}
