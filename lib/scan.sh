# orgami scan — walk every repo in the org and write map/graph.json.
# Every edge carries file:line evidence. Nothing in the graph is inferred by a model.

NOISE_DOMAINS='github\.com|githubusercontent\.com|githubapp\.com|docker\.io|ghcr\.io|quay\.io|npmjs\.(org|com)|rubygems\.org|pypi\.org|crates\.io|golang\.org|k8s\.io|kubernetes\.io|apache\.org|w3\.org|schema\.org|example\.(com|org)|localhost|\.local$|\.test$|nodejs\.org|python\.org|ubuntu\.com|debian\.org|alpinelinux\.org|letsencrypt\.org|sentry\.io|json-schema\.org'

emit_node() {
  local meta=${4:-}
  [[ -n $meta ]] || meta='{}'
  jq -cn --arg id "$1" --arg kind "$2" --arg name "$3" --argjson meta "$meta" \
    '{t:"node", id:$id, kind:$kind, name:$name, meta:$meta}' >>"$EMIT"
}

emit_edge() {
  jq -cn --arg from "$1" --arg to "$2" --arg kind "$3" --arg evidence "${4-}" \
    '{t:"edge", from:$from, to:$to, kind:$kind, evidence:$evidence}' >>"$EMIT"
}

# emit_tool <repo> <tool> <evidence-file>
emit_tool() {
  emit_node "tool:$2" tool "$2"
  emit_edge "repo:$1" "tool:$2" uses "$3"
}

# Hosts and domains found in a config file, minus registry/vendor noise.
# $4 is the edge kind: deploys-to for deploy targets, reaches for dependencies.
emit_hosts_from() {
  local repo=$1 file=$2 rel=$3 kind=${4:-deploys-to} tok line
  [[ -f $file ]] || return 0
  grep -noE '(\b([0-9]{1,3}\.){3}[0-9]{1,3}\b)|([a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)+\.[a-z]{2,})' "$file" 2>/dev/null |
    while IFS=: read -r line tok; do
      [[ $tok =~ ^(0\.0\.0\.0|127\.0\.0\.1|255\.|1\.0\.0|0\.0\.0)  ]] && continue
      echo "$tok" | grep -qE "$NOISE_DOMAINS" && continue
      [[ $tok =~ ^[0-9.]+$ ]] || [[ $tok == *.* ]] || continue
      emit_node "host:$tok" host "$tok"
      emit_edge "repo:$repo" "host:$tok" "$kind" "$rel:$line"
    done
}

