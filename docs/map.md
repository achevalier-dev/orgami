# The map

`orgami scan` shallow-clones every non-archived, non-fork repo in the org — eight
at a time behind a progress bar, `--jobs N` to change that — and pattern-matches
what is committed:

| Looking for | Where |
|---|---|
| Deployment tooling | `.github/workflows` actions, `Dockerfile`, `config/deploy.yml` (Kamal), `fly.toml`, `vercel.json`, `netlify.toml`, `render.yaml`, `serverless.yml`, `Chart.yaml`, `Procfile`, `*.tf`, `ansible.cfg`, Kubernetes manifests, `.gitlab-ci.yml`, `Jenkinsfile`, `.circleci/config.yml` |
| Servers and endpoints | Kamal `servers:`, Fly app names, Kubernetes ingress hosts, `.env.example` |
| Backing services | `docker-compose.yml` images, `*_URL` / `*_HOST` names in `.env.example` |
| Third-party vendors | dependency manifests, `.env.example` variable names, literal URLs, terraform providers and workflow actions, matched against `lib/vendors.tsv` |
| Third-party accounts | not from the scan at all — `orgami dns` reads the organization's public DNS for verification tokens, MX, SPF, DMARC, conventional CNAMEs and nameservers, against the same `lib/vendors.tsv`. Its own file, its own clock: [docs/dns.md](dns.md) |
| Repo-to-repo links | `github.com/org/other`, `ghcr.io/org/other`, `@org/other`, and dependency manifests naming a sibling repo |
| What a repo is | framework (Next.js, NestJS, Express, Rails, Django, FastAPI, Parse, Go, …), package manager, runtime version |
| How to work on it | `package.json` scripts, Makefile targets, `bin/setup`-style scripts, Procfile process types |
| What it serves | Express/Nest/Fastify routes, Next.js API routes and route handlers, Parse cloud functions, Flask and FastAPI decorators, Rails routes |
| What it calls | literal URLs in source, matched against the hosts other repos declare as their own |
| Shared contracts | distinctive environment variables read by more than one repo |

The result is `map/graph.json` — a flat list of nodes and edges, nothing else.
`ARCHITECTURE.md`, the mermaid diagrams, `graph.html` and the terminal view are
all rendered from it, so there is one source of truth and it diffs cleanly week
to week.

**Nothing in the graph is inferred by a model**, and `orgami doc --narrate` adds
one Claude-written summary paragraph on top, clearly separated from the facts
underneath it.

## Extracted and inferred

Most edges are *extracted*: a literal string sat in a committed file, and the
edge carries the `file:line` you can open. A few are *inferred*: nothing
declared them, they were resolved by matching one repo's reading against
another's. Every edge says which it is, in a `confidence` field, and everything
that renders the graph says it too.

| Edge | Why |
|---|---|
| `calls` | inferred — a repo's literal URL matched a host exactly one other repo claims as its own |
| `shares-config` | inferred — two repos read the same distinctive environment variable name |
| `changes-with` | inferred — the two keep landing pull requests in the same week |
| `imports` | either — extracted when the specifier names the organization, inferred when a bare name merely equals a repo name |
| everything else | extracted — `uses`, `deploys-to`, `depends-on`, `reaches`, `references` all point at a file |

Both kinds are worth having. Only one of them can be checked, and a map that
does not say which is which is quietly lying about the difference. In
`ARCHITECTURE.md` an inferred edge is a dotted arrow and carries *(inferred)* in
the evidence list; in `orgami view` and `orgami query` it is prefixed `~`; in
`graph.html` it is a dashed line you can switch off entirely.

An edge written before the field existed still reads correctly: `calls`,
`shares-config` and `changes-with` are only ever produced by resolution, so
that is how they are reported.

What the scan cannot see, it does not invent. Services wired together by runtime
environment variables, a service mesh, or a shared gateway leave no trace in a
repository, so a missing edge means "not found in committed configuration" and
never "not connected".

## The map as a picture

