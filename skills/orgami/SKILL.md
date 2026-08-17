---
name: orgami
description: Load organization context before working on a client's repository — what a repo is, how to run and test it, which repos it talks to, which ones change with it, the org's own conventions, and the decisions already made. Use when starting work in a repo that belongs to a mapped GitHub organization, when asked how services connect, where something is deployed, which repo owns a behavior, what changed recently, or why something is the way it is. Triggers: "how does X talk to Y", "where is this deployed", "how do I run this", "what server runs", "which repo handles", "what shipped last week", "why do we do it this way", "map of the org", "architecture", client or company names configured in orgami.
---

# orgami

`orgami` keeps a scanned map of a GitHub organization, a page per repository,
the org's own agent instructions, decisions mined from merged pull requests, and
weekly recaps. Read from it before guessing, and before asking the user to
explain their own system.

State lives in `~/.orgami/<company>/`. One directory per company, so a freelancer
can hold several clients at once.

## Start here

```bash
orgami context
```

Run it inside a checkout and it prints that repo's page. Run it anywhere else
and it prints the organization overview. `orgami context <repo>` names one
directly. This is the first thing to run when work begins in an unfamiliar repo
— one command, one screen, no file hunting.

The repo page carries: language and framework, the exact commands to run, build
and test it, what it talks to and what talks to it, the endpoints it serves,
the environment it reads, where it deploys, which repos it usually changes with,
its recent merged pull requests, and links to any `AGENTS.md` it already has.

## When you need more

| Question | Where |
|---|---|
| One repo, in depth | `orgami card <repo>`, or `~/.orgami/<c>/map/repos/<repo>.md` |
| One node and its edges | `orgami query <repo\|host\|tool\|service>` |
| The whole org | `~/.orgami/<c>/map/ARCHITECTURE.md` |
| How they write code here | `~/.orgami/<c>/map/CONVENTIONS.md` |
| Why something is the way it is | `~/.orgami/<c>/map/DECISIONS.md` |
| What shipped recently | `~/.orgami/<c>/reports/*.md`, newest last |
| Anything needing a filter | `~/.orgami/<c>/map/graph.json`, `repos.json`, `coupling.json` |

`CONVENTIONS.md` is the one to read before writing code: it gathers every
`AGENTS.md`, `CLAUDE.md` and `CONTRIBUTING.md` committed in the org, with the
`.github` repo's version marked as the org-wide default. A repo's own file wins
over the default.

`DECISIONS.md` answers "why is it like this" — technology choices, constraints
accepted, things deprecated — each bullet carrying the pull request it came
from. Read it before proposing a change that might already have been decided
against.

## Picking the company

`orgami context` matches the checkout to a company by its git remote on its own.
When that fails, or when you are outside a checkout:

```bash
orgami list                       # the starred line is the default
ORGAMI_COMPANY=<name> orgami ...  # for one command
```

Set `ORGAMI_COMPANY` per command rather than changing the default — the default
is the user's, not yours.

## Graph shape

`graph.json` nodes are `{id, kind, name, meta}` where `kind` is `repo`, `host`,
`tool`, `service` or `lang`. Edges are `{from, to, kind, evidence}`:

- `references` — a repo names another in a manifest or URL
- `calls` — a repo hits a host that exactly one other repo declares as its own
- `shares-config` — two repos read the same distinctive environment variable
- `changes-with` — the two keep landing pull requests together
- `uses`, `deploys-to`, `depends-on`, `reaches`, `written-in`

## Trusting it

Every edge stores the `file:line`, URL or pull request it came from. Before
acting on a host, a dependency or a claimed link, open that evidence and confirm.
Say where a claim came from when you report it.

Three limits worth stating out loud rather than papering over:

- **The scan sees only what is committed.** Services wired together at runtime —
  environment variables set in a dashboard, a service mesh, a gateway — leave no
  trace. A missing edge means "not found in committed configuration", never
  "not connected".
- **`changes-with` is correlation.** It comes from who merged what in the same
  week; it is a hint about blast radius, not a dependency.
- **`generated` in `graph.json` is when the scan last ran.** If it is more than
  a week old and the question is load-bearing, say the map is stale.

## Refreshing

```bash
orgami pull && orgami report   # this week's PRs, the recap, new decisions
orgami scan && orgami doc      # rebuild the map, the cards, the conventions
orgami coupling                # recompute what changes together
```

`orgami scan` shallow-clones every repo in the org. It takes minutes and hits the
network — run it when the user asks, not on your own initiative.

`orgami publish` commits everything to the client's docs repo and pushes. Never
run it unless the user asks for it in that turn.
