#!/bin/bash
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

brief=$("$ORGAMI" brief 2>/dev/null) || exit 0
[[ -n $brief ]] || exit 0

cat <<CTX
$brief

Use this instead of re-deriving it. \`orgami context\` for the full page.
If this session turns up something durable that is not in the code — the real
cause of a bug, why an obvious fix does not work here, a missing setup step —
offer to record it with \`orgami note "..."\`, and ask before writing, because
notes are shared with the whole team under the user's name.
CTX
