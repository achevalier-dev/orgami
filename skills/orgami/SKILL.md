---
name: orgami
description: Read and write the organization's memory for a repository in a mapped GitHub organization — what a repo is, how to run and test it, what it talks to, the conventions, the decisions, and the playbooks for work that keeps coming round. Use at the start of work in a mapped repo, and again when a piece of work is finished, to record what it leaves behind. Triggers, reading: "how does X talk to Y", "where is this deployed", "how do I run this", "which repo handles", "what shipped last week", "why do we do it this way", "map of the org", "architecture", organization names configured in orgami. Triggers, writing: finishing a fix or a feature in a mapped repo; doing one of a kind of job that will recur (one more fetcher, scraper, endpoint, migration, integration, client); finding the real cause of a bug; discovering the obvious fix does not work; "is this documented", "write this down", "how do we usually do this", "playbook", "next time", "we keep hitting this", "I've fixed three of these".
---

# orgami

`orgami` keeps a scanned map of a GitHub organization, a page per repository,
the org's own agent instructions, decisions mined from merged pull requests, and
weekly recaps. Read from it before guessing, and before asking the user to
explain their own system.

State lives in `~/.orgami/<org>/` — usually one organization, occasionally
several, one directory each.

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
| One node and its edges | `orgami query <repo\|host\|tool\|service\|vendor>` |
| The whole org | `~/.orgami/<c>/map/ARCHITECTURE.md` |
| How they write code here | `~/.orgami/<c>/map/CONVENTIONS.md` |
| Why something is the way it is | `~/.orgami/<c>/map/DECISIONS.md` |
| What shipped recently | `~/.orgami/<c>/reports/*.md`, newest last |
| What teammates hit before you | `orgami notes`, `orgami notes --repo <repo>` |
| How to run, ship or unbreak it | `orgami runbook <repo>`, or `~/.orgami/<c>/map/runbooks/<repo>.md` |
| How a recurring kind of change is made | `orgami playbook <repo>`, `orgami playbooks` |
| How anything ships, org-wide | `~/.orgami/<c>/map/RUNBOOK.md` |
| Which repo defines a symbol | `orgami depth --symbol <name>`, when `map/depth.json` exists |
| The map as a picture | `~/.orgami/<c>/map/graph.html`, self-contained, opens anywhere |
| Anything needing a filter | `~/.orgami/<c>/map/graph.json`, `repos.json`, `coupling.json`, `depth.json` |

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

## Playbooks — the work that keeps coming round

A runbook is about a repository. A playbook is about a *kind of change* inside
one: fixing a broken fetcher, adding another endpoint to the same service,
migrating one more collection, wiring one more client the same way. The repos
where this matters are the ones holding many of the same thing, and doing the
fourth one from scratch is pure waste.

```bash
orgami playbooks                                  # every one recorded
orgami playbook scraphome                         # every topic in one repo
orgami playbook scraphome --topic broken-fetcher  # one, printed
```

**Read the playbook before starting a job that has one.** It carries the shape
of the case, what to check first, the steps in order, the traps, and the check
that closes it — written from the instances the team recorded, with the note id
or pull request behind each claim. Its prose is the one part of the map a model
wrote, so the evidence it was written from is printed underneath it; where they
disagree, the evidence wins.

**Record the instance when you finish one.** This is the part that is always
skipped, and the reason nothing accumulates:

```bash
orgami note --repo scraphome --tag pattern --topic broken-fetcher \
  "The Carmax fetcher returned an empty list rather than throwing …"
```

Write it as an instance, not a manual: what the case looked like, what you did
in order, what tripped you up, and which parts were particular to this one. Two
instances under the same `--topic` write the playbook by themselves, and every
one after that rewrites it.

Judge it by whether the job recurs, not by whether you were surprised. Tedious
and undocumented is exactly what belongs here. Use a topic general enough for
the next instance to land on it: `broken-fetcher`, not
`carmax-fetcher-timeout-2026`.

## When a piece of work is finished

Before moving on, ask two questions, and act on them rather than reporting them:

1. **Did this establish something durable that is not in the code?** The real
   cause behind a misleading symptom, why the obvious fix does not hold here, a
   setup step nobody wrote down. That is `orgami note`.
2. **Was this one of a kind of job that will come round again?** That is
   `orgami note --tag pattern --topic <job>`.

Both are shared with the team under the user's name, so ask first unless the org
config has `notes_autosync`. A session that ends without either is the common
case for the first question and much rarer for the second.

Sessions are also read back on their own — at the end of one, and again at the
start of the next for any that were killed before they could be — and anything
they establish is drafted. `orgami drafts` keeps or discards what was written
for the user. That is a safety net, not a substitute: it only sees what was said
in the conversation.

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

Where the org config has `notes_autosync`, record it and say so, rather than
asking first — publishing is guarded, not manual. It is screened for credentials
and for any other organization on the machine, a model reviews it against everything already recorded,
a required check runs in CI, and a note that does not pass is held back with the
reason rather than shared. `orgami notes --rejected` shows what came back and
why; rewriting it with the reason addressed is worth doing.

Without `notes_autosync`, ask first — the note then goes out under the user's
name the next time they sync.

Never put in a note: a credential of any kind, a token, a connection string with
a password, or the name of another organization on the machine. orgami refuses those outright, at
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

## Picking the organization

`orgami context` matches the checkout to an organization by its git remote on
its own.
When that fails, or when you are outside a checkout:

```bash
orgami list                       # the starred line is the default
ORGAMI_COMPANY=<name> orgami ...  # for one command
```

