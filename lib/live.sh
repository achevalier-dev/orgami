# shellcheck shell=bash
# orgami live — what is actually running, read from the providers' own APIs.
#
# This is deliberately not part of `orgami scan`. The graph is committed
# evidence: every edge carries a file:line anyone on the team can open, and two
# people scanning the same org get the same map. A reading taken from a cloud
# account is none of those things — it expires, it needs credentials not
# everyone has, and it cannot be checked after the fact. So it lives in its own
# file, carries its own timestamp, and says which account it came from.
#
# Names and endpoints only. No environment variable values, no secrets, no
# parameter contents — this file is publishable, and one day someone will.

LIVE_STALE_DAYS=7

# The tag keys a resource may use to name the repository it was built from.
LIVE_REPO_TAGS='Repository|repository|Repo|repo|github:repo|GitHubRepo'

live_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- matching -----------------------------------------------------------------
# A row is only attached to a repo when something says so. Three things can:
# the provider's own git link, an app name the map already ties to a repo, or a
# name that is exactly a repo name. Anything else stays unmatched and is
# reported as such, because a wrong attribution is worse than a missing one.

live_repo_exists() {
  jq -e --arg r "$1" 'any(.[]; .name == $r)' "$DIR/map/repos.json" >/dev/null 2>&1
}

# The repo of exactly this name, whatever its capitalisation — GitHub treats
# `WinIt-backend` and `winit-backend` as the same name, so a provider that
# lowercased it has still named the repository. Anything less than the whole
# name is not a match: `winit-backend-dev` is not `WinIt-backend`.
live_repo_named() {
  jq -re --arg n "$1" '[.[] | select((.name | ascii_downcase) == ($n | ascii_downcase)) | .name]
                       | if length == 1 then .[0] else empty end' \
    "$DIR/map/repos.json" 2>/dev/null
}

# The repo the map already says deploys to this host, if exactly one does.
live_repo_for_host() {
  local host=$1 g="$DIR/map/graph.json"
  [[ -f $g ]] || return 1
  jq -re --arg h "host:$host" \
    '[.edges[] | select(.to == $h and .kind == "deploys-to") | .from | sub("^repo:"; "")]
     | unique | if length == 1 then .[0] else empty end' "$g" 2>/dev/null
}

# --- providers ----------------------------------------------------------------
# Each writes ndjson rows to $LIVE_ROWS and never exits the run: a provider the
# machine cannot reach is an error on the report, not a failed command.

# Recorded, not printed: cmd_live reports every error once, at the end.
live_err() {
  jq -cn --arg p "$1" --arg m "$2" '{provider:$p, message:$m}' >>"$LIVE_ERRORS"
}

live_row() { cat >>"$LIVE_ROWS"; }

