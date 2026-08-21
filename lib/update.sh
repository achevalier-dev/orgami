# shellcheck shell=bash
# Keeping every copy of orgami on a machine at the same version.
#
# There are usually two, installed by different things and updated by neither:
# the clone `bootstrap.sh` put in ~/.local/share/orgami, which owns the CLI on
# PATH, and the clone Claude Code keeps under ~/.claude/plugins, which owns the
# skill, the slash commands and the session hooks. A fix landing in one of them
# and not the other is the normal state of affairs, and it is invisible — the
# CLI says one version, the hook that calls it is a fortnight older.
#
# So: one command that moves both, and a check cheap enough to run at every
# session start.

UPDATE_INTERVAL_HOURS=${ORGAMI_UPDATE_INTERVAL:-24}

update_state_dir() {
  local d="${XDG_STATE_HOME:-$HOME/.local/state}/orgami"
  mkdir -p "$d" 2>/dev/null || return 1
  echo "$d"
}

update_enabled() {
  [[ ${ORGAMI_AUTOUPDATE:-1} != 0 ]] || return 1
  local root="$ORGAMI_HOME/config.json"
  [[ -f $root ]] || return 0
  [[ $(jq -r '.auto_update // true' "$root" 2>/dev/null) != false ]]
}

# A checkout somebody is working in is not a checkout to pull under them. This
# is the whole safety story: uncommitted work, no upstream, or a branch that is
# not what the install tracks, and the answer is to say so and change nothing.
update_why_not() {
  local dir=$1
  [[ -d $dir/.git ]] || {
    echo "not a git checkout — reinstall with bootstrap.sh to get updates"
    return 0
  }
  git -C "$dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || {
    echo "$(basename "$dir") tracks no upstream branch"
    return 0
  }
  [[ -z $(git -C "$dir" status --porcelain 2>/dev/null) ]] || {
    echo "$dir has uncommitted changes — left alone"
    return 0
  }
  return 1
}

# Claude Code owns its own plugin clone: it decides where it lives and when it
# moves. Pulling it from underneath would work until the day it does not.
update_is_plugin_dir() { [[ $1 == *"/.claude/plugins/"* ]]; }

update_version() { jq -r '.version // "unknown"' "$1/manifest.json" 2>/dev/null; }

# Every copy of orgami this machine has, which is not the same as the one
# running. A plugin hook runs the plugin's copy, and the clone that owns the CLI
# on PATH is a different directory entirely — updating only the copy that
# happens to be executing is how one of them stays a fortnight behind forever.
update_targets() {
  local path_bin dir
  {
    echo "$ROOT"
    path_bin=$(command -v orgami 2>/dev/null || true)
    if [[ -n $path_bin ]]; then
      dir=$(orgami_realpath "$path_bin")
      (cd -- "$(dirname -- "$dir")/.." 2>/dev/null && pwd) || true
    fi
  } | awk 'NF && !seen[$0]++'
}

# The CLI's own clone. Returns 0 when it moved, 1 when it did not.
update_cli() {
  local dir=$1 quiet=$2 before after why

  if update_is_plugin_dir "$dir"; then
    [[ $quiet == 1 ]] || log "running from the Claude Code plugin — it updates with the plugin"
    return 1
  fi

  if why=$(update_why_not "$dir"); then
    [[ $quiet == 1 ]] || log "$why"
    return 1
  fi

  git -C "$dir" fetch --quiet origin 2>/dev/null || {
    [[ $quiet == 1 ]] || log "could not reach the remote — nothing changed"
    return 1
  }

  before=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  after=$(git -C "$dir" rev-parse '@{u}' 2>/dev/null)
  [[ $before != "$after" ]] || return 1

  local from
  from=$(update_version "$dir")
  git -C "$dir" merge --ff-only --quiet '@{u}' 2>/dev/null || {
    # A fast-forward that will not fast-forward means the local clone has
    # commits of its own. That is somebody's work, not a stale install.
    [[ $quiet == 1 ]] || log "$dir has diverged from its upstream — left alone"
    return 1
  }

  # New files need linking, and the systemd units are copied rather than linked.
  bash "$dir/install.sh" >/dev/null 2>&1 || true

  local to state
  to=$(update_version "$dir")
  # What actually changed, for the line the next session prints.
  if state=$(update_state_dir); then
    {
      echo "orgami updated $from -> $to"
      git -C "$dir" log --oneline "$before..$after" 2>/dev/null | head -5 | sed 's/^/  /'
    } >"$state/updated"
  fi
  [[ $quiet == 1 ]] || {
    echo "orgami $from -> $to"
    git -C "$dir" log --oneline "$before..$after" 2>/dev/null | head -10 | sed 's/^/  /'
  }
  return 0
}

