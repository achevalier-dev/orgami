#!/usr/bin/env bash
# One command: dependencies, orgami itself, and whichever editors are installed.
#
#   curl -fsSL https://raw.githubusercontent.com/achevalier-dev/orgami/main/bootstrap.sh | bash
#
# Flags (pass with `| bash -s -- --flag`):
#   --dry-run      print what would happen, change nothing
#   --no-deps      skip package installation
#   --no-editors   skip the Claude Code and Cursor wiring

set -euo pipefail

REPO_URL=${ORGAMI_REPO:-https://github.com/achevalier-dev/orgami}
SRC=${ORGAMI_SRC:-$HOME/.local/share/orgami}
DRY=0
DEPS=1
EDITORS=1

for arg in "$@"; do
  case $arg in
    --dry-run) DRY=1 ;;
    --no-deps) DEPS=0 ;;
    --no-editors) EDITORS=0 ;;
    -h | --help)
      sed -n '2,12p' "$0" 2>/dev/null || true
      exit 0
      ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

run() {
  if [[ $DRY == 1 ]]; then
    dim "would run: $*"
  else
    dim "$*"
    "$@"
  fi
}

# ---------------------------------------------------------------- environment

OS=$(uname -s)
case $OS in
  Darwin) PLATFORM=macos ;;
  Linux) PLATFORM=linux ;;
  MINGW* | MSYS* | CYGWIN*) PLATFORM=gitbash ;;
  *) PLATFORM=unknown ;;
esac
grep -qi microsoft /proc/version 2>/dev/null && PLATFORM=wsl

MGR=none
if command -v brew >/dev/null; then MGR=brew
elif command -v pacman >/dev/null; then MGR=pacman
elif command -v apt >/dev/null; then MGR=apt
elif command -v dnf >/dev/null; then MGR=dnf
elif command -v winget >/dev/null; then MGR=winget
fi

SUDO=""
[[ $EUID -ne 0 ]] && command -v sudo >/dev/null && SUDO=sudo

bold "orgami installer"
dim "$PLATFORM, package manager: $MGR"

# ---------------------------------------------------------------- dependencies

missing=()
for tool in git gh jq fzf gum python3; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
# Git Bash calls it python, not python3.
[[ $PLATFORM == gitbash ]] && command -v python >/dev/null &&
  missing=("${missing[@]/python3/}")

pkg_name() {
  case "$MGR:$1" in
    brew:gh) echo gh ;;
    brew:python3) echo python ;;
    pacman:gh) echo github-cli ;;
    pacman:python3) echo python ;;
    apt:gh | dnf:gh) echo gh ;;
    winget:gh) echo GitHub.cli ;;
    winget:jq) echo jqlang.jq ;;
    winget:fzf) echo junegunn.fzf ;;
    winget:gum) echo charmbracelet.gum ;;
    winget:git) echo Git.Git ;;
    winget:python3) echo Python.Python.3.12 ;;
    *) echo "$1" ;;
  esac
}

