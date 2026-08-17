# orgami

A weekly recap of every pull request an organization merged, and a map of how
its repositories, deployment tooling and servers fit together — both readable in
the terminal, both committed to a docs repo, and both loaded as context by Claude
Code before it touches a client's code.

One directory per company under `~/.orgami`, so a freelancer can keep several
clients side by side without mixing them.

No daemon, no database, no web app. Bash, `gh`, `jq`, `fzf`, `gum`, a systemd user
timer, and plain files that diff cleanly in git.

*org + origami — folding a flat sheet of repositories into a shape you can see.*

## Install

In Claude Code:

```
/plugin marketplace add achevalier-dev/orgami
/plugin install orgami@orgami
```

Then ask Claude to run the installer it mentions, or do it yourself:

```bash
~/.claude/plugins/marketplaces/orgami/install.sh
```

The plugin brings the skill, the `/orgami:context` and `/orgami:note` commands, and a
`SessionStart` hook that hands Claude the context for whatever repo you opened —
framework, run and test commands, linked repos, and the team's notes on it —
before you type anything. The installer puts the `orgami` CLI on your PATH and
installs the weekly timer.

Without Claude Code, or for a server that only runs the weekly job:

```bash
git clone https://github.com/achevalier-dev/orgami ~/orgami
cd ~/orgami && ./install.sh
```

Needs `gh` (authenticated), `jq`, `git`, `fzf`, `gum` and `claude` on PATH.

Then either map an org yourself with `orgami init`, or pick up one a colleague
has already mapped with `orgami join`.

## Use

```bash
orgami        # the menu
orgami init   # add a company, step by step
```

`orgami init` picks the organization from the ones your `gh` token can see, then
asks where the weekly report should be committed — an existing repo in that org,
a new one it creates for you (`orgami-reports` by default, private or public),
a git URL you type, or nowhere at all. It then builds the thing: this week's
recap, a scan of every repo, the architecture doc, and a first publish if you
gave it a docs repo. Ctrl-C stops the build and keeps the config. The last
question is whether to run it weekly. Bare
`orgami` opens a menu over whichever company is current — browse the map, read
the last recap, write this week's, rebuild, publish, switch org.

If the token sees more organizations than you care about, narrow the picker:

```bash
ORGAMI_ORGS="acme-inc beta-corp" orgami init
```

or keep it permanently in `~/.orgami/config.json`:

```json
{ "orgs": ["acme-inc", "beta-corp"] }
```

"type another…" still reaches every other org.

