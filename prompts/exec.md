Write this week's engineering update for the person who runs the company. They
are not an engineer. They are paying for this work and need to know what they
got, what is at risk, and what needs them.

Two JSON documents follow: `STATS` (already computed, exact) and
`PULL_REQUESTS` (the merged work).

Rules:

- **No jargon.** No repository names, no file names, no framework names, no
  pull request numbers in the body. Say "the attorney portal", not
  `Attorney-Portal`. Say "the system that loads data into the warehouse", not
  `WinitJobsAWS`. If a term cannot be avoided, define it in the same sentence.
- **Lead with what changed for customers or for the business**, not with what
  changed in the code. A refactor that prevents an outage is "the payment
  retries that were silently failing now get caught" — not "refactored the
  retry handler".
- **Never invent an impact.** If a change's business value is not stated or
  obvious, describe what it does plainly and leave the value out. Do not
  estimate revenue, hours saved, or customers affected — you have no basis for
  any of those numbers.
- **Only use figures from STATS.** Never compute your own.
- Plain sentences. No bullets longer than two lines. No praise, no filler, no
  "the team did great work". Dry and specific reads as competent; enthusiasm
  reads as padding.
- Where something needs a decision, say who or what it is waiting on.

Write GitHub-flavored markdown with these sections, in this order. Sections
marked omittable disappear entirely when empty — no heading, no "nothing this
week":

## The week in three sentences

What the week was about. Three sentences, maximum.

## What you got

The work that a customer, an employee, or the business would notice. Four to
six items, most consequential first, one short paragraph each. Say what it
does now that it did not do before.

## What was broken and is now fixed

Only problems that were affecting real use. Say what was going wrong, in terms
of what someone experienced. Omit anything purely internal.

## Needs you

**Omittable.** Decisions waiting on the person reading this, money that needs
approving, risks that need accepting or refusing, or work that is blocked on
someone outside the engineering team. Say plainly what happens if it keeps
waiting. If nothing is waiting on them, omit this section — do not manufacture
an ask.

## Worth knowing

**Omittable.** Things that are true and consequential but need no action:
concentration risk, a system nobody is monitoring, a dependency on one person,
a growing backlog. State it once, without alarm and without softening.

## The numbers

A short paragraph using only STATS: how much shipped, how fast it merged, how
much of it was reviewed by a second person. Say what each number means in one
clause — "68 of 71 changes went in without a second person reading them, which
is how mistakes reach customers unnoticed".

Output only the markdown body. No title heading, no preamble.
