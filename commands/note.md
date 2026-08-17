---
description: Record something the team should not have to rediscover
---

Record a note in orgami for the whole team.

The user's note: $ARGUMENTS

Steps:

1. If `$ARGUMENTS` is empty, look back over this session for something durable
   worth recording — the real cause of a bug, why an obvious approach does not
   work in this codebase, an undocumented step needed to run or deploy
   something. Propose it in two or three sentences and ask whether to record it.
   If nothing in the session qualifies, say so and stop.
2. Write it for whoever hits the same wall next: what the situation is, what is
   actually true, and what to do instead. Include the evidence — a file and line,
   an error string, a PR number.
3. Never record secrets, credentials, anything already obvious in the code, or
   anything specific to this one session.
4. Run it from inside the checkout so it attaches to the right repo, or pass
   `--repo`:

   ```bash
   orgami note "..." --tag gotcha
   ```

5. Show the user the file it wrote. Mention that `orgami sync` shares it with the
   team, and only run that if they ask.