Both need [gum](https://github.com/charmbracelet/gum). Everything below works
without it, and is what the timer and any script should use:

```bash
orgami init acme --org acme-inc --docs-repo git@github.com:acme-inc/handbook.git
orgami pull            # cache this week's merged PRs
orgami report          # write reports/2026-W33.md
orgami scan            # clone every repo in parallel, rebuild the map
orgami doc             # render map/ARCHITECTURE.md
orgami view            # browse the map in the terminal
orgami publish         # commit both into the docs repo
```

`orgami weekly` runs that whole sequence. Schedule it per company:

```bash
systemctl --user enable --now orgami-weekly@acme.timer
```

Add the next client with another `orgami init`. Switch the default with
`orgami use beta-corp`, or set `ORGAMI_COMPANY=beta-corp` for a single command.

## The weekly recap

`orgami pull` pages the GitHub GraphQL search API for every PR the org merged
that week — body, diff size, labels, reviews, and review threads — and caches
the raw response under `cache/prs/`. Re-running a week overwrites only that
week's file.

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

`orgami scan` shallow-clones every non-archived, non-fork repo in the org — eight
at a time behind a progress bar, `--jobs N` to change that — and pattern-matches
what is committed:

| Looking for | Where |
|---|---|
| Deployment tooling | `.github/workflows` actions, `Dockerfile`, `config/deploy.yml` (Kamal), `fly.toml`, `vercel.json`, `netlify.toml`, `render.yaml`, `serverless.yml`, `Chart.yaml`, `Procfile`, `*.tf`, `ansible.cfg`, Kubernetes manifests, `.gitlab-ci.yml`, `Jenkinsfile`, `.circleci/config.yml` |
| Servers and endpoints | Kamal `servers:`, Fly app names, Kubernetes ingress hosts, `.env.example` |
| Backing services | `docker-compose.yml` images, `*_URL` / `*_HOST` names in `.env.example` |
| Repo-to-repo links | `github.com/org/other`, `ghcr.io/org/other`, `@org/other`, and dependency manifests naming a sibling repo |
| What a repo is | framework (Next.js, NestJS, Express, Rails, Django, FastAPI, Parse, Go, …), package manager, runtime version |
| How to work on it | `package.json` scripts, Makefile targets, `bin/setup`-style scripts, Procfile process types |
| What it serves | Express/Nest/Fastify routes, Next.js API routes and route handlers, Parse cloud functions, Flask and FastAPI decorators, Rails routes |
| What it calls | literal URLs in source, matched against the hosts other repos declare as their own |
| Shared contracts | distinctive environment variables read by more than one repo |

The result is `map/graph.json` — a flat list of nodes and edges, nothing else.
`ARCHITECTURE.md`, the mermaid diagrams and the terminal view are all rendered
from it, so there is one source of truth and it diffs cleanly week to week.

**Every edge carries the `file:line` it came from.** Nothing in the graph is
inferred by a model, and every claim can be opened and checked. `orgami doc
--narrate` adds one Claude-written summary paragraph on top — clearly separated
from the facts underneath it.

What the scan cannot see, it does not invent. Services wired together by runtime
environment variables, a service mesh, or a shared gateway leave no trace in a
repository, so a missing edge means "not found in committed configuration" and
never "not connected".

## The terminal view

`orgami view` lists every node — repos first, then languages, tools, services
and hosts — with the node's metadata and both directions of its edges in the
preview pane. Type to filter, `ctrl-o` opens the repo on GitHub, `enter` prints
the node into your scrollback.

For one node without the TUI:

```bash
orgami query thruster
orgami query kamal
orgami query 51.158.10.20
```

## What an agent reads

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

Three files sit alongside the map and answer the questions a map cannot:

- **`CONVENTIONS.md`** — every `AGENTS.md`, `CLAUDE.md` and `CONTRIBUTING.md`
  committed anywhere in the org, with the `.github` repo's copy marked as the
  org-wide default. An agent reads how this team writes code without opening
  forty repositories.
- **`DECISIONS.md`** — durable decisions mined from merged pull requests each
  week: what was adopted or dropped, what constraint was accepted, what was
  rejected and why. One fragment per week, so the record only grows. Every
  bullet carries its pull request.
- **`coupling.json`** — which repos keep landing changes together, counted by
  same-day and same-week co-occurrence, bots excluded. Correlation, not
  dependency, and labelled as such — but it is the blast radius no static scan
  can see, and it sharpens every week the timer runs.

`install.sh` links a skill into `~/.claude/skills/orgami/` that teaches Claude to
run `orgami context` first, cite the evidence line for anything it claims, say
when the map is stale rather than trusting it silently, distinguish "not found in
committed configuration" from "not connected", and never run `orgami publish` on
its own.

There is no MCP server. The CLI plus a skill covers the same ground with less to
install and less to break; an MCP wrapper is a thin shim over these commands if
a non-Claude-Code client ever needs one.

## Layout

```
bin/orgami             dispatcher
lib/common.sh          paths, config, company selection
lib/init.sh            init / use / list
lib/pull.sh            GraphQL fetch of merged PRs
lib/prs.graphql        the query
lib/stats.jq           every number in the report
lib/report.sh          stats + Claude -> reports/
lib/scan.sh            repo scan -> map/graph.json
lib/doc.sh             graph.json -> ARCHITECTURE.md
lib/view.sh            fzf TUI, query, open
lib/profile.sh         what a repo is: framework, commands, env, routes
lib/card.sh            repo pages and `orgami context`
lib/coupling.sh        which repos change together
lib/ui.sh              the menu and the setup wizard
lib/publish.sh         commit to the docs repo, weekly runner
prompts/recap.md       the recap prompt
prompts/decisions.md   the decision-mining prompt
hooks/                 the SessionStart hook
commands/              /orgami:context and /orgami:note
.claude-plugin/        plugin and marketplace manifests
skills/orgami/         the Claude Code skill
systemd/               orgami-weekly@.service and .timer
```

Company state, never in this repo:

```
~/.orgami/
  config.json          default company, and an optional "orgs" picker filter
~/.orgami/<company>/
  config.json          org, docs repo, include/exclude, model
  cache/prs/           raw GraphQL responses, one file per week
  cache/repos/         the org's repo list
  cache/src/           shallow clones
  cache/docs/          the docs repo checkout
  reports/             one markdown recap per week
  map/graph.json       nodes and edges
  map/repos.json       one profile per repo
  map/coupling.json    which repos change together
  map/ARCHITECTURE.md  rendered from the graph
  map/CONVENTIONS.md   the org's own agent instructions, gathered
  map/DECISIONS.md     decisions mined from pull requests, one section per week
  map/repos/<repo>.md  a page per repo
  map/decisions/       one fragment per week, assembled into DECISIONS.md
```

## Five people, one memory

The map and the recaps are generated. What a team knows is not — the cause
someone found at 2am, the reason the obvious fix does not work, the step missing
from the README. `orgami note` records that, and the docs repo syncs it.

```bash
orgami note "Parse Dashboard config lives in WinIt-ParseDashboard/index.js,
             not the fork. Copying it into SSM by hand drops every user's apps[]."
orgami notes --repo WinIt-backend
orgami sync
```

Run inside a checkout, a note attaches itself to that repo, and from then on it
appears on the repo's page — so the next person's agent reads it before touching
the code. Each note is its own file, named by timestamp and author, so five
people writing at once never produce a conflict. `orgami sync` runs on its own as
part of `orgami weekly`.

A colleague does not need to scan anything, or know where the map lives:

```bash
orgami join
```

Pick the organization and it finds the repo that already holds a map — probing
every repo in the org in parallel, a couple of seconds — then pulls the map, the
cards, the conventions, the decisions and every note out of it. One command
instead of forty clones. Only whoever runs the weekly timer needs the checkouts.

`orgami join <company> --repo <url> [--path <dir>]` skips the questions, for
scripts and for a docs repo that lives outside the org.

## Cost

Two Claude calls a week: the recap, and the decision mining. One more if you use
`orgami doc --narrate`.
Everything else is `gh`, `git`, `jq` and `grep`. `orgami report --stats-only`
costs nothing at all.

## Licence

MIT.
