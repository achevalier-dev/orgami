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

brief=$("$ORGAMI" brief 2>/dev/null) || exit 0
[[ -n $brief ]] || { [[ $JSON == 1 ]] && echo '{}'; exit 0; }

context=$(cat <<CTX
$brief

Use this instead of re-deriving it. \`orgami context\` for the full page.
If this session turns up something durable that is not in the code — the real
cause of a bug, why an obvious fix does not work here, a missing setup step —
offer to record it with \`orgami note "..."\`, and ask before writing, because
notes are shared with the whole team under the user's name.
CTX
)

if [[ $JSON == 1 ]]; then
  jq -n --arg c "$context" '{additional_context: $c}'
else
  printf '%s\n' "$context"
fi
