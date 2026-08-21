# The work that keeps coming round

A note holds one fact: the cause behind a misleading symptom, the step nobody
wrote down. It is the right shape for something you learn once.

Most engineering work is not that shape. A repository holds thirty fetchers,
twenty endpoints, a dozen jobs wired the same way, and the work is doing one
more of them. Nothing about the fourth one is surprising, which is exactly why
nobody writes it down — and so the fifth one starts where the first one did.

A playbook is that missing artefact: how one *kind of change* is made in one
repository. `RUNBOOK.md` says how a repository is run and shipped. A playbook
says how a job inside it is done.

## Recording an instance

You do not write a playbook. You record instances of the job, and the playbook
follows.

```bash
orgami note --repo scraphome --tag pattern --topic broken-fetcher \
  "The Carmax fetcher stopped returning rows after the site moved its results
   into a client-side table. src/fetchers/carmax.ts still parsed the server
   HTML and got an empty list rather than throwing, so the job logged success.
   Fixed by switching it to the headless path src/fetchers/copart.ts already
   uses, then npm run build:worker."
```

Two things make it an instance rather than a note:

- `--tag pattern` — this is a step in a procedure, not a standing fact.
- `--topic <name>` — what the job is called. Two to four words, kebab-case,
  general enough that the next one files under the same topic:
  `broken-fetcher`, not `carmax-fetcher-timeout`.

Write it as an instance: what the case looked like, what you did in order, what
tripped you up, and which parts were particular to this one. Name the files, the
commands and the error text.

**Judge it by whether the job recurs, not by whether you were surprised.**
Tedious and undocumented is the point. The bar for a `gotcha` — was this
non-obvious — is the wrong bar here and keeps everything out.

## What gets written

The second instance under a topic writes the playbook, and every instance after
that rewrites it. `~/.orgami/<company>/map/playbooks/<repo>--<topic>.md`:

```bash
orgami playbooks                                  # every one recorded
orgami playbook scraphome                         # every topic in one repo
orgami playbook scraphome --topic broken-fetcher  # one, printed
orgami playbook scraphome --topic broken-fetcher --force   # rewrite it now
```

It carries six sections: when you are in this case, what to check first, the
procedure, the traps, how you know it worked, and what is not established. Each
specific claim carries the note id or the `repo#123` it came from.

`ORGAMI_PLAYBOOK_MIN=3 orgami playbook <repo>` raises the threshold if two
instances feels thin for your team.

## Why this one is written by a model

Everything else in the map is derived. The graph carries the `file:line` behind
every edge, the recaps have their numbers computed by `jq` before a model sees
them, and a runbook quotes rather than summarises. A procedure cannot be
computed out of committed files. It only exists in what the repeated instances
had in common, and reading that out is a model's job.

Three things keep it honest:

- **The evidence is printed underneath the prose**, in full — the instances, the
  matching pull requests, the commands the repository actually has. If the two
  disagree, the evidence is right.
- **Every specific claim carries its source** inline, so a step can be walked
  back to the note or the pull request that justifies it.
- **Holes are written as holes.** Where the instances do not say how something
  was verified, the playbook says `TODO — the evidence does not say how` rather
  than inventing a plausible command. A hole a reader can see is worth more than
  a confident invention they cannot check.

Treat a playbook the way you would treat a colleague's write-up: useful,
specific, and worth checking against the file it names.

## Where they show up

- On the repo card and in what an agent is handed at session start, as a line
  naming the topics that exist.
- In `map/PLAYBOOKS.md`, one row per playbook with its instance count.
- In the docs repo after `orgami publish`, under `playbooks/`, so a teammate who
  never runs a scan still has them.

## When one is wrong

Record the next instance — it rewrites the playbook. If a *fact* inside it is
now wrong, supersede the note that carried it:

```bash
orgami note --supersede <old-id> "what is true now"
orgami playbook scraphome --topic broken-fetcher --force
```

The superseded instance stops counting everywhere at once, and the rewrite is
done from what is left.
