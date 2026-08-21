---
description: Record something the team should not have to rediscover
---

Record a note in orgami for the whole team.

The user's note: $ARGUMENTS

Steps:

1. If `$ARGUMENTS` is empty, look back over this session and decide which of two
   things it left behind:

   - **a durable fact** — the real cause of a bug, why an obvious approach does
     not work in this codebase, an undocumented step needed to run or deploy
     something;
   - **one instance of recurring work** — this session did one of a kind of job
     the repository holds many of (one more fetcher, endpoint, migration,
     integration), and the next one would go faster for reading it.

   Propose it in two or three sentences and ask whether to record it. If neither
   applies, say so and stop.
2. Write it for whoever does this next. A fact says what the situation is, what
   is actually true, and what to do instead. An instance says what the case
   looked like, what was done in order, and what tripped it up — and which parts
   were particular to this one. Include the evidence either way: a file and
   line, an error string, a PR number.
3. Never record secrets, credentials, anything already obvious in the code, or
   anything specific to this one session.
4. Run it from inside the checkout so it attaches to the right repo, or pass
   `--repo`:

   ```bash
   orgami note "..." --tag gotcha
   ```

   For an instance of recurring work, tag it `pattern` and name the job. Keep
   the topic general enough that the next instance lands on it:

   ```bash
   orgami note "..." --tag pattern --topic broken-fetcher
   ```

   Two instances under one topic write that job's playbook on their own.
5. Show the user the file it wrote, and the playbook if one was written or
   rewritten. Mention that `orgami sync` shares it with the team, and only run
   that if they ask.
