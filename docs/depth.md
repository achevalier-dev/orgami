# The symbol layer

`orgami scan` reads what a repository *declares about itself* and stops at the
door: manifests, deploy configuration, the URLs it writes down. That is the
right altitude for an organization map — it costs nothing but `grep`, it runs
over forty repositories in a couple of minutes, and two people scanning the same
org get the same map.

It is also blind to the inside of the code. It cannot tell you which repo
defines `chargeCustomer`, and the only way it can find an import is to grep for
a name — which matches a comment, a changelog and a variable just as happily as
an import statement.

`orgami depth` parses instead.

```bash
orgami depth                      # every checkout the scan already made
orgami depth --only billing-api   # one repo
orgami depth --symbol chargeCustomer
orgami depth --stats              # what has been parsed, per repo
```

Every file goes through a tree-sitter grammar, so a definition is a definition
node and an import is an import node, and the line number is the one the parser
reported rather than the one `grep` happened to land on. That is *better*
evidence than the scan can produce, not worse — which is why what it contributes
to the graph is marked `extracted`.

## What it needs, and why it is separate

The rest of orgami is bash, `gh`, `jq`, `fzf`, `gum`. This needs Python and a
set of compiled grammars, so it installs them into a virtualenv of its own:

```
~/.orgami/.venv/depth
```

Nothing else in orgami looks at that directory, and every other command works
exactly as well without it. First run installs it and says so; `orgami depth
--setup` redoes it; `rm -rf ~/.orgami/.venv/depth` undoes it. If you already have
`tree-sitter` and `tree-sitter-language-pack` in an interpreter you like, point
at it instead and orgami will not install anything:

```bash
orgami depth --python /usr/bin/python3
```

It reads the checkouts `orgami scan` already made, so it clones nothing and
needs no token. A 39-repo organization — 6,600 files — parses in about two
seconds.

## What comes out

`map/depth.json`, one entry per repo:

| Field | What it is |
|---|---|
| `parsed`, `files`, `languages` | how much of the repo the grammars could read |
| `symbol_count`, `exported_count` | every definition found, and how many are surface |
| `symbols` | the exported ones, each with `file` and the parser's `line` |
| `imports` | one row per module, with the first place it is imported and how often |
| `external_modules`, `internal_imports` | packages versus paths next door |

What is *kept* is the repo's surface. A private helper and a `require("../db")`
are real, they are counted, and neither is listed: nothing outside the repo could
ever depend on them, and forty repos' worth of them is several megabytes of file
nobody opens. Where a listing is cut, the count beside it is still exact and the
entry says `symbols_truncated`.

Languages with a grammar: Python, JavaScript, TypeScript, TSX, Go, Ruby, Rust,
Java, PHP, C#, Kotlin, Swift, Bash, C, C++. Anything else is counted under
`unparsed_extensions`, so "we do not parse your Elixir" is visible rather than
silently absent.

## Which repo defines this

The question the scan could never answer, and the first one anybody asks of an
unfamiliar organization:

```bash
$ orgami depth --symbol createTicket
  Attorney-Portal  createTicket    [function]  services/ticketService.js:446
  winit-frontends  createTicket    [function]  src/data/services/traffic.ts:24
  winit-ios        createTicket    [function]  Coordinators/TrafficCoordinator.swift:139
  parkingpay-api   findOrCreateTicket [function]  db/methods/Ticket/findOrCreate.js:9
```

Three repositories with their own `createTicket` is the sort of thing nobody
knows until they go looking. Only exported definitions are indexed — an internal
helper is not something another repo could have called anyway.

## What it adds to the map

`imports` edges, and only where an import statement resolves to a sibling
repository. The statement itself is always extracted — it sat at that line and
the parser says so — but whether the module it names *is* that repository is a
second question, and the honest answer differs:

- **`github.com/org/repo`, `@org/repo`, `ghcr.io/org/repo`** — the specifier
  carries the organization, so it resolves to exactly one repository and nothing
  else. **Extracted.**
- **A bare name that happens to equal a repository name** — resolved by
  resemblance. Real organizations have a `services/tracking/trackhome.js`
  importing `trackhome` and meaning the file next door. **Inferred**, and the
  evidence says exactly what was matched:

  ```
  repo:scraphome → repo:trackhome  [inferred]
    front-job/src/integrations/trackhome.ts:1 — imports "trackhome",
    which is also a repo name
  ```

A relative path is never a cross-repo edge, and no repository is ever pointed at
itself. See [the confidence tag](map.md#extracted-and-inferred) for what the two
labels mean everywhere else in the map.

## Where it shows up

- **`orgami context <repo>`** and the repo page get a **Public surface**
  section: how many definitions are exported, the first of them with their
  `file:line`, and the packages the repo imports most.
- **`map/graph.html`** shows the parsed counts in the panel for a repo, and
  draws `imports` edges dashed when they are inferred.
- **`orgami query`** and `orgami view` show `imports` alongside the other
  repo-to-repo edges, with `~` in front of the inferred ones.

`orgami weekly` does **not** run it. The weekly sequence has to work on any
machine with `gh` and `jq`; this one needs grammars installed, so it stays
something you ask for. Add it to your own timer if you want it fresh:

```bash
orgami scan && orgami depth && orgami doc
```
