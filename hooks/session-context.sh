#!/usr/bin/env bash
# SessionStart: hand Claude the context for whatever repo this session opened in.
# Silent when the directory has nothing to do with a mapped organization.

set -uo pipefail

ORGAMI=$(command -v orgami 2>/dev/null)
if [[ -z $ORGAMI && -n ${CLAUDE_PLUGIN_ROOT:-} && -x $CLAUDE_PLUGIN_ROOT/bin/orgami ]]; then
  ORGAMI="$CLAUDE_PLUGIN_ROOT/bin/orgami"
fi

if [[ -z $ORGAMI ]]; then
  # Only nag once, and only where it could plausibly help.
  marker="${XDG_STATE_HOME:-$HOME/.local/state}/orgami-install-nudge"
  if [[ ! -f $marker && -n ${CLAUDE_PLUGIN_ROOT:-} ]]; then
    mkdir -p "$(dirname "$marker")" 2>/dev/null && : >"$marker"
    echo "orgami is installed as a plugin but its CLI is not on PATH."
    echo "Offer to run: $CLAUDE_PLUGIN_ROOT/install.sh"
  fi
  exit 0
fi

# Cursor's sessionStart hook wants JSON on stdout with an additional_context key.
# Claude Code's takes the text as-is.
JSON=0
[[ ${1:-} == --json ]] && JSON=1

cd "${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}" 2>/dev/null || true

# Take whatever teammates have written since the last session, at most once
# every half hour, and never let a slow network hold up the session.
timeout 6 "$ORGAMI" sync --pull --max-age 30 --quiet >/dev/null 2>&1 || true

# Everything else — publishing what this machine wrote, having it reviewed,
# merging it if it passes — happens detached, so the session never waits.
"$ORGAMI" autosync --background --quiet >/dev/null 2>&1 || true

# Most sessions never end cleanly — a window is closed, a machine is shut — and
# SessionEnd does not fire for any of them. Whatever those sessions learned is
# read back here instead, detached, newest first.
"$ORGAMI" note-sweep --background >/dev/null 2>&1 || true

brief=$("$ORGAMI" brief 2>/dev/null || true)

# Notes drafted from earlier sessions, waiting for a person to keep or drop them.
drafts=$("$ORGAMI" drafts --count 2>/dev/null || echo 0)
waiting=""
if [[ ${drafts:-0} -gt 0 ]]; then
  waiting="
$drafts note(s) were drafted from earlier sessions and are waiting to be kept or
thrown away. Mention this once, and offer to run \`orgami drafts\`."
fi
# Drafts are worth surfacing even outside a mapped checkout; a brief is not.
if [[ -z $brief && -z $waiting ]]; then
  [[ $JSON == 1 ]] && echo '{}'
  exit 0
fi

context=$(cat <<CTX
$brief
$waiting

Use this instead of re-deriving it. \`orgami context\` for the full page.

Reading the map is half of it. When a piece of work in this session is done,
decide what it leaves behind for the next person:

- a durable fact that is not visible in the code — the real cause of a bug, why
  the obvious fix does not hold here, a setup step nobody wrote down:
  \`orgami note "..."\`;
- one instance of a job that will come round again — one more fetcher, one more
  endpoint, one more migration, one more integration wired the same way:
  \`orgami note --tag pattern --topic <the-job> "..."\`. Two instances under one
  topic write that job's playbook by themselves, and the next one starts from it
  instead of from nothing.

Ask before writing: notes are shared with the whole team under the user's name.
The orgami skill has the rest — playbooks, runbooks, decisions, what is deployed.
CTX
)

if [[ $JSON == 1 ]]; then
  jq -n --arg c "$context" '{additional_context: $c}'
else
  printf '%s\n' "$context"
fi