scan_deploy() {
  local repo=$1 src=$2 f

  [[ -d $src/.github/workflows ]] && {
    emit_tool "$repo" github-actions ".github/workflows"
    grep -rhoE 'uses:\s*[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+' "$src/.github/workflows" 2>/dev/null |
      sed 's/uses:\s*//' | sort -u | while read -r action; do
        case $action in
          superfly/*|*flyctl*) emit_tool "$repo" fly ".github/workflows ($action)" ;;
          amondnet/vercel-action|vercel/*) emit_tool "$repo" vercel ".github/workflows ($action)" ;;
          aws-actions/*) emit_tool "$repo" aws ".github/workflows ($action)" ;;
          google-github-actions/*) emit_tool "$repo" gcp ".github/workflows ($action)" ;;
          azure/*) emit_tool "$repo" azure ".github/workflows ($action)" ;;
          docker/build-push-action) emit_tool "$repo" docker-registry ".github/workflows ($action)" ;;
          hashicorp/setup-terraform) emit_tool "$repo" terraform ".github/workflows ($action)" ;;
          appleboy/ssh-action|appleboy/scp-action) emit_tool "$repo" ssh-deploy ".github/workflows ($action)" ;;
        esac
      done
  }

  [[ -f $src/Dockerfile ]] && emit_tool "$repo" docker Dockerfile
  [[ -f $src/.gitlab-ci.yml ]] && emit_tool "$repo" gitlab-ci .gitlab-ci.yml
  [[ -f $src/Jenkinsfile ]] && emit_tool "$repo" jenkins Jenkinsfile
  [[ -f $src/.circleci/config.yml ]] && emit_tool "$repo" circleci .circleci/config.yml
  [[ -f $src/netlify.toml ]] && emit_tool "$repo" netlify netlify.toml
  [[ -f $src/vercel.json ]] && emit_tool "$repo" vercel vercel.json
  [[ -f $src/render.yaml ]] && emit_tool "$repo" render render.yaml
  [[ -f $src/serverless.yml ]] && emit_tool "$repo" serverless serverless.yml
  [[ -f $src/Chart.yaml ]] && emit_tool "$repo" helm Chart.yaml
  [[ -f $src/Procfile ]] && emit_tool "$repo" procfile Procfile
  [[ -f $src/ansible.cfg ]] && emit_tool "$repo" ansible ansible.cfg

  for f in fly.toml; do
    [[ -f $src/$f ]] || continue
    emit_tool "$repo" fly "$f"
    local app
    app=$(grep -m1 -oE '^app\s*=\s*"?[a-z0-9-]+' "$src/$f" | grep -oE '[a-z0-9-]+$' || true)
    [[ -n $app ]] && {
      emit_node "host:$app.fly.dev" host "$app.fly.dev"
      emit_edge "repo:$repo" "host:$app.fly.dev" deploys-to "$f"
    }
  done

  for f in config/deploy.yml deploy.yml .kamal/deploy.yml; do
    [[ -f $src/$f ]] || continue
    grep -q '^servers:' "$src/$f" || continue
    emit_tool "$repo" kamal "$f"
    emit_hosts_from "$repo" "$src/$f" "$f" deploys-to
  done

  if compgen -G "$src/*.tf" >/dev/null || [[ -d $src/terraform ]] || [[ -d $src/infra ]]; then
    local tf
    tf=$(find "$src" -maxdepth 3 -name '*.tf' -not -path '*/.git/*' 2>/dev/null | head -1)
    [[ -n $tf ]] && {
      emit_tool "$repo" terraform "${tf#"$src"/}"
      grep -rhoE 'provider\s+"[a-z0-9_]+"' "$src" --include='*.tf' 2>/dev/null |
        grep -oE '"[a-z0-9_]+"' | tr -d '"' | sort -u | while read -r p; do
          emit_tool "$repo" "$p" "terraform provider"
        done
    }
  fi

  local kf
  kf=$(grep -rlE '^kind:\s*(Deployment|StatefulSet|Ingress)' "$src" \
    --include='*.yaml' --include='*.yml' 2>/dev/null | head -1 || true)
  [[ -n $kf ]] && {
    emit_tool "$repo" kubernetes "${kf#"$src"/}"
    grep -rhoE '^\s+host:\s*[a-z0-9.-]+' "$src" --include='*.yaml' --include='*.yml' 2>/dev/null |
      grep -oE '[a-z0-9.-]+$' | sort -u | while read -r h; do
        echo "$h" | grep -qE "$NOISE_DOMAINS" && continue
        [[ $h == *.* ]] || continue
        emit_node "host:$h" host "$h"
        emit_edge "repo:$repo" "host:$h" deploys-to "kubernetes ingress"
      done
  }

  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [[ -f $src/$f ]] || continue
    emit_tool "$repo" docker-compose "$f"
    grep -oE '^\s+image:\s*\S+' "$src/$f" | awk '{print $2}' | tr -d '"' |
      sed 's/:.*//' | sort -u | while read -r img; do
        local base=${img##*/}
        case $base in
          postgres|postgis|mysql|mariadb|redis|valkey|mongo|rabbitmq|kafka|elasticsearch|opensearch|clickhouse|minio|memcached|nats|meilisearch|typesense|qdrant)
            emit_node "service:$base" service "$base"
            emit_edge "repo:$repo" "service:$base" depends-on "$f"
            ;;
        esac
      done
    break
  done

  for f in .env.example .env.sample .env.template config/.env.example; do
    [[ -f $src/$f ]] || continue
    grep -oE '^[A-Z0-9_]*(POSTGRES|DATABASE|REDIS|MONGO|ELASTIC|RABBIT|KAFKA|S3|SMTP)[A-Z0-9_]*=' "$src/$f" |
      tr -d '=' | sort -u | while read -r v; do
        local kind
        kind=$(echo "$v" | grep -oE 'POSTGRES|DATABASE|REDIS|MONGO|ELASTIC|RABBIT|KAFKA|S3|SMTP' | head -1 |
          tr 'A-Z' 'a-z')
        emit_node "service:$kind" service "$kind"
        emit_edge "repo:$repo" "service:$kind" depends-on "$f ($v)"
      done
    emit_hosts_from "$repo" "$src/$f" "$f" reaches
  done
}

# Repo-to-repo edges: explicit references only.
scan_links() {
  local repo=$1 src=$2 other rel line
  while read -r other; do
    [[ -z $other || $other == "$repo" ]] && continue
    local hit
    hit=$(grep -rn --binary-files=without-match \
      -e "github\.com[:/]$ORG/$other\b" \
      -e "ghcr\.io/$ORG/$other\b" \
      -e "@$ORG/$other\b" \
      "$src" \
      --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor \
      --exclude-dir=dist --exclude-dir=build --exclude='*.lock' --exclude='*.sum' \
      2>/dev/null | head -1 || true)
    if [[ -z $hit ]]; then
      # A dependency manifest naming the repo counts, but only for names long
      # enough not to collide with an ordinary word.
      [[ ${#other} -ge 4 ]] || continue
      local mf
      for mf in Gemfile go.mod package.json requirements.txt pyproject.toml \
        Cargo.toml composer.json mix.exs; do
        [[ -f $src/$mf ]] || continue
        hit=$(grep -nw -- "$other" "$src/$mf" 2>/dev/null | head -1) || true
        [[ -n $hit ]] && { hit="$src/$mf:$hit"; break; }
      done
    fi
    [[ -n $hit ]] || continue
    rel=${hit%%:*}
    rel=${rel#"$src"/}
    line=$(echo "$hit" | cut -d: -f2)
    emit_edge "repo:$repo" "repo:$other" references "$rel:$line"
  done <"$REPOLIST"
}

# One repo, start to finish, into its own emit file. Safe to run in parallel.
scan_repo() {
  local repo=$1
  local src="$DIR/cache/src/$repo"
  EMIT="$EMITDIR/e-$repo.ndjson"
  : >"$EMIT"

  if [[ -d $src/.git ]]; then
    git -C "$src" fetch --depth "$DEPTH" --quiet origin 2>/dev/null &&
      git -C "$src" reset --hard --quiet FETCH_HEAD 2>/dev/null || true
  else
    gh repo clone "$ORG/$repo" "$src" -- --depth "$DEPTH" --single-branch --quiet 2>/dev/null || {
      echo "$repo" >>"$EMITDIR/failed"
      : >"$EMITDIR/done/$repo"
      return 0
    }
  fi

  local meta lang
  meta=$(jq -c --arg r "$repo" '.[] | select(.name == $r)
         | {language, description, private, pushed_at, topics,
            url: .html_url, size_kb: .size}' "$REPOSJSON")
  emit_node "repo:$repo" repo "$repo" "$meta"

  lang=$(jq -r '.language // empty' <<<"$meta")
  [[ -n $lang ]] && {
    emit_node "lang:$lang" lang "$lang"
    emit_edge "repo:$repo" "lang:$lang" written-in ""
  }

  scan_deploy "$repo" "$src"
  scan_links "$repo" "$src"
  : >"$EMITDIR/done/$repo"
}

scan_draw() {
  local done=$1 total=$2 cols width filled pct f="" e="" i
  cols=$(tput cols 2>/dev/null || echo 80)
  width=$((cols - 30))
  ((width > 44)) && width=44
  ((width < 8)) && width=8
  ((total > 0)) || total=1
  filled=$((done * width / total))
  pct=$((done * 100 / total))
  for ((i = 0; i < filled; i++)); do f+="█"; done
  for ((i = filled; i < width; i++)); do e+="░"; done
  printf '\r\033[2K  \033[38;5;12m%s\033[38;5;238m%s\033[0m  %3d%%  %d/%d repos' \
    "$f" "$e" "$pct" "$done" "$total" >&2
}

scan_progress() {
  local total=$1 pid=$2 done
  while kill -0 "$pid" 2>/dev/null; do
    done=$(find "$EMITDIR/done" -type f 2>/dev/null | wc -l)
    scan_draw "$done" "$total"
    sleep 0.25
  done
  scan_draw "$(find "$EMITDIR/done" -type f 2>/dev/null | wc -l)" "$total"
  printf '\n' >&2
}

cmd_scan() {
  load_company
  need gh
  need git

  local only="" depth=1 jobs=8
  while [[ $# -gt 0 ]]; do
    case $1 in
      --only) only=$2; shift 2 ;;
      --depth) depth=$2; shift 2 ;;
      --jobs | -j) jobs=$2; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  local repos="$DIR/cache/repos/list.json"
  log "listing repos in $ORG"
  gh api "orgs/$ORG/repos?per_page=100&type=all" --paginate \
    --jq '[.[] | {name, description, language, archived, private, fork,
                  pushed_at, default_branch, topics, html_url,
                  size, open_issues_count}]' |
    jq -s 'add' >"$repos"

  local excl incl
  excl=$(jq -c '.exclude // []' "$DIR/config.json")
  incl=$(jq -c '.include // []' "$DIR/config.json")

  REPOLIST=$(mktemp)
  jq -r --argjson excl "$excl" --argjson incl "$incl" \
    '.[] | select(.archived | not) | select(.fork | not)
     | .name
     | select(($incl | length) == 0 or (. as $n | $incl | index($n)))
     | select([. as $n | $excl[] | select($n | test(.))] | length == 0)' \
    "$repos" >"$REPOLIST"

  [[ -n $only ]] && echo "$only" >"$REPOLIST"

  local total
  total=$(grep -c . "$REPOLIST" || true)
  [[ $total -gt 0 ]] || die "no repositories to scan in $ORG"
  ((jobs > total)) && jobs=$total
  log "$total active repos"

  EMITDIR=$(mktemp -d)
  mkdir -p "$EMITDIR/done"
  : >"$EMITDIR/failed"
  DEPTH=$depth
  REPOSJSON=$repos
  export EMITDIR DEPTH ORG DIR REPOLIST REPOSJSON NOISE_DOMAINS
  export -f scan_repo scan_deploy scan_links emit_node emit_edge emit_tool emit_hosts_from

  xargs -a "$REPOLIST" -P "$jobs" -I{} bash -c 'scan_repo "$1"' _ {} &
  local xpid=$!
  if [[ -t 2 ]]; then
    scan_progress "$total" "$xpid"
  fi
  wait "$xpid" 2>/dev/null || true

  local failed
  failed=$(grep -c . "$EMITDIR/failed" || true)
  [[ $failed -gt 0 ]] &&
    log "could not clone: $(tr '\n' ' ' <"$EMITDIR/failed")"

  local out="$DIR/map/graph.json"
  find "$EMITDIR" -name 'e-*.ndjson' -exec cat {} + |
    jq -s --arg company "$COMPANY" --arg org "$ORG" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{company: $company, org: $org, generated: $at,
        nodes: ([.[] | select(.t == "node") | del(.t)]
                | group_by(.id) | map(.[0] + {meta: (map(.meta) | add)})),
        edges: ([.[] | select(.t == "edge") | del(.t)] | unique)}' \
      >"$out"

  rm -rf "$EMITDIR"
  rm -f "$REPOLIST"
  echo "$out  ($(jq '.nodes | length' "$out") nodes, $(jq '.edges | length' "$out") edges)"
}
