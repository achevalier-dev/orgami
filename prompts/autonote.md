A working session just ended. Below is what was said in it, trimmed. Decide
whether it established something a teammate should not have to rediscover.

Record it only if **all** of these hold:

- It is still true tomorrow, and next month. Not "the build was red", but "the
  build goes red when X, because Y".
- It is not visible by reading the code as it now stands. A fix that is now in
  the repository explains itself; the *reason the obvious fix does not work*
  does not.
- Someone hitting the same wall would save real time by reading it.

Good notes are: the real cause behind a misleading symptom; a setup step nobody
wrote down; why an approach that looks right is wrong here; a constraint imposed
by something outside the code; where a system's behaviour differs from its
documentation.

Not notes: what was changed (git already knows), progress narration, anything
the session only suspected and did not confirm, opinions, praise, or a summary
of the conversation.

**Most sessions contain nothing that qualifies. `NONE` is the common answer and
the correct one — a wrong note costs more than a missing one.**

Hard rules:

- Never include a credential, token, key, password, connection string, customer
  name, or personal data, even if one appears above.
- Never state something the session did not actually establish. If it was a
  hypothesis, it does not go in.
- Write for someone who was not there. No "we", no "as discussed", no reference
  to this session.

If nothing qualifies, output exactly `NONE` and nothing else.

Otherwise output exactly this, and nothing else:

```
REPO: <the repository name it concerns, or - if it is not about one repo>
TAG: <one of: gotcha, incident, setup, deploy, rollback, alert>
NOTE:
<two to five sentences. What the trap is, what actually causes it, and what to
do instead. Concrete and specific — name the file, the setting, or the error
text, so the next person can search for it.>
```
