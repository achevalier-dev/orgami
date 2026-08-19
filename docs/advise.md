# What you are paying for twice

`orgami scan` already finds the third parties an organization's code names — the
package in the manifest, the variable in the env file, the hostname in the
config. Each one lands in the map as a `vendor` node with the `file:line` it was
matched on.

`orgami dns` finds the other half — the vendors no repository will ever mention,
read out of the organization's own public DNS and written to `map/dns.json`.

`orgami advise` reads both back and asks the question nobody has time to ask
manually: is anything here being paid for twice?

```bash
orgami advise                  # the report, ranked
orgami advise --json           # the same thing, machine-readable
orgami advise --stale-days 90  # a stricter idea of "nobody touches this"
orgami advise --all            # including what the team has already answered
```

It writes two files next to the rest of the map:

```
~/.orgami/<company>/map/advise.json    one row per proposal, with its evidence
~/.orgami/<company>/map/ADVISE.md      the same thing, rendered
```

## What it will not do

It has never seen an invoice, a contract, a seat count or a credential, and it
makes no network call of any kind. So it cannot tell you what anything costs,
and it does not try to: with no money in the picture, proposals are ranked by
confidence first and blast radius second — how many repositories an answer would
touch.

Everything it says is already in the local cache — the map from `orgami scan`,
and the DNS reading from `orgami dns` if somebody has taken one. A vendor that
does not appear was **not found in committed configuration** and not found in
public DNS, which is not the same fact as not being in use: a subscription
somebody pays for on a personal card, or wires in through a dashboard, leaves
neither a file nor a record to match.

Nothing here is written by a model. Every number in the report is computed by
`lib/advise.jq`, and every claim carries the path and line it came from.

## Two sources, unioned

Code names what the organization *calls*. DNS names what it has an *account*
with, and at the top of a bill those are almost disjoint sets — nothing in a
repository mentions Google Workspace, and no DNS record mentions the Stripe SDK.
So the two are unioned per vendor rather than merged, and every piece of
evidence keeps its source all the way to the page:

| Vendor | Source | Where | Found in |
|---|---|---|---|
| Stripe | code | web | `web/package.json:31` |
| Stripe | dns | acme.com | `TXT acme.com "stripe-verification=421fc24e…" (dig 2026-08-19)` |

A vendor both agree on is a stronger claim than either alone, and the proposal
about it says so. A proposal resting only on a DNS record says that too — it has
no `file:line`, because there is no file. Run `orgami dns` before reading this
and the report gets larger and more honest; the header says whether a reading
exists and how old it is, because a vendor's absence means different things
depending on the answer.

## The five things it looks for

**Two vendors doing the same job.** Every vendor in the catalogue carries a
category — payments, error-tracking, observability. The one wired into the
fewest repositories is named as the consolidation candidate, because it is the
cheapest to fold into the other. High confidence: the categories are declared,
not guessed.

It only fires on categories whose vendors are genuinely substitutes. Two error
trackers is a duplicate; two mail providers and two help desks are duplicates.
Six hosting providers is a normal organization — AWS for the data pipeline,
Vercel for the marketing site, Heroku for the thing nobody has migrated yet —
and "Azure is the least wired in, so fold it into the others" is bad advice
delivered at high confidence, which costs more than the finding was worth. The
allow-list is `substitutable_categories` in `lib/advise.jq`, with the reasoning
for each category beside it. Everything not on it — hosting, databases, CDNs,
model providers, analytics, auth — is treated as a category where vendors
coexist by design, and the report says which categories it held back on rather
than dropping them silently.

**A vendor in one repository.** Not a problem by itself — it is a note about
blast radius. Dropping it, or folding it into something already in the map,
changes one repository. Medium confidence.

**A vendor wired into a repository nobody touches.** The edge is real and the
code is idle, which is the shape of a subscription still being billed for a
service nothing calls. The threshold is 180 days since the last push, settable
per organization:

```bash
jq '.advise_stale_days = 90' ~/.orgami/<company>/config.json
```

High confidence — the date comes from GitHub's own record of the repository, not
from an inference.

**An account nothing in the code accounts for.** A vendor public DNS names and
no repository does — the workspace suite, the applicant tracker, the design
tool. Not a duplicate and not an oversight: a subscription no repository was
ever going to mention, put in front of whoever has to renew it. `orgami scan`
alone can never produce one of these. High confidence when a verification token,
an MX record or a DMARC destination is behind it, since each of those is an
account of its own; medium when it rests on an SPF include, a CNAME or a
nameserver, which is often infrastructure the map already knows under another
name.

**A variable declared for an SDK that was never wired.** A vendor matched in a
repository by an environment variable and by nothing stronger — no package in
any manifest, no terraform provider, no workflow action. Usually a spike that
was abandoned with the variable left behind, occasionally a live integration
wired through something this scan does not read. Medium confidence, and the
declaring line is right there to check.

Not every vendor has an SDK to be missing. A Slack incoming webhook is a URL you
POST to, Google Analytics is a script tag, and Vercel injects `VERCEL_*` into
its own builds — for all three, a variable with no package behind it is the
finished integration rather than an abandoned one. Those vendors carry `no-sdk`
in the `flags` column of `lib/vendors.tsv` and this rule skips them. The flag is
not for a vendor that has a real SDK and also happens to offer a webhook: Sentry
and Stripe do not get it.

## What it holds back, and says so

Both of those restraints are policy, and policy that quietly deletes a finding
is policy nobody can argue with. So the report carries a **Not proposed, on
purpose** section naming every category it declined to call a duplicate and
every vendor-and-repository pair the `no-sdk` flag took off the list, each with
the id the proposal would have had:

```
- **hosting** — AWS, Google Cloud, Heroku, Vercel, Netlify, Microsoft Azure ·
  `duplicate-category:hosting:aws+azure+gcp+heroku+netlify+vercel`
- **Slack** in 6 repositories — `ghost-env-var:slack@api`, …
```

The same thing is in `advise.json` under `excluded`, together with the full
allow-list of substitutable categories, so a reader who thinks two search
vendors *is* a duplicate can see what the map found, see that the policy
disagreed, and go and change the list.

## Saying no, once

This is the part that decides whether the report is worth opening a second time.

Most of what a first run turns up is deliberate. Two payment processors because
of tax residency. A vendor in one repo because that repo is the only thing that
should talk to it. A report that asks again every Monday is a report nobody
reads by March.

So every proposal has a stable id, derived from what it is about rather than
from a hash of the run:

```
duplicate-category:payments:paddle+stripe
orphan-vendor:sentry@legacy
ghost-env-var:twilio@api
single-repo-vendor:posthog
dns-only-vendor:google-workspace
```

The same situation produces the same id every time, which is what makes an
answer stick. Answer one and it is gone:

```bash
orgami advise --reject orphan-vendor:sentry@legacy \
  "legacy is frozen for a lawsuit, and Sentry has to keep receiving from it until it settles"
```

The reason is not optional, because the reason is the valuable half. That
rejection is an ordinary `orgami note`: it is tagged `advise-suppressed`, filed
against the repository it concerns when it concerns exactly one, screened for
credentials like every other note, synced to the docs repo, and read back into
every agent's session brief. Six months from now the next person to wonder why
`legacy` still has Sentry in it finds the answer on the repo's own page rather
than in a spreadsheet.

`orgami advise --all` shows what has been answered and who answered it.
`orgami notes --tag advise-suppressed` is the same list without the report
around it. To change an answer, supersede the note the way you would supersede
any other:

```bash
orgami note --supersede <note-id> --repo legacy "the lawsuit settled; Sentry can go"
```

An advisory list that gets shorter every month is the one that is working.