install_missing() {
  local pkgs=()
  local t
  for t in "${missing[@]}"; do
    [[ -n $t ]] && pkgs+=("$(pkg_name "$t")")
  done
  [[ ${#pkgs[@]} -gt 0 ]] || return 0

  case $MGR in
    brew) run brew install "${pkgs[@]}" ;;
    pacman) run $SUDO pacman -S --needed --noconfirm "${pkgs[@]}" ;;
    dnf) run $SUDO dnf install -y "${pkgs[@]}" ;;
    winget)
      for p in "${pkgs[@]}"; do run winget install -e --id "$p"; done
      ;;
    apt)
      # gh and gum publish their own repositories; the rest is plain apt.
      local plain=()
      for p in "${pkgs[@]}"; do
        case $p in
          gh | gum) ;;
          *) plain+=("$p") ;;
        esac
      done
      run $SUDO apt-get update -qq
      [[ ${#plain[@]} -gt 0 ]] && run $SUDO apt-get install -y "${plain[@]}"
      if printf '%s\n' "${pkgs[@]}" | grep -qx gh; then
        run $SUDO mkdir -p -m 755 /etc/apt/keyrings
        if [[ $DRY == 0 ]]; then
          curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg |
            $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
          $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
          echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
            $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        else
          dim "would add the GitHub CLI apt repository"
        fi
      fi
      if printf '%s\n' "${pkgs[@]}" | grep -qx gum; then
        if [[ $DRY == 0 ]]; then
          $SUDO mkdir -p /etc/apt/keyrings
          curl -fsSL https://repo.charm.sh/apt/gpg.key |
            $SUDO gpg --dearmor -o /etc/apt/keyrings/charm.gpg
          echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" |
            $SUDO tee /etc/apt/sources.list.d/charm.list >/dev/null
        else
          dim "would add the Charm apt repository"
        fi
      fi
      run $SUDO apt-get update -qq
      for p in gh gum; do
        printf '%s\n' "${pkgs[@]}" | grep -qx "$p" && run $SUDO apt-get install -y "$p"
      done
      ;;
    *)
      warn "no package manager found — install by hand: ${pkgs[*]}"
      ;;
  esac
}

if [[ ${#missing[@]} -gt 0 && -n ${missing[0]} ]]; then
  step "Installing ${missing[*]}"
  if [[ $DEPS == 1 ]]; then
    install_missing
  else
    dim "skipped (--no-deps): ${missing[*]}"
  fi
else
  step "Dependencies already present"
fi

command -v claude >/dev/null ||
  warn "claude is not installed — 'orgami report' needs it: curl -fsSL https://claude.ai/install.sh | bash"

# ---------------------------------------------------------------------- orgami

step "Installing orgami into $SRC"
if [[ -d $SRC/.git ]]; then
  run git -C "$SRC" pull --quiet --ff-only
else
  run mkdir -p "$(dirname "$SRC")"
  run git clone --quiet "$REPO_URL" "$SRC"
fi
run bash "$SRC/install.sh"

ORGAMI="$SRC/bin/orgami"

# ---------------------------------------------------------------------- editors

if [[ $EDITORS == 1 ]]; then
  if command -v claude >/dev/null; then
    step "Wiring Claude Code"
    run claude plugin marketplace add achevalier-dev/orgami
    run claude plugin install orgami@orgami
  fi

  if [[ -d $HOME/.cursor ]] || command -v cursor >/dev/null; then
    step "Wiring Cursor"
    if [[ $DRY == 0 ]]; then
      "$ORGAMI" agents --cursor-hook --user || warn "could not install the Cursor hook"
      mkdir -p "$HOME/.cursor"
      tmp=$(mktemp)
      [[ -f $HOME/.cursor/mcp.json ]] || echo '{}' >"$HOME/.cursor/mcp.json"
      jq --arg bin "$HOME/.local/bin/orgami" \
        '.mcpServers = ((.mcpServers // {}) + {orgami: {command: $bin, args: ["mcp"]}})' \
        "$HOME/.cursor/mcp.json" >"$tmp" && mv "$tmp" "$HOME/.cursor/mcp.json"
      dim "$HOME/.cursor/mcp.json"
    else
      dim "would install the Cursor sessionStart hook and MCP server"
    fi
  fi
fi

# ------------------------------------------------------------------ next steps

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *)
    warn "$HOME/.local/bin is not on your PATH — add it to your shell profile:"
    warn '  export PATH="$HOME/.local/bin:$PATH"'
    ;;
esac

echo
bold "Done."
echo
if ! gh auth status >/dev/null 2>&1; then
  echo "  1. gh auth login       sign in to GitHub"
  echo "  2. orgami init         map an organization, or 'orgami join' to pick one up"
else
  echo "  orgami init            map an organization"
  echo "  orgami join            or pick up one a colleague already mapped"
fi
echo
dim "then: orgami schedule (weekly), orgami (the menu), orgami context (in a checkout)"
