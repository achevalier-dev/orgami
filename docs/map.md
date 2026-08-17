# The map

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

## The four files beside the map

- **`CONVENTIONS.md`** — every `AGENTS.md`, `CLAUDE.md` and `CONTRIBUTING.md`
  committed anywhere in the org, with the `.github` repo's copy marked as the
  org-wide default. An agent reads how this team writes code without opening
  forty repositories.
- **`DECISIONS.md`** — durable decisions mined from merged pull requests each
  week: what was adopted or dropped, what constraint was accepted, what was
  rejected and why. One fragment per week, so the record only grows. Every
  bullet carries its pull request.
- **`RUNBOOK.md` and `runbooks/<repo>.md`** — the operational half. Per repo:
  how to run it, which workflow ships it and on what trigger, the health
  endpoint it serves, where its alerts go, what it drags with it when it
  changes, and what the recaps already recorded as *do not*. A repo with no
  deploying workflow says so — that is a finding, not a blank. Six note tags
  (`setup`, `deploy`, `rollback`, `incident`, `gotcha`, `oncall`) file a note
  straight into the matching section, so the page gets better every time
  somebody loses an afternoon and writes it down.
- **`coupling.json`** — which repos keep landing changes together, counted by
  same-day and same-week co-occurrence, bots excluded. Correlation, not
  dependency, and labelled as such — but it is the blast radius no static scan
  can see, and it sharpens every week the timer runs.