Set `ORGAMI_COMPANY` per command rather than changing the default — the default
is the user's, not yours.

## Graph shape

`graph.json` nodes are `{id, kind, name, meta}` where `kind` is `repo`, `host`,
`tool`, `service`, `vendor` or `lang`. A `vendor` is a third party the code pays
for — its `meta` carries the category it competes in and where its billing lives.
Vendors the *code* names live here; vendors the organization has an *account*
with live in `map/dns.json`, which the graph never carries. Edges are
`{from, to, kind, evidence, confidence}`, and a vendor edge also carries
`signal` — which kind of fact matched (`pkg`, `env`, `host`, `tf`, `action`):

- `references` — a repo names another in a manifest or URL
- `imports` — a parsed import statement in one repo names another (`orgami depth`)
- `calls` — a repo hits a host that exactly one other repo declares as its own
- `shares-config` — two repos read the same distinctive environment variable
- `changes-with` — the two keep landing pull requests together
- `uses`, `deploys-to`, `depends-on`, `reaches`, `written-in`

## Trusting it

`confidence` is the first thing to read on an edge, and the thing to repeat when
you report what it says.

- **`extracted`** — a literal string sat in a committed file. `evidence` is the
  `file:line` you can open. Open it before acting on a host, a dependency or a
  claimed link.
- **`inferred`** — nothing declared this. It was resolved by matching one repo's
  reading against another's, and `evidence` is what was matched, not a line.
  `calls`, `shares-config` and `changes-with` are always inferred; `imports` is
  inferred when a bare module name merely happens to equal a repo name.

Report the difference. "`billing` imports `shared` — `src/pay.ts:8`" and
"`billing` and `shared` keep changing in the same week" are different claims,
and treating the second as the first is how a plan gets built on a coincidence.
An edge with no `confidence` field predates it: `calls`, `shares-config` and
`changes-with` are inferred, everything else extracted.

Three limits worth stating out loud rather than papering over:

- **The scan sees only what is committed.** Services wired together at runtime —
  environment variables set in a dashboard, a service mesh, a gateway — leave no
  trace. A missing edge means "not found in committed configuration", never
  "not connected".
- **`changes-with` is correlation.** It comes from who merged what in the same
  week; it is a hint about blast radius, not a dependency.
- **`generated` in `graph.json` is when the scan last ran.** If it is more than
  a week old and the question is load-bearing, say the map is stale.

## Symbols

`map/depth.json` exists only where somebody has run `orgami depth`, which parses
every checkout with tree-sitter. When it is there it answers what the graph
cannot: which repo defines a name, and what each repo exports.

```bash
orgami depth --symbol chargeCustomer   # repo, kind, file:line
orgami depth --stats                   # what has been parsed, per repo
```

Two things to hold on to. Only *exported* definitions are indexed, so "not
found" means "nothing exports that name", not "it does not exist". And the file
is as old as the last parse — it does not move when the code does, so check
`generated` before leaning on it. Run `orgami depth` yourself only when asked
for it in that turn: on a machine without the grammars it installs a virtualenv,
which is not a side effect to cause uninvited.

## What is running, and what is only configured

The graph says what the committed files say: this repo is *configured* to deploy
to Fly, to Vercel, to ECS. It does not say the app still exists or answers on
that domain. When `map/live.json` is present, someone has asked the providers,
and `orgami context` renders it as **Running now** with the age of the reading.

Two rules for using it:

- **Quote the age with the fact.** "Vercel says `web` was READY when this was
  read three days ago" is honest; "web is live" is not. A row older than a week
  is a rumour — say so, or leave it out.
- **A repo with no row is not a repo with nothing running.** It may deploy
  through a provider nobody has a reader for, or through one nobody has
  credentials for on this machine. `unmatched` in the same file is the other
  half: things running that nothing ties to a repo.

## What the code names, and what the org has an account with

`orgami scan` finds vendors in committed files, so it finds what the code
*calls*. It will never find Google Workspace, Microsoft 365, the applicant
tracker or the e-signature seats, because no repository mentions them.
`map/dns.json`, written by `orgami dns`, is the other half: verification tokens,
MX, SPF `include:`, the DMARC destination, conventional CNAMEs and nameservers,
read out of the organization's own public DNS.

Three rules for using it:

- **Say which source a claim rests on.** `orgami advise` tags every row `code`
  or `dns` and so should you. A DNS finding has no `file:line`; it has a record,
  and the evidence string is the `dig` that reproduces it.
- **A record proves an account, never a price.** A verification token means the
  vendor confirmed this organization owns the domain. It says nothing about the
  plan, the seats, or whether anyone still logs in.
- **Quote the age.** The reading carries `generated`; past 90 days say so.

## Refreshing

```bash
orgami pull && orgami report   # this week's PRs, the recap, new decisions
orgami scan && orgami doc      # rebuild the map, the cards, the conventions
orgami coupling                # recompute what changes together
```

`orgami scan` shallow-clones every repo in the org. It takes minutes and hits the
network — run it when the user asks, not on your own initiative.

`orgami live` calls the user's cloud accounts — Vercel, Fly, AWS. Read-only, but
they are their accounts and their credentials. Read `map/live.json` freely; run
`orgami live` only when asked for it in that turn.

`orgami dns` sends DNS queries about the user's domains. No credentials and
nothing written, but it is still traffic on their behalf, and it asks which
domains it may query before it does. Read `map/dns.json` freely; run `orgami
dns` only when asked for it in that turn.

`orgami publish` commits everything to the org's docs repo and pushes. Never
run it unless the user asks for it in that turn.
