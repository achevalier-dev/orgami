# What a repo *is*, read off its committed files: framework, how to run it,
# what configuration it reads, what it serves, what it calls, what it already
# tells agents. Written per repo during the scan, rendered into cards by `doc`.

PROFILE_EXCL=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor
  --exclude-dir=dist --exclude-dir=build --exclude-dir=.next --exclude-dir=out
  --exclude-dir=coverage --exclude-dir=__pycache__ --exclude-dir=.venv
  --exclude-dir=venv --exclude-dir=target --exclude-dir=Pods
  --exclude=*.lock --exclude=*.sum --exclude=*.min.js --exclude=*.map)

# Env vars that say nothing about the system.
ENV_NOISE='^(NODE_ENV|ENV|ENVIRONMENT|PORT|HOST|DEBUG|LOG_LEVEL|TZ|HOME|PATH|USER|PWD|CI|npm_.*|NEXT_RUNTIME|VERCEL.*)$'

profile_framework() {
  local src=$1 pkg="$src/package.json" out=()
  if [[ -f $pkg ]]; then
    local deps
    deps=$(jq -r '[(.dependencies // {}), (.devDependencies // {})] | add // {} | keys[]' "$pkg" 2>/dev/null || true)
    grep -qx 'next' <<<"$deps" && out+=("Next.js")
    grep -qx '@nestjs/core' <<<"$deps" && out+=("NestJS")
    grep -qx 'express' <<<"$deps" && out+=("Express")
    grep -qx 'fastify' <<<"$deps" && out+=("Fastify")
    grep -qx 'koa' <<<"$deps" && out+=("Koa")
    grep -qx 'parse-server' <<<"$deps" && out+=("Parse Server")
    grep -qx 'parse' <<<"$deps" && out+=("Parse SDK")
    grep -qx 'react-native' <<<"$deps" && out+=("React Native")
    grep -qx 'expo' <<<"$deps" && out+=("Expo")
    grep -qx 'react' <<<"$deps" && [[ ${#out[@]} -eq 0 ]] && out+=("React")
    grep -qx 'vue' <<<"$deps" && out+=("Vue")
    grep -qx 'svelte' <<<"$deps" && out+=("Svelte")
    grep -qx 'agenda' <<<"$deps" && out+=("Agenda jobs")
    grep -qx 'bullmq\|bull' <<<"$deps" && out+=("Bull queue")
    grep -qx 'serverless' <<<"$deps" && out+=("Serverless")
  fi
  [[ -f $src/manage.py ]] && out+=("Django")
  grep -rqlE '^from fastapi import|FastAPI\(' "$src" --include='*.py' "${PROFILE_EXCL[@]}" 2>/dev/null && out+=("FastAPI")
  grep -rqlE '^from flask import|Flask\(__name__\)' "$src" --include='*.py' "${PROFILE_EXCL[@]}" 2>/dev/null && out+=("Flask")
  [[ -f $src/config/routes.rb ]] && out+=("Rails")
  [[ -f $src/go.mod ]] && out+=("Go module")
  [[ -f $src/Cargo.toml ]] && out+=("Cargo crate")
  [[ -f $src/pubspec.yaml ]] && out+=("Flutter")
  [[ -d $src/ios && -d $src/android ]] && out+=("Mobile app")

  printf '%s\n' "${out[@]:-}" | grep -v '^$' | sort -u | jq -Rn '[inputs]'
}

profile_commands() {
  local src=$1
  local pkg="$src/package.json" cmds='{}'

  if [[ -f $pkg ]]; then
    cmds=$(jq -c '(.scripts // {})
      | with_entries(select(.key | test("^(dev|start|build|test|lint|typecheck|migrate|seed|e2e)")))
      | to_entries | .[0:8] | from_entries' "$pkg" 2>/dev/null || echo '{}')
  fi

  if [[ -f $src/Makefile ]]; then
    local targets
    targets=$(grep -oE '^[a-z][a-z0-9_-]*:' "$src/Makefile" | tr -d ':' |
      grep -E '^(dev|run|start|build|test|lint|check|setup|install|migrate)$' | head -6 || true)
    [[ -n $targets ]] && cmds=$(jq -c --argjson t "$(jq -Rn '[inputs]' <<<"$targets")" \
      '. + ($t | map({(.): ("make " + .)}) | add // {})' <<<"$cmds")
  fi
  local b
  for b in setup dev test start console migrate; do
    [[ -x $src/bin/$b ]] && cmds=$(jq -c --arg k "$b" --arg v "bin/$b" '.[$k] //= $v' <<<"$cmds")
  done

  local pm=""
  [[ -f $src/pnpm-lock.yaml ]] && pm=pnpm
  [[ -z $pm && -f $src/yarn.lock ]] && pm=yarn
  [[ -z $pm && -f $src/package-lock.json ]] && pm=npm
  [[ -z $pm && -f $src/Gemfile ]] && pm=bundler
  [[ -z $pm && -f $src/poetry.lock ]] && pm=poetry
  [[ -z $pm && -f $src/requirements.txt ]] && pm=pip
  [[ -z $pm && -f $src/go.mod ]] && pm=go
  [[ -z $pm && -f $src/Cargo.toml ]] && pm=cargo

  local runtime=""
  [[ -f $src/.nvmrc ]] && runtime="node $(tr -d 'v \n' <"$src/.nvmrc" | head -c 12)"
  [[ -z $runtime && -f $pkg ]] && runtime=$(jq -r '.engines.node // empty | if . == "" then empty else "node " + . end' "$pkg" 2>/dev/null || true)
  [[ -z $runtime && -f $src/.python-version ]] && runtime="python $(head -1 "$src/.python-version")"
  [[ -z $runtime && -f $src/.ruby-version ]] && runtime="ruby $(head -1 "$src/.ruby-version")"
  [[ -z $runtime && -f $src/go.mod ]] && runtime=$(grep -m1 '^go ' "$src/go.mod" | sed 's/^go /go /' || true)

  local procfile="[]"
  [[ -f $src/Procfile ]] &&
    procfile=$(grep -oE '^[a-z]+:' "$src/Procfile" | tr -d ':' | jq -Rn '[inputs]')

  jq -n --argjson scripts "$cmds" --arg pm "$pm" --arg runtime "$runtime" \
    --argjson procs "$procfile" \
    '{scripts: $scripts, package_manager: $pm, runtime: $runtime, procfile: $procs}'
}

profile_env() {
  local src=$1
  {
    grep -rhoE 'process\.env\.[A-Z][A-Z0-9_]{2,}' "$src" "${PROFILE_EXCL[@]}" 2>/dev/null |
      sed 's/process\.env\.//'
    grep -rhoE "os\.environ(\.get)?[\[(]['\"][A-Z][A-Z0-9_]{2,}" "$src" --include='*.py' "${PROFILE_EXCL[@]}" 2>/dev/null |
      grep -oE "[A-Z][A-Z0-9_]{2,}$"
    grep -rhoE "ENV\[['\"][A-Z][A-Z0-9_]{2,}" "$src" --include='*.rb' "${PROFILE_EXCL[@]}" 2>/dev/null |
      grep -oE "[A-Z][A-Z0-9_]{2,}$"
    for f in .env.example .env.sample .env.template; do
      [[ -f $src/$f ]] && grep -oE '^[A-Z][A-Z0-9_]{2,}=' "$src/$f" | tr -d '='
    done
  } 2>/dev/null | sort -u | grep -vE "$ENV_NOISE" | head -60 | jq -Rn '[inputs]'
}

# Endpoints this repo serves, with the file they were found in.
profile_routes() {
  local src=$1
  {
    # Only the server side: app/router/server verbs. An axios or fetch call
    # uses the same shape and would otherwise look like a route it serves.
    grep -rnoE "\b(app|router|server|routes)\.(get|post|put|patch|delete)\(\s*['\"\`][^'\"\`]{1,60}" "$src" \
      --include='*.js' --include='*.ts' "${PROFILE_EXCL[@]}" 2>/dev/null |
      sed -E "s|^$src/||; s/\b(app|router|server|routes)\.(get|post|put|patch|delete)\(\s*['\"\`]/ \U\2\E /" |
      grep -E ' (GET|POST|PUT|PATCH|DELETE) ' || true

    grep -rnoE "@(Get|Post|Put|Patch|Delete|Controller)\(\s*['\"][^'\"]{0,60}" "$src" \
      --include='*.ts' "${PROFILE_EXCL[@]}" 2>/dev/null |
      sed -E "s|^$src/||; s/@([A-Za-z]+)\(\s*['\"]/ \U\1\E /" || true

    grep -rnoE "Parse\.Cloud\.(define|job)\(\s*['\"][^'\"]{1,60}" "$src" \
      --include='*.js' --include='*.ts' "${PROFILE_EXCL[@]}" 2>/dev/null |
      sed -E "s|^$src/||; s/Parse\.Cloud\.(define|job)\(\s*['\"]/ CLOUD /" || true

    grep -rnoE "@(app|router|blueprint)\.(route|get|post|put|patch|delete)\(\s*['\"][^'\"]{1,60}" "$src" \
      --include='*.py' "${PROFILE_EXCL[@]}" 2>/dev/null |
      sed -E "s|^$src/||; s/@[a-z_]+\.([a-z]+)\(\s*['\"]/ \U\1\E /" || true

    if [[ -d $src/pages/api ]]; then
      find "$src/pages/api" -type f \( -name '*.ts' -o -name '*.js' -o -name '*.tsx' \) 2>/dev/null |
        sed -E "s|^$src/||" | while read -r f; do
          echo "$f:1 ROUTE /$(sed -E 's|^pages/||; s|\.[jt]sx?$||; s|/index$||' <<<"$f")"
        done
    fi
    if [[ -d $src/app ]]; then
      find "$src/app" -type f -name 'route.ts' -o -path "$src/app/*" -name 'route.js' 2>/dev/null |
        sed -E "s|^$src/||" | while read -r f; do
          echo "$f:1 ROUTE /$(sed -E 's|^app/||; s|/route\.[jt]s$||' <<<"$f")"
        done
    fi

    [[ -f $src/config/routes.rb ]] &&
      grep -nE '^\s*(get|post|put|patch|delete|resources)\s' "$src/config/routes.rb" |
      sed -E "s|^|config/routes.rb:|" || true
  } 2>/dev/null | sed 's/[[:space:]]\+/ /g' | sort -u | head -40 | jq -Rn '[inputs]'
}

# Hosts this repo reaches out to, from literal URLs in source.
profile_calls() {
  local src=$1
  grep -rhoE 'https?://[a-zA-Z0-9._-]+' "$src" \
    --include='*.js' --include='*.ts' --include='*.jsx' --include='*.tsx' \
    --include='*.py' --include='*.rb' --include='*.go' --include='*.env*' \
    --include='*.yml' --include='*.yaml' --include='*.json' \
    "${PROFILE_EXCL[@]}" 2>/dev/null |
    sed -E 's|https?://||' | sort -u |
    grep -vE "$NOISE_DOMAINS" |
    grep -vE '^(localhost|127\.0\.0\.1|0\.0\.0\.0|example\.)' |
    head -40 | jq -Rn '[inputs]'
}

# How this repo ships: one entry per workflow, with what triggers it and which
# of them actually deploy. A repo with no deploying workflow is a fact worth
# stating in a runbook, not a gap to paper over.
profile_workflows() {
  local src=$1 dir="$src/.github/workflows" f name triggers env actions deploys
  [[ -d $dir ]] || { echo '[]'; return 0; }

  {
    for f in "$dir"/*.yml "$dir"/*.yaml; do
      [[ -f $f ]] || continue
      name=$(grep -m1 -E '^name:' "$f" | sed -E 's/^name:\s*//; s/^["'"'"']//; s/["'"'"']$//' || true)
      [[ -n $name ]] || name=$(basename "$f")

      triggers=$(grep -oE '^\s{0,4}(push|pull_request|workflow_dispatch|schedule|release|workflow_call|repository_dispatch):' "$f" |
        tr -d ' :' | sort -u | paste -sd, - || true)

      env=$(grep -m1 -oE '^\s+environment:\s*\S+' "$f" | awk '{print $2}' | tr -d '"' || true)

      actions=$(grep -ohE 'uses:\s*[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+' "$f" |
        sed -E 's/uses:\s*//' | sort -u | head -6 | paste -sd, - || true)

      # A workflow deploys if it says so in its name, or if it uses an action
      # that only exists to deploy. Merely touching aws-actions is not enough —
      # every test job configures credentials too.
      deploys=false
      if grep -qiE '(^|[-_/])(deploy|release|publish|ship)' <<<"$(basename "$f") $name"; then
        deploys=true
      elif grep -qE 'uses:\s*(akhileshns/heroku-deploy|superfly/flyctl-actions|amondnet/vercel-action|vercel/action|aws-actions/amazon-ecs-deploy-task-definition|JamesIves/github-pages-deploy-action|peaceiris/actions-gh-pages|appleboy/ssh-action|serverless/github-action)' "$f"; then
        deploys=true
      fi

      jq -n --arg file ".github/workflows/$(basename "$f")" --arg name "$name" \
        --arg on "$triggers" --arg env "$env" --arg actions "$actions" \
        --argjson deploys "$deploys" \
        '{file: $file, name: $name, deploys: $deploys,
          on: ($on | split(",") | map(select(. != ""))),
          environment: $env,
          actions: ($actions | split(",") | map(select(. != "")))}'
    done
  } 2>/dev/null | jq -s '.'
}

# Hosts this repo declares as its own — the other half of who-calls-whom.
profile_serves() {
  local src=$1 f
  {
    [[ -f $src/CNAME ]] && head -3 "$src/CNAME"
    [[ -f $src/public/CNAME ]] && head -3 "$src/public/CNAME"
    [[ -f $src/vercel.json ]] &&
      jq -r '(.alias // []) | if type == "array" then .[] else . end' "$src/vercel.json" 2>/dev/null
    for f in .env.example .env.sample .env.template; do
      [[ -f $src/$f ]] || continue
      grep -oE '^[A-Z0-9_]*(SELF|PUBLIC|SITE|APP|BASE|SERVER|FRONTEND|CLIENT)[A-Z0-9_]*_URL=\S+' "$src/$f" |
        sed -E 's|^[^=]+=||; s|https?://||; s|[/:].*$||'
    done
    [[ -f $src/app.json ]] &&
      jq -r '.name // empty | if . == "" then empty else . + ".herokuapp.com" end' "$src/app.json" 2>/dev/null
  } 2>/dev/null |
    tr -d '"\r' | grep -vE '^\s*$' |
    grep -E '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-z]{2,}$' |
    grep -vE "$NOISE_DOMAINS" | sort -u | head -10 | jq -Rn '[inputs]'
}

profile_docs() {
  local src=$1 f out=()
  for f in AGENTS.md CLAUDE.md CONTRIBUTING.md ARCHITECTURE.md docs/ARCHITECTURE.md \
    .cursorrules .github/copilot-instructions.md; do
    [[ -f $src/$f ]] && out+=("$f")
  done
  printf '%s\n' "${out[@]:-}" | grep -v '^$' | jq -Rn '[inputs]'
}

# Writes one profile JSON for a repo. $1 repo, $2 checkout, $3 the repo's meta.
profile_repo() {
  local repo=$1 src=$2 meta=$3
  jq -n \
    --arg name "$repo" \
    --argjson meta "$meta" \
    --argjson frameworks "$(profile_framework "$src")" \
    --argjson commands "$(profile_commands "$src")" \
    --argjson env "$(profile_env "$src")" \
    --argjson routes "$(profile_routes "$src")" \
    --argjson calls "$(profile_calls "$src")" \
    --argjson serves "$(profile_serves "$src")" \
    --argjson workflows "$(profile_workflows "$src")" \
    --argjson docs "$(profile_docs "$src")" \
    '{name: $name, meta: $meta, frameworks: $frameworks, commands: $commands,
      env: $env, routes: $routes, calls: $calls, serves: $serves,
      workflows: $workflows, agent_docs: $docs}' \
    >"$EMITDIR/p-$repo.json"
}