# The plugin clone, through the tool that owns it.
update_plugin() {
  local quiet=$1
  command -v claude >/dev/null || return 1
  claude plugin marketplace update orgami >/dev/null 2>&1 || {
    [[ $quiet == 1 ]] || log "could not update the Claude Code plugin — try: claude plugin marketplace update orgami"
    return 1
  }
  [[ $quiet == 1 ]] || echo "Claude Code plugin updated — it loads at the next session"
  return 0
}

# Point both installs at a working checkout, so an edit is live in the next
# session rather than after a commit, a push and two pulls. This is what a
# machine that develops orgami wants, and nothing else does.
update_dev() {
  local repo=${1:-$PWD}
  repo=$(cd -- "$repo" 2>/dev/null && pwd) || die "no such directory: ${1:-$PWD}"
  [[ -f $repo/bin/orgami && -f $repo/.claude-plugin/marketplace.json ]] ||
    die "$repo is not an orgami checkout"

  bash "$repo/install.sh"

  if ! command -v claude >/dev/null; then
    log "claude is not on PATH — the CLI reads $repo, the plugin is untouched"
    return 0
  fi

  # The marketplace name comes from marketplace.json, so the GitHub one and this
  # one collide. Drop it before adding the path, or the add is refused.
  claude plugin marketplace remove orgami >/dev/null 2>&1 || true
  claude plugin marketplace add "$repo" >/dev/null 2>&1 ||
    die "could not add $repo as a marketplace — add it by hand: claude plugin marketplace add $repo"
  claude plugin install orgami@orgami --yes >/dev/null 2>&1 || true

  echo "the CLI and the Claude Code plugin both read $repo now."
  echo "Edits are live in the next session — no commit, no push, no pull."
  echo "Back to the published one: claude plugin marketplace remove orgami &&"
  echo "  claude plugin marketplace add achevalier-dev/orgami"
}

# orgami update [--check] [--if-stale] [--background] [--quiet] [--dev [path]]
cmd_update() {
  local check=0 if_stale=0 background=0 quiet=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --report) update_report; return 0 ;;
      --dev | --link) shift; update_dev "${1:-$PWD}"; return 0 ;;
      --check | -n) check=1; shift ;;
      --if-stale) if_stale=1; shift ;;
      --background | --detach) background=1; shift ;;
      --quiet | -q) quiet=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  if [[ $if_stale == 1 ]]; then
    update_enabled || return 0
    local state stamp
    state=$(update_state_dir) || return 0
    stamp="$state/update-checked"
    if [[ -f $stamp ]]; then
      local age
      age=$(((  $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null ||
        stat -f %m "$stamp" 2>/dev/null || echo 0) ) / 3600))
      [[ $age -ge $UPDATE_INTERVAL_HOURS ]] || return 0
    fi
    : >"$stamp"
    quiet=1
  fi

  if [[ $background == 1 ]]; then
    # Detached: a session never waits on somebody else's network.
    (setsid "$ORGAMI_BIN" update --quiet >/dev/null 2>&1 &) 2>/dev/null ||
      ("$ORGAMI_BIN" update --quiet >/dev/null 2>&1 &)
    return 0
  fi

  need git

  local dir why behind
  if [[ $check == 1 ]]; then
    while read -r dir; do
      [[ -n $dir ]] || continue
      if update_is_plugin_dir "$dir"; then
        echo "$(update_version "$dir") — $dir, updated by claude plugin marketplace update"
        continue
      fi
      if why=$(update_why_not "$dir"); then
        echo "$(update_version "$dir") — $why"
        continue
      fi
      git -C "$dir" fetch --quiet origin 2>/dev/null || {
        echo "$(update_version "$dir") — $dir, could not reach the remote"
        continue
      }
      behind=$(git -C "$dir" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
      if [[ ${behind:-0} -gt 0 ]]; then
        echo "$(update_version "$dir") — $dir, $behind commit(s) behind. Run: orgami update"
        git -C "$dir" log --oneline "HEAD..@{u}" | head -10 | sed 's/^/  /'
      else
        echo "$(update_version "$dir") — $dir, up to date"
      fi
    done < <(update_targets)
    return 0
  fi

  local moved=0
  while read -r dir; do
    [[ -n $dir ]] || continue
    update_cli "$dir" "$quiet" && moved=1
  done < <(update_targets)
  update_plugin "$quiet" && moved=1

  if [[ $moved == 0 && $quiet == 0 ]]; then
    echo "$(update_version "$ROOT") — already the newest here"
  fi
  return 0
}

# One line for the session hook, once, naming what moved since it last spoke.
update_report() {
  local state file
  state="${XDG_STATE_HOME:-$HOME/.local/state}/orgami"
  file="$state/updated"
  [[ -f $file ]] || return 0
  cat "$file"
  rm -f "$file"
}
