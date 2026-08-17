From the merged pull requests below, extract only **durable decisions** — the
ones a person joining this codebase in six months would need to know, and that
are not obvious from reading the code as it stands now.

A durable decision is one of:

- a technology, library, service or pattern adopted, replaced or dropped
- a convention established or changed (naming, structure, error handling, auth)
- a deliberate constraint accepted ("we keep X in sync by hand because Y")
- something deprecated, frozen, or scheduled for removal
- a rejected alternative, where the PR says why it was rejected

Not a decision: bug fixes, dependency bumps, copy changes, routine features,
refactors with no stated rationale.

Rules:

- One bullet each, in this exact shape:
  `- **What was decided** — why, in one clause. (org/repo#123)`
- The reason must come from the PR body or a review comment. If no reason is
  stated anywhere, do not invent one — write `no reason recorded` and keep the
  bullet only if the decision itself is clearly durable.
- Quote the repo and number for every bullet so it can be checked.
- Order by how much it constrains future work, most constraining first.
- Cap at eight bullets. Fewer is normal and correct.
- If nothing in this week qualifies, output exactly `NONE` and nothing else.

Output only the bullets. No heading, no preamble, no closing summary.
