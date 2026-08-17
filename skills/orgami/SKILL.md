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

With the plugin installed a short version of this is already in your context from
session start; run the command when you need the full page.

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
| What teammates hit before you | `orgami notes`, `orgami notes --repo <repo>` |
| How to run, ship or unbreak it | `orgami runbook <repo>`, or `~/.orgami/<c>/map/runbooks/<repo>.md` |
| How anything ships, org-wide | `~/.orgami/<c>/map/RUNBOOK.md` |
| Anything needing a filter | `~/.orgami/<c>/map/graph.json`, `repos.json`, `coupling.json` |

`CONVENTIONS.md` is the one to read before writing code: it gathers every
`AGENTS.md`, `CLAUDE.md` and `CONTRIBUTING.md` committed in the org, with the
`.github` repo's version marked as the org-wide default. A repo's own file wins
over the default.

`DECISIONS.md` answers "why is it like this" — technology choices, constraints
accepted, things deprecated — each bullet carrying the pull request it came
from. Read it before proposing a change that might already have been decided
against.

## Runbooks

`orgami runbook <repo>` answers the operational questions: what runs it, what
ships it and on which trigger, which health endpoint it serves, where its alerts
go, what changes alongside it, and what the weekly recaps recorded as *do not*.
All of it derived and cited — no model wrote any of it.

A repo with no deploying workflow says so plainly. That is a real finding, not a
gap: it means shipping happens somewhere the scan cannot see, and it is worth
asking the user and recording the answer.

Six note tags file straight into a runbook section — `setup`, `deploy`,
`rollback`, `incident`, `gotcha`, `oncall`:

```bash
orgami note --repo scraphome --tag rollback "Re-run the previous deploy workflow from its commit"
```

**When you learn something operational the runbook does not have** — how to roll
back, the real first thing to check when it breaks, a prerequisite nobody wrote
down — offer to record it with the matching tag. It lands in that repo's runbook
for everyone the next time `orgami doc` runs.

## Shared team memory

Notes arrive on their own — the session hook pulls what the team has merged
before this conversation started, so what you were given is current. Sending is
the part that needs the user: `orgami sync` publishes under their name.

`orgami note` records something the team should not have to rediscover — a
gotcha, a cause found the hard way, a constraint that is not written down
anywhere. Notes are one file each, synced through the docs repo, and they appear
on the repo's page for everyone.

```bash
orgami notes --repo WinIt-backend   # what has been recorded about this repo
orgami note "..." --repo <repo> --tag gotcha
```

**Write a note when you learn something durable that is not in the code** — the
real cause of a bug, why an obvious approach does not work here, an undocumented
step needed to run something. Keep it to a few sentences, written for whoever
hits the same wall next, and say what the evidence was: a file and line, an error
string, a pull request number.

Where the company config has `notes_autosync`, record it and say so, rather than
asking first — publishing is guarded, not manual. It is screened for credentials
and for other clients, a model reviews it against everything already recorded,
a required check runs in CI, and a note that does not pass is held back with the
reason rather than shared. `orgami notes --rejected` shows what came back and
why; rewriting it with the reason addressed is worth doing.

Without `notes_autosync`, ask first — the note then goes out under the user's
name the next time they sync.

Never put in a note: a credential of any kind, a token, a connection string with
a password, or the name of another client. orgami refuses those outright, at
write time and again before anything syncs, but do not rely on the filter —
write as if the note will be read outside the team, because a repository leaks.

Point at where a value lives rather than quoting it: "the key is in SSM under
`/prod/parse/config`", never the key.

**Replace rather than pile up.** If a note is now wrong or has been fixed,
supersede it instead of adding a contradicting one:

```bash
orgami note --supersede <old-id> "what is true now"
```

The old note stops appearing everywhere at once. `orgami stale` lists notes old
enough to deserve a second look. Say when a note you are relying on looks out of
date rather than trusting it silently.

If the user asks whether their notes are any good, or wants the waiting ones
looked at, `orgami review --auto` reads them against everything already recorded
and comments a verdict per note on the pull request. Report what it said rather
than merging on your own.

`orgami sync` exchanges notes with the docs repo — it pushes, so treat it like
`publish` and only run it when the user asks. Where the team has review turned
on, it opens a pull request instead of committing, so a person sees every note
before it reaches everyone, and a CI check screens it for credentials. Tell the
user their note is waiting for review rather than implying it is already shared. `orgami join` sets a new machine up from
whatever map the organization has already published, without scanning anything.

## Other tools on the same map

The map is not Claude-only. `orgami mcp` serves it over MCP for Cursor,
opencode, Windsurf, Zed, Codex and VS Code; `orgami agents --cursor-hook` gives
Cursor the same automatic session injection this plugin does; and `orgami agents`
writes the same context into a repo's `AGENTS.md` or `.cursor/rules/` for tools
that only read files. Those written blocks are snapshots — `orgami agents
--refresh` and `orgami agents --git-hook` keep them from drifting. If the user asks how a
teammate on a different editor gets this, `orgami mcp --config <client>` prints
the snippet for that client.

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