# Fly. `flyctl apps list --json` is the whole inventory in one call. Field
# names have changed case across flyctl versions, so every read has a fallback.
live_fly() {
  local bin
  bin=$(command -v flyctl || command -v fly || true)
  [[ -n $bin ]] || { live_err fly "flyctl is not on PATH"; return 0; }

  local out
  out=$("$bin" apps list --json 2>&1) || {
    live_err fly "$(head -1 <<<"$out")"
    return 0
  }
  jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 || {
    live_err fly "unexpected output from 'flyctl apps list --json'"
    return 0
  }

  local name status org repo match host
  while IFS=$'\t' read -r name status org; do
    [[ -n $name ]] || continue
    host="$name.fly.dev"
    match=""
    repo=$(live_repo_for_host "$host" 2>/dev/null || true)
    [[ -n $repo ]] && match="map"
    if [[ -z $repo ]]; then
      repo=$(live_repo_named "$name" || true)
      [[ -n $repo ]] && match="name"
    fi

    jq -cn --arg provider fly --arg name "$name" --arg repo "$repo" \
      --arg match "$match" --arg state "$status" --arg url "$host" \
      --arg account "$org" --arg source "fly:app/$name" \
      '{provider:$provider, name:$name,
        repo:(if $repo == "" then null else $repo end),
        match:(if $match == "" then null else $match end),
        state:(if $state == "" then null else $state end),
        urls:(if $url == "" then [] else [$url] end),
        account:(if $account == "" then null else $account end),
        updated:null,
        source:$source}' | live_row
  done < <(jq -r '.[] | [(.Name // .name // ""),
                         (.Status // .status // ""),
                         (.Organization.Slug // .organization.slug // .Org // "")] | @tsv' <<<"$out")
}

# Vercel. The CLI prints tables, not JSON, and the field that matters — which
# GitHub repository a project is linked to — is only in the REST API. So this
# one wants a token: VERCEL_TOKEN, and VERCEL_TEAM_ID when the projects live
# under a team rather than a personal account.
live_vercel() {
  local token=${VERCEL_TOKEN:-}
  [[ -n $token ]] || {
    live_err vercel "VERCEL_TOKEN is not set (vercel.com/account/tokens)"
    return 0
  }
  need curl

  local team=${VERCEL_TEAM_ID:-} url next body page=0
  url="https://api.vercel.com/v9/projects?limit=100"
  [[ -n $team ]] && url="$url&teamId=$team"

  while :; do
    body=$(curl -sS --max-time 30 -H "Authorization: Bearer $token" "$url" 2>&1) || {
      live_err vercel "$(head -1 <<<"$body")"
      return 0
    }
    if jq -e '.error' <<<"$body" >/dev/null 2>&1; then
      live_err vercel "$(jq -r '.error.message // "request rejected"' <<<"$body")"
      return 0
    fi
    jq -e '.projects | type == "array"' <<<"$body" >/dev/null 2>&1 || {
      live_err vercel "unexpected response from api.vercel.com"
      return 0
    }

    local name linked state updated aliases repo match
    while IFS=$'\t' read -r name linked state updated aliases; do
      [[ -n $name ]] || continue
      repo=""; match=""
      if [[ -n $linked ]] && live_repo_exists "$linked"; then repo=$linked; match="link"; fi
      if [[ -z $repo ]]; then
        repo=$(live_repo_named "$name" || true)
        [[ -n $repo ]] && match="name"
      fi

      jq -cn --arg provider vercel --arg name "$name" --arg repo "$repo" \
        --arg match "$match" --arg state "$state" --arg updated "$updated" \
        --arg aliases "$aliases" --arg account "${team:-personal}" \
        --arg source "vercel:project/$name" \
        '{provider:$provider, name:$name,
          repo:(if $repo == "" then null else $repo end),
          match:(if $match == "" then null else $match end),
          state:(if $state == "" then null else $state end),
          urls:($aliases | split(",") | map(select(. != ""))),
          account:$account,
          updated:(if $updated == "" then null else $updated end),
          source:$source}' | live_row
    done < <(jq -r --arg org "$ORG" '
      .projects[]
      | (.targets.production // {}) as $p
      | [.name,
         (if (.link.org // "") == $org then (.link.repo // "") else "" end),
         ($p.readyState // ""),
         (if ($p.createdAt // null) == null then ""
          else (($p.createdAt / 1000) | todate) end),
         (($p.alias // []) | join(","))] | @tsv' <<<"$body")

    next=$(jq -r '.pagination.next // empty' <<<"$body")
    [[ -n $next ]] || break
    page=$((page + 1))
    ((page < 20)) || break
    url="https://api.vercel.com/v9/projects?limit=100&until=$next"
    [[ -n $team ]] && url="$url&teamId=$team"
  done
}

# AWS. Nothing in an AWS account records which repository built a resource, so
# this reader enumerates what is running and then attributes only what something
# names: a tag, a host the map already points at, or a whole repo name.
#
# It does not go through the tagging API alone. That API returns only resources
# carrying at least one tag, which on a real account means most of what is
# running is invisible to it — one organization here had three of sixteen
# Lambdas and none of eleven ECS services. So the inventory comes from the
# services themselves, and tags are read once and applied on top.
#
# An unattributed row is a finding, not a failure: something is running that
# nothing in the organization's committed configuration accounts for.
live_aws() {
  command -v aws >/dev/null || { live_err aws "the aws CLI is not on PATH"; return 0; }

  local region
  region=$(cfg aws_region)
  [[ -n $region ]] || region=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
  [[ -n $region ]] || region=$(aws configure get region 2>/dev/null || true)
  [[ -n $region ]] || {
    live_err aws "no region — set aws_region in $DIR/config.json or AWS_REGION"
    return 0
  }

  local ident account
  ident=$(aws sts get-caller-identity --output json --region "$region" 2>&1) || {
    live_err aws "$(head -1 <<<"$ident")"
    return 0
  }
  account="$(jq -r '.Account // "unknown"' <<<"$ident") ($region)"

  # Tags first, so every reader below can ask "does anything name a repo here".
  # A failure is not fatal: it costs attribution, not the inventory.
  local tagfile
  tagfile=$(mktemp)
  aws resourcegroupstaggingapi get-resources --region "$region" --output json \
    2>/dev/null |
    jq -r --arg keys "$LIVE_REPO_TAGS" '
      .ResourceTagMappingList[]?
      | [.ResourceARN,
         ([.Tags[]? | select(.Key | test("^(" + $keys + ")$")) | .Value] | first // "")]
      | select(.[1] != "") | @tsv' >"$tagfile" 2>/dev/null || true

  live_aws_tag() { awk -F'\t' -v a="$1" '$1 == a {print $2; exit}' "$tagfile"; }

  # One row, attributed by whichever rule fires first.
  # $1 name  $2 kind  $3 arn  $4 state  $5 updated  $6 host
  live_aws_row() {
    local name=$1 kind=$2 arn=$3 state=$4 updated=$5 host=${6:-}
    local repo match tagged
    repo=""; match=""
    tagged=$(live_aws_tag "$arn")
    if [[ -n $tagged ]] && live_repo_exists "$tagged"; then repo=$tagged; match="tag"; fi
    if [[ -z $repo && -n $host ]]; then
      repo=$(live_repo_for_host "$host" 2>/dev/null || true)
      [[ -n $repo ]] && match="map"
    fi
    if [[ -z $repo ]]; then
      repo=$(live_repo_named "$name" || true)
      [[ -n $repo ]] && match="name"
    fi

    jq -cn --arg provider aws --arg name "$name" --arg repo "$repo" \
      --arg match "$match" --arg state "$state" --arg updated "$updated" \
      --arg host "$host" --arg account "$account" --arg source "aws:$kind/$name" \
      '{provider:$provider, name:$name,
        repo:(if $repo == "" then null else $repo end),
        match:(if $match == "" then null else $match end),
        state:(if $state == "" then null else $state end),
        urls:(if $host == "" then [] else [$host] end),
        account:$account,
        updated:(if $updated == "" then null else $updated end),
        source:$source}' | live_row
  }

  local n u arn a cluster
  local read_any=0

  # Lambda: name, last modified, and the state the list call already carries.
  local fns
  if fns=$(aws lambda list-functions --region "$region" --output json 2>&1); then
    read_any=1
    while IFS=$'\t' read -r n u arn; do
      [[ -n $n ]] || continue
      live_aws_row "$n" lambda "$arn" "" "$u"
    done < <(jq -r '.Functions[]? | [.FunctionName, (.LastModified // ""), .FunctionArn] | @tsv' <<<"$fns")
  else
    live_err aws "lambda: $(head -1 <<<"$fns")"
  fi

  # ECS: the services, not the clusters. A cluster with no service is a batch
  # queue, not something answering requests.
  local clusters svcs desc
  if clusters=$(aws ecs list-clusters --region "$region" --output json 2>&1); then
    read_any=1
    while read -r cluster; do
      [[ -n $cluster ]] || continue
      svcs=$(aws ecs list-services --region "$region" --cluster "$cluster" \
        --output json 2>/dev/null) || continue
      local -a arns=() batch=()
      while read -r a; do [[ -n $a ]] && arns+=("$a"); done < <(jq -r '.serviceArns[]?' <<<"$svcs")
      [[ ${#arns[@]} -gt 0 ]] || continue

      # describe-services takes ten at a time. Every service is described, in
      # batches — a cluster with eleven of them does not quietly lose one.
      local i
      for ((i = 0; i < ${#arns[@]}; i += 10)); do
        batch=("${arns[@]:i:10}")
        desc=$(aws ecs describe-services --region "$region" --cluster "$cluster" \
          --services "${batch[@]}" --output json 2>/dev/null) || continue
        while IFS=$'\t' read -r n u arn; do
          [[ -n $n ]] || continue
          live_aws_row "$n" "ecs/${cluster##*/}" "$arn" "$u" ""
        done < <(jq -r '.services[]? | [.serviceName,
            ((.status // "") + " " + ((.runningCount // 0) | tostring) + "/" + ((.desiredCount // 0) | tostring)),
            .serviceArn] | @tsv' <<<"$desc")
      done
    done < <(jq -r '.clusterArns[]?' <<<"$clusters")
  else
    live_err aws "ecs: $(head -1 <<<"$clusters")"
  fi

  # Elastic Beanstalk: the one AWS service that hands back a hostname, which
  # means the map's own deploys-to edges can match it.
  local envs
  if envs=$(aws elasticbeanstalk describe-environments --region "$region" \
    --output json 2>/dev/null); then
    read_any=1
    local host
    while IFS=$'\t' read -r n u arn host; do
      [[ -n $n ]] || continue
      live_aws_row "$n" beanstalk "$arn" "$u" "" "$host"
    done < <(jq -r '.Environments[]? | [.EnvironmentName,
        ((.Status // "") + " " + (.Health // "")), (.EnvironmentArn // ""),
        (.CNAME // "")] | @tsv' <<<"$envs")
  fi

  unset -f live_aws_tag live_aws_row
  rm -f "$tagfile"
  [[ $read_any == 1 ]] || live_err aws "nothing could be listed in $region"
  return 0
}

# --- the command --------------------------------------------------------------

# Which providers the map already says the org deploys with. Asking a provider
# nobody uses is a wasted call and a confusing error.
live_providers_in_map() {
  local g="$DIR/map/graph.json"
  [[ -f $g ]] || return 0
  jq -r '[.nodes[] | select(.kind == "tool") | .name]
         | map(select(. == "vercel" or . == "fly" or . == "aws"))
         | unique | .[]' "$g" 2>/dev/null
}

cmd_live() {
  load_company
  [[ -f $DIR/map/repos.json ]] || die "no map yet — run: orgami scan"

  local want="" quiet=0 as_json=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --provider | -p) want=$2; shift 2 ;;
      --json) as_json=1; shift ;;
      --quiet | -q) quiet=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  local providers
  if [[ -n $want ]]; then
    providers=$(tr ', ' '\n\n' <<<"$want" | grep -v '^$' || true)
  else
    providers=$(live_providers_in_map)
    [[ -n $providers ]] ||
      providers=$(jq -r '(.live.providers // []) | .[]' "$DIR/config.json" 2>/dev/null || true)
  fi
  [[ -n ${providers//[[:space:]]/} ]] ||
    die "no provider to ask — the map names none of vercel, fly, aws; pass --provider"

  LIVE_ROWS=$(mktemp)
  LIVE_ERRORS=$(mktemp)

  local p asked=()
  while read -r p; do
    [[ -n $p ]] || continue
    case $p in
      fly) [[ $quiet == 1 ]] || log "asking fly"; live_fly ;;
      vercel) [[ $quiet == 1 ]] || log "asking vercel"; live_vercel ;;
      aws) [[ $quiet == 1 ]] || log "asking aws"; live_aws ;;
      *) live_err "$p" "no reader for '$p' — vercel, fly and aws are the ones there are"; continue ;;
    esac
    asked+=("$p")
  done <<<"$providers"

  # A run where no provider could be read is not a reading of an empty org — it
  # is a missing token, or a typo in --provider. Keep whatever was there before
  # rather than replacing a good reading with a blank one.
  local out="$DIR/map/live.json" failed read_ok
  failed=$(jq -s '[.[].provider] | unique | length' "$LIVE_ERRORS")
  read_ok=$((${#asked[@]} - failed))
  if [[ $read_ok -le 0 ]]; then
    echo "no provider could be read — $out left as it was" >&2
    jq -r '"  " + .provider + ": " + .message' "$LIVE_ERRORS" >&2
    rm -f "$LIVE_ROWS" "$LIVE_ERRORS"
    return 1
  fi

  jq -s --arg at "$(live_now)" --argjson epoch "$(date -u +%s)" \
    --argjson providers "$(printf '%s\n' "${asked[@]:-}" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
    --slurpfile errors "$LIVE_ERRORS" \
    '{generated: $at, generated_epoch: $epoch, providers: $providers,
      deployments: ([.[] | select(.repo != null)] | sort_by(.provider, .name)),
      unmatched: ([.[] | select(.repo == null) | {provider, name, state, urls, source}] | sort_by(.provider, .name)),
      errors: $errors}' \
    "$LIVE_ROWS" >"$out"

  rm -f "$LIVE_ROWS" "$LIVE_ERRORS"

  if [[ $as_json == 1 ]]; then
    cat "$out"
    return 0
  fi

  local matched unmatched errs
  matched=$(jq '.deployments | length' "$out")
  unmatched=$(jq '.unmatched | length' "$out")
  errs=$(jq '.errors | length' "$out")

  jq -r '.deployments[]
    | "  " + (.repo // "?") + "  ← " + .provider + " " + .name
      + (if .state then "  [" + .state + "]" else "" end)
      + (if (.urls | length) > 0 then "  " + (.urls | join(" ")) else "" end)' "$out"
  [[ $matched -gt 0 ]] && echo

  # The unmatched list is the interesting half on most accounts, but it is also
  # the long one. First ten, then the count — never a silent truncation.
  if [[ $unmatched -gt 0 ]]; then
    jq -r '.unmatched[0:10][] | "  (nothing ties this to a repo) " + .provider + " " + .name
      + (if .state then "  [" + .state + "]" else "" end)
      + (if (.urls | length) > 0 then "  " + (.urls | join(" ")) else "" end)' "$out"
    [[ $unmatched -gt 10 ]] && echo "  … and $((unmatched - 10)) more, all in $out"
    echo
  fi

  echo "$out  ($matched tied to a repo, $unmatched not, $errs provider error(s))"
  [[ $errs -gt 0 ]] && jq -r '.errors[] | "  " + .provider + ": " + .message' "$out"

  # Nothing attributed is not a bug in the reading — it means the account and
  # the repositories are named by different conventions, which is worth saying
  # once rather than leaving someone to conclude the command is broken.
  if [[ $matched == 0 && $unmatched -gt 0 ]]; then
    echo
    echo "Nothing here names a repository. A deployment is only tied to one by a tag"
    echo "(Repository=<repo>), by the provider naming the GitHub repo itself, or by"
    echo "carrying the whole repo name — see docs/live.md."
  fi
  return 0
}

# --- reading it back ----------------------------------------------------------

# How old the reading is, in whole days. Nothing here is worth showing without
# it: a deployment that was READY nine days ago is a rumour.
live_age_days() {
  local f="$DIR/map/live.json" was now
  [[ -f $f ]] || return 1
  was=$(jq -r '.generated_epoch // empty' "$f" 2>/dev/null)
  [[ -n $was ]] || return 1
  now=$(date -u +%s)
  echo $(((now - was) / 86400))
}

# "today" / "3 days ago" — the reading is worthless without one of these.
live_age_phrase() {
  local age=${1:-}
  if [[ -z $age || $age == "?" ]]; then echo "at some point"
  elif [[ $age -le 0 ]]; then echo "today"
  elif [[ $age == 1 ]]; then echo "yesterday"
  else echo "$age days ago"
  fi
}

# The "Running now" block for a repo page. Empty when nothing is known, which
# is the common case until someone runs `orgami live`.
live_section() {
  local repo=$1 f="$DIR/map/live.json" age rows
  [[ -f $f ]] || return 0
  rows=$(jq -r --arg r "$repo" '.deployments[] | select(.repo == $r)
    | "- **" + .provider + "** `" + .name + "`"
      + (if .state then " — " + .state else "" end)
      + (if (.urls | length) > 0 then " · " + (.urls | map("<https://" + . + ">") | join(", ")) else "" end)
      + (if .account then " · " + .account else "" end)' "$f" 2>/dev/null)
  [[ -n $rows ]] || return 0

  age=$(live_age_days || echo "?")
  echo "## Running now"
  echo
  echo "$rows"
  echo
  if [[ $age != "?" && $age -ge $LIVE_STALE_DAYS ]]; then
    echo "**Read $(live_age_phrase "$age") and not since** — treat it as a rumour until \`orgami live\` runs again."
  else
    echo "Read from the providers $(live_age_phrase "$age"), not from the code — it expires."
  fi
  echo
}

# One line for the session-start injection: what this repo is serving right
# now, and how old that reading is. Silent when nobody has run `orgami live`,
# and silent once the reading is too old to state as fact.
live_brief() {
  local repo=$1 f="$DIR/map/live.json" age rows
  [[ -f $f ]] || return 0
  age=$(live_age_days) || return 0
  [[ $age -lt $LIVE_STALE_DAYS ]] || return 0
  rows=$(jq -r --arg r "$repo" '[.deployments[] | select(.repo == $r)
    | .provider + " " + .name
      + (if .state then " (" + .state + ")" else "" end)
      + (if (.urls | length) > 0 then " " + (.urls | first) else "" end)]
    | join(", ")' "$f" 2>/dev/null)
  [[ -n $rows && $rows != "null" ]] || return 0
  echo "deployed (read $(live_age_phrase "$age")): $rows"
}

# The org-level view: how much of the map is tied to something running.
live_overview() {
  local f="$DIR/map/live.json" age
  [[ -f $f ]] || return 0
  age=$(live_age_days || echo "?")

  # Nothing attributed, but things running: that is still worth one line. A
  # service nobody can name is the one that surprises somebody at 2am.
  if ! jq -e '(.deployments | length) > 0' "$f" >/dev/null 2>&1; then
    local orphans
    orphans=$(jq '.unmatched | length' "$f" 2>/dev/null || echo 0)
    [[ ${orphans:-0} -gt 0 ]] || return 0
    echo "## What is actually running"
    echo
    echo "$orphans things are running that nothing in this map accounts for, read"
    echo "$(live_age_phrase "$age") with \`orgami live\`. None of them carries a repository"
    echo "name or tag, so none can be attributed — the list is in \`map/live.json\`."
    echo
    return 0
  fi

  echo "## What is actually running"
  echo
  jq -r '.deployments[]
    | "- **" + .repo + "** — " + .provider + " `" + .name + "`"
      + (if .state then " " + .state else "" end)
      + (if (.urls | length) > 0 then " · " + (.urls | map("<https://" + . + ">") | join(", ")) else "" end)' "$f"
  echo
  echo "Read from the providers $(live_age_phrase "$age") with \`orgami live\`, not from"
  echo "committed files — unlike the rest of this page, it cannot be checked after the fact."
  echo
}
