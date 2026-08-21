A working session just ended. Below is what was said in it, trimmed. Decide
whether it left behind anything a teammate should not have to rediscover.

There are two kinds of thing worth recording, and they are judged differently.

## 1. A durable fact — `gotcha`, `incident`, `setup`, `deploy`, `rollback`, `alert`

Record it only if **all** of these hold:

- It is still true tomorrow, and next month. Not "the build was red", but "the
  build goes red when X, because Y".
- It is not visible by reading the code as it now stands. A fix that is now in
  the repository explains itself; the *reason the obvious fix does not work*
  does not.
- Someone hitting the same wall would save real time by reading it.

Good facts are: the real cause behind a misleading symptom; a setup step nobody
wrote down; why an approach that looks right is wrong here; a constraint imposed
by something outside the code; where a system's behaviour differs from its
documentation.

**Most sessions establish no new fact. That is normal — a wrong fact costs more
than a missing one.**

## 2. An instance of recurring work — `pattern`

This is the other half, and it is missed far more often than it is
over-recorded. Ask: **was this session one of a kind of job that will come
round again?**

Not "was something learned", but "will someone do this same shape of work
again". Fixing one of many scrapers, adding one of many endpoints, migrating one
of many collections, wiring one more client to the same service, chasing one
more instance of the same class of failure — every one of those recurs, and
every one leaves the next person starting from nothing.

Record it if:

- The work has a **shape** — the same steps would apply to the next one of its
  kind, with different names in them.
- The repository plainly contains **more of the same thing** (more fetchers,
  more jobs, more routes, more integrations), or the session itself was the
  second or third time round.
- Someone doing the next one would be meaningfully faster for reading this.

It does **not** need to be surprising. A procedure that is merely tedious and
undocumented is exactly what belongs here. Two instances recorded under the same
topic become a playbook on their own, so a single instance is worth writing even
when it feels incomplete.

A `pattern` note is written as an instance, not as a manual: what the case
looked like, what was actually done in order, and what tripped it up. Name the
files, the commands and the error text. Say plainly which parts were
particular to this one and which would hold for the next.

`TOPIC` names the recurring job in two to four words, kebab-case, general enough
that the next instance files under the same one: `broken-fetcher`, not
`fix-carmax-fetcher-timeout`.

## Not worth recording, either way

What was changed (git already knows), progress narration, anything the session
only suspected and did not confirm, opinions, praise, a summary of the
conversation, or work that failed and was abandoned.

## Hard rules

- Never include a credential, token, key, password, connection string, customer
  name, or personal data, even if one appears above.
- Never state something the session did not actually establish. If it was a
  hypothesis, it does not go in.
- Write for someone who was not there. No "we", no "as discussed", no reference
  to this session.
- One record per session. Where a session qualifies on both counts, write the
  `pattern` one — the fact will usually be inside it.

## Output

If nothing qualifies, output exactly `NONE` and nothing else.

Otherwise output exactly this, and nothing else:

```
REPO: <the repository name it concerns, or - if it is not about one repo>
TAG: <one of: gotcha, incident, setup, deploy, rollback, alert, pattern>
TOPIC: <kebab-case name of the recurring job — only when TAG is pattern, otherwise omit this line>
NOTE:
<For a fact: two to five sentences — what the trap is, what actually causes it,
and what to do instead. For a pattern: up to twelve lines — the case, the steps
that worked in order, and what tripped it. Concrete and specific either way:
name the file, the setting, or the error text, so the next person can search
for it.>
```
