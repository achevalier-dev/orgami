# Five people, one memory

The map and the recaps are generated. What a team knows is not — the cause
someone found at 2am, the reason the obvious fix does not work, the step missing
from the README. `orgami note` records that, and the docs repo syncs it.

```bash
orgami note "Parse Dashboard config lives in WinIt-ParseDashboard/index.js,
             not the fork. Copying it into SSM by hand drops every user's apps[]."
orgami notes --repo WinIt-backend
orgami sync
```

Three things keep this from turning into a landfill or a leak.

## A note holds a fact; a playbook holds a procedure

Some work is not one fact. A repository holds thirty fetchers and the job is
fixing another one — nothing surprising, which is why nobody writes it down, and
why the fifth one starts where the first did. Tag a note `pattern` and give it a
`--topic` and it becomes an instance of that job instead of a standing fact:

```bash
orgami note --repo scraphome --tag pattern --topic broken-fetcher "…"
```

Two instances under one topic write the playbook for it, and every one after
rewrites it. See **[playbooks.md](playbooks.md)**.

## Nothing shareable gets in

Before a note is written — and again before anything is pushed — it is screened
for private keys, AWS and GitHub and Slack and Stripe tokens, JWTs, connection
strings carrying a password, and `secret=`-shaped assignments. It is also
screened for the name of any *other* organization configured on the same
machine, because notes are the obvious place for one org's details to end up in
another's repository. Either refuses the write outright. `orgami notes --check` screens
everything already on disk, including what arrived from teammates.

Writing a note from inside one organization's checkout while another is the
current one is refused too, by comparing the checkout's git remote against the
configured organization.

## A person can review it first

Set `"notes_review": true` in the company config and `orgami sync` opens a pull
request instead of committing — one branch per author, reused, so syncing twice
before review updates the same pull request rather than opening another. Notes
reach the team only when someone merges.

## It gets pruned

A note that is now wrong is replaced, not contradicted:

```bash
orgami note --supersede <old-id> "what is true now"
orgami stale 120        # notes nobody has touched in four months
orgami prune --superseded
```

A superseded note disappears from the repo pages, the notes list and every
agent's context the moment its replacement lands. `orgami prune` moves it to
`notes/archive/` — kept on disk, removed from the shared repository on the next
sync. Nothing is ever deleted outright.

Run inside a checkout, a note attaches itself to that repo, and from then on it
appears on the repo's page — so the next person's agent reads it before touching
the code. Each note is its own file, named by timestamp and author, so five
people writing at once never produce a conflict. `orgami sync` runs on its own as
part of `orgami weekly`.

## Joining an org someone already mapped

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