`orgami doc` also writes `map/graph.html` — the same graph, force-directed, in
one file you can open. It is generated from `graph.json` and nothing else, and
it is self-contained: no CDN, no fonts, no network at all, so it works from a
`file://` URL, inside a private repository, and on a plane.

```bash
orgami html     # just the page, without re-rendering the rest
```

Click a node and the panel shows both directions of every edge with the evidence
it came from and whether that evidence is a line you can open. Type to filter,
switch node kinds on and off, and switch inferred edges off when you only want
what is written down. Layout is seeded from the node names, so the same map
draws the same way on every machine — a screenshot in a pull request matches
what the next person sees.

`orgami publish` commits it beside `ARCHITECTURE.md`.

## The terminal view

`orgami view` opens the map, the repos, the team's notes and the recaps as one
screen: a list on the left, a preview on the right, and a header that says how
stale the map is and whether this week has a recap yet.

```
orgami · acme · acme-inc                                    mapped yesterday
 Map │ Repos │ Notes │ Recaps                 44 repos · 348 edges · recap 2026-W33
map ›                                                                    53/53
  ▪ billing-api        repo    Go          Payments and webhook delivery
  ▪ web                repo    TypeScript  Customer dashboard
  ◆ api.acme.com       host
  ◈ kamal              tool
  ▣ postgres           service
 tab switch · type filter · enter print · ctrl-o github · ctrl-n note · esc quit
```

Four tabs, `tab` and `shift-tab` between them:

| Tab | What the list holds | What the preview shows |
|---|---|---|
| **Map** | every node — repos first, then languages, tools, services, vendors and hosts | the node, and both directions of every edge that named it |
| **Repos** | one row per repo: language, runtime, how many edges touch it, when it was last pushed | the repo's card — how to run it, what it talks to, where it ships, what it serves, what it reads, and the team's notes on it |
| **Notes** | what the team has recorded, newest first | the note, its author and its age |
| **Recaps** | every weekly recap on disk | the recap, through `glow` when it is installed |

Typing filters the list. `enter` prints whatever is under the cursor into your
scrollback, so it can be copied or piped. `ctrl-o` opens the repo on GitHub,
`ctrl-n` writes a note already attached to the repo you are looking at, `ctrl-r`
re-reads the map from disk, and `esc` leaves.

Every pane is a subcommand underneath, which is why the same text comes back
outside the app:

```bash
orgami query thruster    # one node and its edges, as text
orgami query kamal
orgami query 51.158.10.20
```

Colour is on when a terminal is attached and off when the output is piped, so
`orgami query x | grep` stays clean. `NO_COLOR` turns it off everywhere.

## The files beside the map

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
- **`depth.json`** — the symbol layer, when `orgami depth` has run: what each
  repo exports and where, and which packages it imports most.
- **`coupling.json`** — which repos keep landing changes together, counted by
  same-day and same-week co-occurrence, bots excluded. Correlation, not
  dependency, and labelled as such — but it is the blast radius no static scan
  can see, and it sharpens every week the timer runs.

## Deeper than the scan goes

Everything above is pattern-matched, which is what keeps it cheap and portable.
`orgami depth` parses instead — every file through a tree-sitter grammar — and
answers the questions a pattern match cannot: which repo defines a symbol, what
each repo actually exports, and which imports really are cross-repo references.
It needs grammars installed, so it is optional and lives in its own file:
[docs/depth.md](depth.md).

## What the scan will not tell you

Everything above comes from committed files, which is what makes it checkable
and the same for everyone. It is also why the map can say a repo is *configured*
to deploy somewhere and not whether it still does. `orgami live` asks the
providers themselves and keeps the answer in its own file, on its own clock —
[docs/live.md](live.md).

It is also why the map names the vendors the code *calls* and none of the ones
it merely has an account with. Nothing in a repository mentions Google
Workspace, the applicant tracker or the e-signature seats. `orgami dns` reads
those out of the organization's own public DNS, into `map/dns.json` — also its
own file, because a DNS reading has no `file:line` either, though unlike a cloud
reading anyone can re-run the `dig` and check it. [docs/dns.md](dns.md).
