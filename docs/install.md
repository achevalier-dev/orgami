# Installing orgami by hand

The one-command install in the [README](../README.md) covers macOS, Linux, WSL
and Windows. This page is for doing each step yourself, or for a machine where
the bootstrap script cannot run.

## 1. Dependencies

Pick the line for your machine. `git` is assumed; everything else is one command.

**macOS** — [Homebrew](https://brew.sh):

```bash
brew install gh jq fzf gum
```

**Arch, Omarchy, Manjaro**:

```bash
sudo pacman -S github-cli jq fzf gum python
```

**Debian, Ubuntu, WSL** — `gh` and `gum` ship from their own repositories:

```bash
sudo apt update && sudo apt install -y jq fzf python3 curl

# GitHub CLI
(type -p wget >/dev/null || sudo apt install -y wget) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
     | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
     | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
  && sudo apt update && sudo apt install -y gh

# gum
sudo mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
     | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null \
  && sudo apt update && sudo apt install -y gum
```

**Fedora**:

```bash
sudo dnf install -y gh jq fzf gum python3
```

**Windows** — orgami is bash. Use [WSL](https://learn.microsoft.com/windows/wsl/install),
then follow the Ubuntu line above inside it:

```powershell
wsl --install
```

Git Bash also works for the CLI, but WSL is the path with a working weekly
schedule. If you drive orgami from Windows-native Cursor or Claude Code, point
hook commands at `wsl.exe bash -lc "..."`.

Nothing above is guessed at install time: `install.sh` checks each tool and
prints the exact command for *your* package manager if one is missing.

| Tool | Needed for |
|---|---|
| `gh`, `jq`, `git` | everything |
| `fzf` | `orgami view`, the terminal map browser |
| `gum` | `orgami init` and the menu — flags work without it |
| `python3` | `orgami mcp`, the MCP server for other editors |
| `claude` | `orgami report` only — the weekly recap and decision mining |

## 2. Sign in to GitHub

```bash
gh auth login
```

## 3. Install orgami

**In Claude Code** — this also gives you the skill, `/orgami:context`,
`/orgami:note` and the session hook:

```
/plugin marketplace add achevalier-dev/orgami
/plugin install orgami@orgami
```

then, once, to put the CLI on your PATH:

```bash
~/.claude/plugins/marketplaces/orgami/install.sh
```

**Anywhere else** — Cursor, opencode, a plain terminal, a server that only runs
the weekly job:

```bash
git clone https://github.com/achevalier-dev/orgami ~/orgami
cd ~/orgami && ./install.sh
```

## 4. Staying up to date

Two copies of orgami end up on a machine and neither updates itself: the clone
that owns the CLI on your PATH, and the clone Claude Code keeps for the plugin —
the skill, the slash commands and the session hooks. They drift apart silently,
and the symptom is a fix you know landed doing nothing.

```bash
orgami update          # move both, and relink whatever is new
orgami update --check  # what you would get, without taking it
```

It runs on its own too: once a day at session start, detached, and again at the
start of the weekly timer. The next session says what moved, once. It moves
*every* copy on the machine, not the one that happens to be running — a plugin
hook executes the plugin's copy while the CLI on your PATH is a different clone
entirely, and updating only one of them is how the other stays a fortnight
behind.

A CLI old enough to need updating has no `orgami update` in it, so the session
hook falls back to the plugin's copy, which moves both. That closes the loop:
whichever copy is current updates the other, and there is no manual first step
on a machine that has the plugin.

It refuses any checkout with uncommitted work, commits of its own, or no
upstream, and it never pulls Claude Code's clone directly — that goes through
`claude plugin marketplace update`.

Turn it off with `ORGAMI_AUTOUPDATE=0`, or `"auto_update": false` in
`~/.orgami/config.json`.

### Working on orgami itself

Point both installs at your checkout, and an edit is live in the next session
with no commit, push or pull in between:

```bash
cd ~/path/to/orgami
orgami update --dev
```

That links the CLI to the checkout and swaps the Claude Code marketplace from
GitHub to the local path. To go back:

```bash
claude plugin marketplace remove orgami
claude plugin marketplace add achevalier-dev/orgami
```

## 5. Point it at an organization

```bash
orgami init     # map one yourself — pick the org, it does the rest
orgami join     # or pick up one a colleague already mapped, no scan needed
```

## 6. Optional, once per organization

```bash
orgami schedule                # weekly, on systemd or launchd, cron line elsewhere
orgami agents --cursor-hook    # Cursor injects the context every session
orgami mcp --config cursor     # or opencode, codex, windsurf, zed, vscode
```

## What the bootstrap script does

- installs any of `git gh jq fzf gum python3` you are missing, through Homebrew,
  pacman, apt, dnf or winget — adding the GitHub CLI and Charm apt repositories
  when the distribution needs them
- clones orgami to `~/.local/share/orgami` and links `orgami` into `~/.local/bin`
- **Claude Code**, if present: adds the marketplace and installs the plugin, so
  the skill, `/orgami:context`, `/orgami:note` and the session hook come with it
- **Cursor**, if present: installs the `sessionStart` hook for every project and
  registers the MCP server in `~/.cursor/mcp.json`
- installs the weekly timer units

`--dry-run` prints every step without touching anything. `--no-deps` and
`--no-editors` skip those parts. On Windows the PowerShell script prefers WSL
when it is installed, and otherwise sets up Git for Windows and runs the same
bash installer inside it.
