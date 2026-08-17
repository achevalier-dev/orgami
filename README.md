# orgami

**Know a client's organization before you touch its code.** orgami maps every
repo in a GitHub org — what each one is, how to run it, what it talks to, where
it deploys — recaps every pull request the org merged each week, and hands all of
it to your coding agent at session start.

![orgami: the context an agent is handed, one node and its evidence, the map in
the terminal, and the week's numbers](docs/demo.gif)

<sub>Recorded against a public organization ([honojs](https://github.com/honojs))
with `vhs docs/demo.tape` — every line in it came out of a committed file.</sub>

- **A map you can check.** Every edge carries the `file:line` it came from, so
  nothing in it is a model's guess. Missing edge means "not found in committed
  configuration", never "not connected".
- **A weekly recap you can trust the numbers in.** `jq` computes every figure;
  Claude only writes the prose, and is told the numbers rather than asked to
  count.
- **Context your agent already has.** Open Claude Code or Cursor in a mapped
  checkout and the repo's stack, run and test commands, linked repos and the
  team's notes are in the session before you type.
- **One directory per company**, so a freelancer keeps several clients side by
  side without mixing them.
- **No daemon, no database, no web app.** Bash, `gh`, `jq`, `fzf`, `gum`, a
  weekly timer, and plain files that diff cleanly in git.

*org + origami — folding a flat sheet of repositories into a shape you can see.*

## Install

One command. It installs what is missing, puts `orgami` on your PATH, and wires
up Claude Code and Cursor if they are on the machine.

**macOS, Linux, WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/achevalier-dev/orgami/main/bootstrap.sh | bash
```

**Windows** (PowerShell):

```powershell
irm https://raw.githubusercontent.com/achevalier-dev/orgami/main/bootstrap.ps1 | iex
```

Then:

```bash
gh auth login
orgami init     # map an organization — or `orgami join` to pick up one that exists
```

`--dry-run` prints every step without touching anything. Doing it by hand, or on
a machine the bootstrap cannot cover, is in
**[docs/install.md](docs/install.md)**.

## Use

```bash
orgami        # the menu
orgami init   # add a company, step by step
```

`orgami init` picks the organization from the ones your `gh` token can see, then
asks where the weekly report should be committed — an existing repo in that org,
a new one it creates for you (`orgami-reports` by default, private or public), a
git URL you type, or nowhere at all. It then builds the thing: this week's recap,
a scan of every repo, the architecture doc, and a first publish if you gave it a
docs repo. Ctrl-C stops the build and keeps the config. The last question is
whether to run it weekly. Bare `orgami` opens a menu over whichever company is
current — browse the map, read the last recap, write this week's, rebuild,
publish, switch org.

Every step is also a command, which is what the timer and any script should use:

```bash
orgami init acme --org acme-inc --docs-repo git@github.com:acme-inc/handbook.git
orgami pull            # cache this week's merged PRs
orgami report          # write reports/2026-W33.md
orgami scan            # clone every repo in parallel, rebuild the map
orgami doc             # render map/ARCHITECTURE.md
orgami view            # browse the map in the terminal
orgami publish         # commit both into the docs repo
```

`orgami weekly` runs that whole sequence. Schedule it per company with `orgami
schedule` — a systemd user timer on Linux, a launchd agent on macOS, and a cron
line to paste anywhere else. `orgami schedule --off` stops it.

Add the next client with another `orgami init`. Switch the default with `orgami
use beta-corp`, or set `ORGAMI_COMPANY=beta-corp` for a single command. If the
token sees more organizations than you care about, narrow the picker with
`ORGAMI_ORGS="acme-inc beta-corp"`, or keep `{ "orgs": [...] }` in
`~/.orgami/config.json`.

## The weekly recap

`orgami pull` pages the GitHub GraphQL search API for every PR the org merged
that week — body, diff size, labels, reviews, and review threads — and caches the
raw response under `cache/prs/`. Re-running a week overwrites only that week's
file.

`orgami report` then splits the work in two, and the split is the point:

- **`jq` computes every number.** PR counts, median diff size, median hours to
  merge, how many merged with no review at all, who reviews whom, which files
  keep attracting review threads. `lib/stats.jq`, deterministic, auditable.
  Run `orgami report --stats-only` to see just this.
- **Claude writes the prose**, and is told the numbers rather than asked to
  count. It groups PRs by *why they happened* instead of by repository, and
  writes a "How the team worked" section off the statistics — review
  concentration, PR hygiene, cycle time.

That division is deliberate. A model asked to both count and narrate will do
neither reliably, and a recap nobody trusts the numbers in is not worth writing.

## The map

`orgami scan` shallow-clones every non-archived, non-fork repo in the org and
pattern-matches what is committed — deploy tooling, servers, backing services,
repo-to-repo references, frameworks, run and test commands, routes, shared
environment contracts. The result is `map/graph.json`, a flat list of nodes and
edges; `ARCHITECTURE.md`, the mermaid diagrams and the terminal view are all
rendered from it.

**Every edge carries the `file:line` it came from.** Nothing in the graph is
inferred by a model, and every claim can be opened and checked.

```bash
orgami view              # browse it in the terminal
orgami query thruster    # one node and its edges, as text
```

Beside the map sit `CONVENTIONS.md` (every `AGENTS.md` in the org, gathered),
`DECISIONS.md` (mined from merged PRs, one fragment per week), `RUNBOOK.md` and
one runbook per repo, and `coupling.json` (which repos keep changing together).
Full detail: **[docs/map.md](docs/map.md)**.

## What an agent reads

With the plugin installed there is nothing to run — opening Claude Code in a
mapped checkout injects the repo's stack, commands, linked repos and team notes
at session start, and prints nothing at all outside one. For the whole page:

```bash
orgami context          # inside a checkout: that repo. anywhere else: the org.
orgami context <repo>   # by name
```

Cursor reaches the same parity through its `sessionStart` hook; anything that
speaks MCP gets the map as tools; anything that reads `AGENTS.md` can have the
context written into the repo. See **[docs/agents.md](docs/agents.md)**.

## Five people, one memory

The map and the recaps are generated. What a team knows is not — the cause
someone found at 2am, the reason the obvious fix does not work, the step missing
from the README.

```bash
orgami note "Copying the dashboard config into SSM by hand drops every user's apps[]."
orgami notes --repo WinIt-backend
orgami sync
```

Mostly you will not type that. When a session ends, orgami reads back what was
said and drafts a note if the session established something durable that is not
visible in the code. Nothing is published unattended — drafts wait in
`notes/draft/`, the next session says how many, and `orgami drafts` keeps or
throws each one away. Most sessions produce nothing, which is the intended
answer; the prompt is told so. Five a day at most, credentials stripped before
the transcript leaves the machine, and `ORGAMI_AUTONOTE=0` turns it off.

Notes are screened for credentials and for any *other* client configured on the
machine before they are written, and again before anything is pushed. They can
require a pull request to reach the team, and they can be superseded and pruned.
A colleague picks up an existing map with one `orgami join` — no scan, no
clones. See **[docs/notes.md](docs/notes.md)**.

## Cost

Two Claude calls a week: the recap, and the decision mining. One more if you use
`orgami doc --narrate`. Everything else is `gh`, `git`, `jq` and `grep`.
`orgami report --stats-only` costs nothing at all.

## Contributing

Bug reports and patches welcome — [CONTRIBUTING.md](CONTRIBUTING.md) covers how
to test orgami with no organization and no token, and what the shape of a good
change is. Issues labelled
[good first issue](https://github.com/achevalier-dev/orgami/labels/good%20first%20issue)
are the ones to start with. If the scan got your organization's shape wrong,
that is the most useful report there is.

## Docs

- [Installing by hand](docs/install.md) — per-distribution dependencies, WSL, the plugin
- [The map](docs/map.md) — what the scan looks for, and what it refuses to infer
- [Other agents](docs/agents.md) — Cursor, MCP clients, `AGENTS.md`
- [Team notes](docs/notes.md) — screening, review, pruning, `orgami join`
- [Layout](docs/layout.md) — every file in this repo, and the state it keeps

## Licence

MIT.
