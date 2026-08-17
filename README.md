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

```bash
git clone https://github.com/achevalier-dev/orgami ~/orgami
cd ~/orgami && ./install.sh
```

Needs `gh` (authenticated), `jq`, `git`, `fzf`, `gum` and `claude` on PATH.

## Use

```bash
orgami        # the menu
orgami init   # add a company, step by step
```

`orgami init` picks the organization from the ones your `gh` token can see, then
asks where the weekly report should be committed — an existing repo in that org,
a new one it creates for you (`orgami-reports` by default, private or public),
a git URL you type, or nowhere at all. It ends by offering the first recap, the
first scan and the weekly timer, one confirm each. Bare
`orgami` opens a menu over whichever company is current — browse the map, read
the last recap, write this week's, rebuild, publish, switch org.

Both need [gum](https://github.com/charmbracelet/gum). Everything below works
without it, and is what the timer and any script should use:

```bash
orgami init acme --org acme-inc --docs-repo git@github.com:acme-inc/handbook.git
orgami pull            # cache this week's merged PRs
orgami report          # write reports/2026-W33.md
orgami scan            # shallow-clone every repo, rebuild the map
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

`orgami scan` shallow-clones every non-archived, non-fork repo in the org and
pattern-matches what is committed:

| Looking for | Where |
|---|---|
| Deployment tooling | `.github/workflows` actions, `Dockerfile`, `config/deploy.yml` (Kamal), `fly.toml`, `vercel.json`, `netlify.toml`, `render.yaml`, `serverless.yml`, `Chart.yaml`, `Procfile`, `*.tf`, `ansible.cfg`, Kubernetes manifests, `.gitlab-ci.yml`, `Jenkinsfile`, `.circleci/config.yml` |
| Servers and endpoints | Kamal `servers:`, Fly app names, Kubernetes ingress hosts, `.env.example` |
| Backing services | `docker-compose.yml` images, `*_URL` / `*_HOST` names in `.env.example` |
| Repo-to-repo links | `github.com/org/other`, `ghcr.io/org/other`, `@org/other`, and dependency manifests naming a sibling repo |

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

## Claude Code context

`install.sh` links a skill into `~/.claude/skills/orgami/`. Claude reads it
when a question turns architectural — where something is deployed, how two
services talk, which repo owns a behavior, what shipped recently — and answers
from the map instead of guessing, citing the evidence line for anything it
claims.

The skill tells Claude to match the checkout to a company by its git remote, to
say when the map is stale rather than trusting it silently, and never to run
`orgami publish` on its own.

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
lib/ui.sh              the menu and the setup wizard
lib/publish.sh         commit to the docs repo, weekly runner
prompts/recap.md       the recap prompt
skills/orgami/         the Claude Code skill
systemd/               orgami-weekly@.service and .timer
```

Company state, never in this repo:

```
~/.orgami/<company>/
  config.json          org, docs repo, include/exclude, model
  cache/prs/           raw GraphQL responses, one file per week
  cache/repos/         the org's repo list
  cache/src/           shallow clones
  cache/docs/          the docs repo checkout
  reports/             one markdown recap per week
  map/graph.json       nodes and edges
  map/ARCHITECTURE.md  rendered from the graph
```

## Cost

One Claude call per weekly report, one more if you use `orgami doc --narrate`.
Everything else is `gh`, `git`, `jq` and `grep`. `orgami report --stats-only`
costs nothing at all.

## Licence

MIT.
