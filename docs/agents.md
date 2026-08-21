# Other agents

Nothing here is Claude-only. The map is markdown and JSON on disk, and the CLI
is the interface — only the plugin, the skill and the session hook are specific
to Claude Code.

## What Claude Code reads

With the plugin installed there is nothing to run. Opening Claude Code in a
mapped checkout injects the short version at session start:

```
orgami — winit (winitapp), map from 2026-08-17

WinIt-backend — TypeScript, Agenda jobs, Express, Parse SDK, Parse Server

  build: tsc -p tsconfig.build.json
  test: cross-env NODE_ENV=test ... jest --silent --coverage test/*

linked repos:
  calls -> Attorney-Portal
  changes-with <- Close-SMS-Report

team notes on this repo:
- Parse Dashboard config lives in WinIt-ParseDashboard/index.js, not the fork …
```

Outside a mapped repo it prints nothing at all. For the whole page:

```bash
orgami context          # inside a checkout: that repo. anywhere else: the org.
orgami context <repo>   # by name
```

One command, one screen. The repo page carries the framework, the exact commands
to run and test it, what it talks to and what talks to it, the endpoints it
serves, the environment it reads, where it deploys, which repos it usually
changes with, its recent merged pull requests, and links to any `AGENTS.md` the
repo already has. Cards are also written to `map/repos/<repo>.md` and published
with everything else.

`install.sh` links a skill into `~/.claude/skills/orgami/` that teaches Claude to
run `orgami context` first, cite the evidence line for anything it claims, say
when the map is stale rather than trusting it silently, distinguish "not found in
committed configuration" from "not connected", and never run `orgami publish` on
its own.

The skill covers the other direction too, which is the half that decides whether
any of this accumulates: when a piece of work is finished, what does it leave
behind? A durable fact goes to `orgami note`; one instance of a job that will
come round again — one more fetcher, one more endpoint — goes to `orgami note
--tag pattern --topic <job>`, and two of those write that job's playbook by
themselves. See [playbooks.md](playbooks.md).

Sessions are also read back on their own. The end-of-session hook drafts a note
from what was said, and because most sessions never end cleanly — a window
closed, a machine shut — the *next* session sweeps up whatever was left unread,
newest first, detached so nothing waits on it. `orgami drafts` keeps or throws
away what was written for you; `ORGAMI_AUTONOTE=0` turns the whole thing off.

## Anything that speaks MCP

Cursor, opencode, Windsurf, Zed, Codex, VS Code and Claude Desktop get the map as
tools: `orgami_context`, `orgami_search`, `orgami_notes`, `orgami_note`,
`orgami_query`, `orgami_decisions`, `orgami_conventions`.

```bash
orgami mcp --config cursor      # or opencode, codex, claude-code, windsurf, zed, vscode
```

That prints the snippet for the client, and `orgami mcp` is the server itself —
stdio JSON-RPC, Python standard library only, shelling out to the same CLI so
there is no second implementation to drift. The `orgami_note` tool is described
to the model as requiring the user's agreement first, the same rule the Claude
skill carries.

## Cursor

Cursor reaches parity with Claude Code, because its `sessionStart` hook can
return `additional_context`:

```bash
orgami agents --cursor-hook          # this project
orgami agents --cursor-hook --user   # every project you open
```

Cursor then injects the repo's stack, commands, linked repos and team notes at
the start of every session — regenerated each time, not a snapshot — and stays
silent outside a mapped checkout. Same script as the Claude Code hook, with
`--json` for Cursor's output format.

**opencode** cannot do this. Its plugin API has session *events* but no
documented way to add text to the model's context — only
`experimental.session.compacting`, which fires on compaction. So opencode reads
the generated file instead, and the answer there is to keep that file current.

## Anything that reads AGENTS.md

opencode, Codex, Zed, Jules and Cursor can have the context written straight into
the repository:

```bash
orgami agents            # AGENTS.md, plus .cursor/rules if the repo has .cursor/
orgami agents --all      # both, explicitly
```

It writes a marked block and rewrites only that block on later runs, so anything
you wrote by hand around it survives. These files live in the repo, so commit
them only if the team wants them there.

A written block is a snapshot, so it drifts as soon as the map moves. Two ways to
keep it current, and they compose:

```bash
orgami agents --refresh --workspace ~/Work/acme   # every mapped checkout under a root
orgami agents --git-hook                          # refresh on merge, checkout, rebase
```

The workspace is remembered, so later runs are just `orgami agents --refresh`,
and `orgami weekly` runs it automatically once one is configured. The refresh
only rewrites blocks that already exist — it never creates a context file in a
repo that did not ask for one.
