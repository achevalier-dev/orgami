#!/usr/bin/env bash
# Links orgami onto PATH, installs the Claude skill and the weekly timer units.
# Safe to re-run: everything is a symlink or an overwrite.

set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$HOME/.local/bin"
SKILL_DIR="$HOME/.claude/skills/orgami"
UNIT_DIR="$HOME/.config/systemd/user"

# Say exactly what to run on this machine, rather than naming a missing tool
# and leaving the reader to work it out.
pkg_hint() {
  case "$1" in
    brew) echo "brew install $2" ;;
    pacman) echo "sudo pacman -S $3" ;;
    apt) echo "sudo apt install $3" ;;
    dnf) echo "sudo dnf install $3" ;;
    *) echo "install $2" ;;
  esac
}

MGR=none
command -v brew >/dev/null && MGR=brew
[[ $MGR == none ]] && command -v pacman >/dev/null && MGR=pacman
[[ $MGR == none ]] && command -v apt >/dev/null && MGR=apt
[[ $MGR == none ]] && command -v dnf >/dev/null && MGR=dnf

missing=()
#            command  brew name       distro name
check() {
  command -v "$1" >/dev/null && return 0
  missing+=("$1")
  echo "missing: $1 — $(pkg_hint "$MGR" "$2" "$3")" >&2
}

check jq jq jq
check git git git
check fzf fzf fzf
check gum gum gum
check python3 python python3
case $MGR in
  apt | dnf) check gh gh "gh   # https://github.com/cli/cli/blob/trunk/docs/install_linux.md" ;;
  *) check gh gh github-cli ;;
esac

if ! command -v claude >/dev/null; then
  echo "missing: claude — curl -fsSL https://claude.ai/install.sh | bash" >&2
  echo "         (only 'orgami report' needs it; everything else works without)" >&2
fi

if [[ ${#missing[@]} -gt 0 ]]; then
  echo >&2
  echo "orgami is installed, but install the above before using it." >&2
  echo >&2
fi

gh auth status >/dev/null 2>&1 ||
  echo "gh is not signed in — run: gh auth login" >&2

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

case "$(uname -s)" in
  Linux)
    if command -v systemctl >/dev/null; then
      mkdir -p "$UNIT_DIR"
      cp -f "$REPO/systemd/orgami-weekly@.service" "$REPO/systemd/orgami-weekly@.timer" "$UNIT_DIR/"
      systemctl --user daemon-reload 2>/dev/null || true
      echo "installed $UNIT_DIR/orgami-weekly@.{service,timer}"
    fi
    ;;
  Darwin) echo "macOS: 'orgami schedule' installs a launchd agent" ;;
  *) echo "no systemd or launchd here — 'orgami schedule' prints a cron line" ;;
esac

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH" >&2 ;;
esac

cat <<'EOF'

next:
  orgami init    map your organization, step by step
  orgami         the menu
EOF
