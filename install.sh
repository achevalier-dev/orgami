#!/bin/bash
# Links orgami onto PATH, installs the Claude skill and the weekly timer units.
# Safe to re-run: everything is a symlink or an overwrite.

set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$HOME/.local/bin"
SKILL_DIR="$HOME/.claude/skills/orgami"
UNIT_DIR="$HOME/.config/systemd/user"

for tool in jq gh git fzf gum; do
  command -v "$tool" >/dev/null || echo "warning: $tool is not on PATH" >&2
done
command -v claude >/dev/null ||
  echo "warning: claude is not on PATH — 'orgami report' needs Claude Code in headless mode" >&2
gh auth status >/dev/null 2>&1 ||
  echo "warning: gh is not authenticated — run: gh auth login" >&2

mkdir -p "$BIN_DIR"
ln -sf "$REPO/bin/orgami" "$BIN_DIR/orgami"
echo "linked $BIN_DIR/orgami -> $REPO/bin/orgami"

# Installed as a Claude Code plugin? Then the plugin already supplies the skill,
# the slash commands and the session hook — linking it again would duplicate it.
if [[ $REPO == *"/.claude/plugins/"* ]]; then
  echo "running inside a Claude Code plugin — skill and hooks come from the plugin"
else
  mkdir -p "$SKILL_DIR"
  ln -sf "$REPO/skills/orgami/SKILL.md" "$SKILL_DIR/SKILL.md"
  echo "linked $SKILL_DIR/SKILL.md"
fi

mkdir -p "$UNIT_DIR"
cp -f "$REPO/systemd/orgami-weekly@.service" "$REPO/systemd/orgami-weekly@.timer" "$UNIT_DIR/"
systemctl --user daemon-reload 2>/dev/null || true
echo "installed $UNIT_DIR/orgami-weekly@.{service,timer}"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH" >&2 ;;
esac

cat <<'EOF'

next:
  orgami init    add your first company, step by step
  orgami         the menu
EOF
