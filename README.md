# orgami

[![ci](https://github.com/achevalier-dev/orgami/actions/workflows/ci.yml/badge.svg)](https://github.com/achevalier-dev/orgami/actions/workflows/ci.yml)
[![licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)
[![shell: bash](https://img.shields.io/badge/shell-bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-d97757.svg)](docs/agents.md)

**Ten repos, eight people, and nobody whose job it is to write the docs.**
orgami maps every repository in your GitHub organization — what each one is, how
to run it, what it talks to, where it deploys — digests what the team shipped
today and this week, keeps the things you only learn once, and hands all of it to
your coding agent at session start.

![orgami: the context an agent is handed, one node and its evidence, the map in
the terminal, and the week's numbers](docs/demo.gif)

<sub>Recorded against a public organization ([honojs](https://github.com/honojs))
with `vhs docs/demo.tape` — every line in it came out of a committed file.</sub>

It is built for the size of team where everyone touches everything: no architect
holding the diagram, no wiki that survived the last three months, and a new hire
or a coding agent expected to be useful on day one.

- **A map you can check.** Every edge carries the `file:line` it came from, so
  nothing in it is a model's guess. A missing edge means "not found in committed
  configuration", never "not connected".
- **Digests you can trust the numbers in.** `jq` computes every figure; Claude
  only writes the prose, and is told the numbers rather than asked to count.
- **One memory for the team.** The cause someone found at 2am gets written down
  once — often without anyone typing it — and everyone's agent reads it.
- **Nothing to run.** Open Claude Code or Cursor in a mapped checkout and the
  repo's stack, commands, linked repos and notes are already in the session.
- **No daemon, no database, no web app.** Bash, `gh`, `jq`, `fzf`, `gum`, a
  timer, and plain files that diff cleanly in git.

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

Then, once, on one machine:

```bash
gh auth login
orgami init     # map your organization
```

Everyone else on the team runs `orgami join` and picks it up — no scan, no
clones. `--dry-run` prints every step without touching anything; installing by
hand is in **[docs/install.md](docs/install.md)**.

## Use

```bash
orgami        # the menu
orgami init   # map your organization, step by step
```

`orgami init` picks the organization from the ones your `gh` token can see, then
asks where the reports should be committed — an existing repo in the org, a new
one it creates for you (`orgami-reports` by default, private or public), a git
URL you type, or nowhere at all. It then builds the thing: this week's recap, a
scan of every repo, the architecture doc, and a first publish if you gave it a
docs repo. Ctrl-C stops the build and keeps the config. The last questions are
whether to run it weekly and whether to send a digest each morning.

Bare `orgami` opens a menu: browse the map, read the last recap, write this
week's, rebuild, publish. Every step is also a command, which is what the timer
and any script should use:

```bash
orgami pull            # cache this week's merged PRs
orgami report          # write reports/2026-W33.md
orgami scan            # clone every repo in parallel, rebuild the map
orgami doc             # render map/ARCHITECTURE.md
orgami view            # browse the map in the terminal
orgami publish         # commit both into the docs repo
```

`orgami weekly` runs that whole sequence; `orgami schedule` puts it on a systemd
user timer, a launchd agent, or a cron line you paste anywhere else.

`orgami help` is ten commands — the ones you use. `orgami help --all` is the
rest: note review, MCP, per-repo runbooks, coupling, pruning.

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
orgami view              # the map, the repos, the notes and the recaps, in one screen
orgami query thruster    # one node and its edges, as text
```

`orgami view` is four tabs over the same data — Map, Repos, Notes, Recaps —
with the evidence in the preview pane, `ctrl-o` to open a repo on GitHub and
`ctrl-n` to write a note against the one you are reading.

### And what is actually running

The map says a repo is *configured* to deploy to Fly. It does not say the app
still exists, what domain it answers on, or that anyone has deployed it since
March. `orgami live` asks the providers — Vercel, Fly, AWS — and writes
`map/live.json`.

```bash
orgami live                            # every provider the map already names
orgami live --provider vercel,fly      # only these
```

It is a separate command on a separate file for a reason: a reading from a cloud
account expires, needs credentials not everyone has, and has no `file:line` to
open. So every row carries the age of the reading and the account it came from,
after a week it stops being injected into agent context, and `orgami publish`
leaves it on your machine unless you ask for it.

**Nothing is attributed by resemblance.** `api-staging` is not assigned to
`api`. A deployment is tied to a repo only when the map already has a
`deploys-to` edge to that host, when the provider itself names the GitHub
repository, or when a resource is tagged with one. Everything else is reported
as unmatched, with its state and hostname — which is usually the interesting
part: on the first real account this ran against, all 30 running things were
unaccounted for, including seven preview environments nobody had cleaned up.
Names and endpoints only; no environment values, ever.
**[docs/live.md](docs/live.md)**.

Beside the map sit `CONVENTIONS.md` (every `AGENTS.md` in the org, gathered),
`DECISIONS.md` (mined from merged PRs, one fragment per week), `RUNBOOK.md` and
one runbook per repo, and `coupling.json` (which repos keep changing together).
Full detail: **[docs/map.md](docs/map.md)**.

## The digests

**Each morning.** A day is not a week in miniature: most of a day's work has not
merged yet. So `orgami daily` reads four things — what merged, what opened, what
is sitting open with nobody on it, and commits that never became a pull request
at all, which is the half a merge-based recap cannot see.

```bash
orgami daily                  # today, so far
orgami daily --yesterday      # what the timer runs each weekday morning
orgami daily --stats-only     # the numbers, no model call, no cost
```

**A quiet day produces no file** — a digest that says "nothing happened" every
weekend teaches people to stop opening it. It is a setting on the org, not a
habit you have to remember: `orgami init` asks once, the menu toggles it, and
either way it is two keys in the config, so a second machine agrees.

```bash
orgami schedule --daily              # weekday mornings
orgami schedule --daily --at 09:00   # move it
orgami schedule --daily --off        # stop it; the digests already written stay
```

**Each week.** `orgami pull` pages the GitHub GraphQL search API for every PR the
org merged that week — body, diff size, labels, reviews, review threads — and
`orgami report` splits the work in two, which is the point:

- **`jq` computes every number.** PR counts, median diff size, median hours to
  merge, how many merged with no review at all, who reviews whom, which files
  keep attracting review threads. `lib/stats.jq`, deterministic, auditable.
  `orgami report --stats-only` shows just this, and costs nothing.
- **Claude writes the prose**, and is told the numbers rather than asked to
  count. It groups PRs by *why they happened* instead of by repository, and
  writes a "How the team worked" section off the statistics — review
  concentration, PR hygiene, cycle time.

A model asked to both count and narrate will do neither reliably, and a digest
nobody trusts the numbers in is not worth writing.

## One memory for the team

The map and the digests are generated. What a team knows is not — the cause
someone found at 2am, the reason the obvious fix does not work, the step missing
from the README. On a team this size that knowledge lives in one or two heads,
and leaves with them.

```bash
orgami note "Copying the dashboard config into SSM by hand drops every user's apps[]."
orgami notes --repo billing-api
orgami sync
```

Mostly you will not type that. When a session ends, orgami reads back what was
said and writes a note if the session established something durable that is not
visible in the code. Most sessions produce nothing, which is the intended answer;
the prompt is told so. Five a day at most, credentials stripped before the
transcript leaves the machine, and `ORGAMI_AUTONOTE=0` turns it off.

```bash
orgami autonote            # what it does today
orgami autonote publish    # send them to the team as they are written
orgami autonote drafts     # hold them for you instead
```

Held is the default: a note carries your name, so publishing one unattended is
your call. Held notes wait in `notes/draft/`, the next session says how many are
waiting, and `orgami drafts` keeps or throws each one away. Set to publish, they
go out as they are written — as a pull request when `notes_review` is on, which
is the combination worth having: nobody writes the note, and the team can still
turn one down.

Notes are screened for credentials before they are written and again before
anything is pushed, they can require a pull request to reach the team, and they
can be superseded and pruned. See **[docs/notes.md](docs/notes.md)**.

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

## More than one organization

orgami assumes one. If you carry a second — a consultancy, a side project, an
acquired org — `orgami init` again gives it its own directory under
`~/.orgami`, `orgami use <name>` switches the default, and
`ORGAMI_COMPANY=<name>` runs a single command against the other. Notes are
screened against every org configured on the machine, so nothing crosses.

## Cost

Two Claude calls a week — the recap and the decision mining — plus one short one
per weekday morning if the daily digest is on. One more if you use `orgami doc
--narrate`. Everything else — the scan, the map, `orgami live`, every
`--stats-only` run — is `gh`, `git`, `jq` and `grep`, and costs nothing at all.

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
- [What is running](docs/live.md) — `orgami live`, the providers, and why it is kept apart
- [Other agents](docs/agents.md) — Cursor, MCP clients, `AGENTS.md`
- [Team notes](docs/notes.md) — screening, review, pruning, `orgami join`
- [Layout](docs/layout.md) — every file in this repo, and the state it keeps

## Licence

MIT.
