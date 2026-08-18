Write today's engineering digest for the team that did the work, and for whoever
is paying for it. They will read it in under a minute, tomorrow morning, next to
their coffee. It is not a status report anyone has to fill in — everything below
was read out of GitHub.

Two JSON documents follow: `STATS` (already computed, exact) and `ACTIVITY`
(what merged, what opened, what is waiting, and commits with no pull request
behind them).

Rules:

- **Only use figures from STATS.** Never compute your own, never estimate.
- **Say what changed, not who was busy.** A digest that ranks people by commit
  count teaches people to make commits.
- **One day is a small amount of evidence.** Do not draw a trend from it, do not
  compare it to yesterday, do not describe the day as good or bad.
- **Never invent an impact.** If a pull request does not say why it happened and
  the title does not make it obvious, describe what it does plainly and stop.
- Reference work as `repo#123` — exactly that form, nothing else. The links are
  generated afterwards, so a number that did not exist cannot become one.
- Plain sentences, present tense for what is now true. No praise, no filler, no
  "great progress today". Dry and specific reads as competent.
- Bot work — dependabot, renovate, github-actions — is already excluded from
  STATS. Do not mention it.

Write GitHub-flavored markdown with these sections, in this order. Sections
marked omittable disappear entirely when they would be empty — no heading, no
"nothing today":

## What landed

What merged today, and what it means for someone using or running the system.
Most consequential first, at most six paragraphs, **at most three sentences
each** — a paragraph that runs longer than that is two paragraphs. Group pull
requests into one paragraph only when they are literally the same piece of work.
Every paragraph carries its `repo#123`.

## Started

**Omittable.** Work opened today that has not landed. One line each, at most
four, newest first. Say what it is for, not that it "is in progress".

## Waiting on someone

**Omittable.** Open pull requests with no review on them, oldest first, from
`STATS.waiting`. Give the number of days from that object and say who opened it.
If nothing is waiting, omit the section — do not manufacture an ask.

## Outside a pull request

**Omittable.** Commits with no pull request behind them, from
`commits_without_pull_request` — `STATS.commits_outside_prs` is how many, and
`STATS.loose_repos` which repositories. Say which repositories and roughly what the
commits were doing. State it flatly: this is work that no second person saw, and
that a recap built on merges would miss. No scolding.

Output only the markdown body. No title heading, no preamble, no closing
summary — the numbers are appended automatically.
