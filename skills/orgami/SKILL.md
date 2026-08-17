---
name: orgami
description: Load organization context before working on a client's repository — which repos exist, how they reference each other, what deploys them, which hosts they reach, and what the team shipped recently. Use when starting work in a repo that belongs to a mapped GitHub organization, when asked how services connect, where something is deployed, which repo owns a behavior, or what changed lately in the org. Triggers: "how does X talk to Y", "where is this deployed", "what server runs", "which repo handles", "what shipped last week", "map of the org", "architecture", client or company names configured in orgami.
---

# orgami

`orgami` keeps a scanned map of a GitHub organization and weekly recaps of its
merged pull requests. Read from it before guessing at architecture.

State lives in `~/.orgami/<company>/`. One directory per company, so a freelancer
can hold several clients at once without mixing them.

## Pick the company first

```bash
orgami list
```

The starred line is the default. If the current working directory belongs to a
different client, set `ORGAMI_COMPANY=<name>` for the commands you run rather
than changing the default — the default is the user's, not yours.

Match the checkout to a company by its git remote:

```bash
git remote get-url origin
```

The org in that URL is the `org` field of one of the configs in `~/.orgami/*/config.json`.

## Getting context

Start here, in this order, and stop as soon as you have the answer:

1. **One repo, one host, one tool** — `orgami query <name>`. Works on repo names,
   hostnames, tool names (`kamal`, `terraform`), and service names (`postgres`).
   Prints the node, its metadata, everything it points at, and everything that
   points at it. Each edge carries `file:line` evidence.

2. **The whole system** — `~/.orgami/<company>/map/ARCHITECTURE.md`. Repo table,
   a mermaid graph of cross-repo references, deployment grouped by tool, host
   inventory, backing services, and unconnected repos.

3. **Raw graph** — `~/.orgami/<company>/map/graph.json`, when you need to filter
   with `jq`. Nodes are `{id, kind, name, meta}`; `kind` is one of `repo`, `host`,
   `tool`, `service`, `lang`. Edges are `{from, to, kind, evidence}`; `kind` is
   one of `uses`, `depends-on`, `references`, `deploys-to`, `written-in`.

4. **Recent work** — `~/.orgami/<company>/reports/*.md`, newest file last. The
   "How the team worked" section carries review conventions worth matching:
   typical PR size, who reviews what, which files attract review comments.

## Trusting it

The map is built by pattern-matching deployment files, not by executing them.
Every edge stores the `file:line` it came from. Before acting on a host,
a deploy target, or a claimed dependency, open that evidence and confirm. Say
where a claim came from when you report it.

The scan sees only what is committed. Services wired together by runtime
environment variables, a service mesh, or a shared gateway leave no trace in the
repositories and will be missing from the graph. Absence of an edge is not
evidence of independence — say so rather than concluding the services are unrelated.

`generated` in `graph.json` is when the scan last ran. If it is more than a week
old and the question is load-bearing, say the map is stale, or refresh it with
`orgami scan && orgami doc`.

## Refreshing

```bash
orgami pull           # cache this week's merged PRs
orgami report         # write the weekly recap
orgami scan           # rebuild the map (clones every repo shallowly, slow)
orgami doc            # re-render ARCHITECTURE.md
```

`orgami scan` shallow-clones every repo in the org into
`~/.orgami/<company>/cache/src/`. It takes minutes on a large org and hits the
network — run it when the user asks, not on your own initiative.

`orgami publish` commits the report and map to the client's docs repo and pushes.
Never run it unless the user asks for it in that turn.
