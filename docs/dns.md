# What the org has an account with

`orgami scan` reads committed files, so it finds the vendors the code *calls*: a
dependency on `stripe`, a `SENTRY_DSN`, a terraform provider. That is the
checkable half of the bill, and it is also the smaller one. No repository will
ever mention Google Workspace, Microsoft 365, the applicant tracker, the
e-signature seats or the design tool — and on most organizations those are the
top of the invoice.

DNS finds them, because a vendor that has been set up leaves a record behind.

```bash
orgami dns                                # the domains the map already knows
orgami dns --domain acme.com              # one domain, on its own
orgami dns --max-domains 10               # ask about more of them
orgami dns --yes                          # no confirmation prompt
orgami dns --json                         # the file, on stdout
```

It writes `map/dns.json` and `map/DNS.md`, and nothing else. It needs no
credential, no token and no OAuth — just outbound DNS queries, the ones any
resolver on the internet will answer. `dig` has to be on your PATH: the package
is `bind` on Arch, `bind-tools` on Alpine, `dnsutils` on Debian and Ubuntu.

## Why it is a separate command

`orgami scan` has to stay deterministic. Every edge in `graph.json` carries a
`file:line`, and two people scanning the same organization get the same map out
of the same committed files. A DNS reading is not that kind of fact: it is a
point-in-time observation with no file to open, and the next scan would wipe it
anyway. So it lives in its own file with its own timestamp, exactly as
`orgami live` does.

It differs from `live.json` in one way, and that difference is why this one
**publishes by default** while the live reading does not: a DNS record is
public. Anyone holding the report can run the same `dig` and see the same
answer. That makes a DNS finding reproducible and checkable after the fact,
which is the property everything else in the docs repo has and a reading of
somebody's cloud account does not.

`orgami advise` reads both files and unions them, so a DNS-discovered vendor
shows up beside the ones the code names, and every row says which found it.

## Which domains get asked about

Never a domain there is no reason to think the organization owns. In order:

1. **A `domains` array in the company config.** Authoritative — somebody wrote
   down what this organization owns, and that beats anything derived.
   ```json
   { "domains": ["acme.com", "acme.co.uk"], "dns_max_domains": 8 }
   ```
2. **The apexes of the `host:` nodes the map already found.** Most-referenced
   first, because the domain the organization's own services answer on is the
   one most repositories point at.
3. **`--domain`, repeatable.** A one-off, and it stands alone: somebody asking
   about one domain does not want four others queried alongside it.

Provider-owned domains are dropped hard — `vercel.app`, `fly.dev`,
`herokuapp.com`, `netlify.app`, `github.io`, `amazonaws.com`, `pages.dev`,
`workers.dev`, `onrender.com`, `railway.app` and the rest, plus everything
`scan.sh`'s `NOISE_DOMAINS` already refuses to make a host node out of. Reading
the DNS of `vercel.app` describes Vercel's zone and says nothing about anyone
else.

Whatever is dropped is named out loud, and so is whatever falls past the cap:

```
  not querying fly.dev — owned by a provider, not by this organization
  not querying stripe.com — past the cap of 5 domains
  raise the cap with dns_max_domains in ~/.orgami/acme/config.json
```

A truncated list that says nothing reads as "that was everything".

### Where the apex derivation is conservative

`api.staging.acme.co.uk` is `acme.co.uk`, not `co.uk`. That needs to know which
suffixes have more than one label, and orgami has no build step and will not
download and parse the Public Suffix List to split a domain name — so it carries
a hand-kept list of the country second-levels an organization plausibly sits
under.

A list like that will one day meet a suffix it has never heard of, and the
failure is asymmetric: guessing `com.zz` for `shop.acme.com.zz` would send
queries at a public suffix and attribute whatever came back to this
organization. So when the last label is two characters — a country, which is
where the multi-label suffixes live — and the label in front of it is one of the
generic words those suffixes are built from (`com`, `co`, `net`, `org`, `ac`,
`gov`, …), orgami refuses to answer rather than guess, and says how many hosts
it dropped for that reason. `--domain` is the way through.

## What each record proves, and what it does not

| Record | What it means |
|---|---|
| `txt` | a verification token — `google-site-verification=`, `MS=`, `atlassian-domain-verification=`, `docusign=`, `stripe-verification=`, `slack-domain-verification=` and friends. The strongest signal here: it is the vendor stating that this organization proved to *them* that it owns this domain |
| `mx` | where the mail goes, which is where the mailboxes are billed |
| `spf` | an `include:` or `redirect=` — a service given permission to send mail as the organization |
| `dmarc` | the `rua=`/`ruf=` destination in `_dmarc`. Nobody reads their own DMARC XML by hand, so that mailbox is a vendor |
| `cname` | a conventional subdomain pointed at somebody on purpose |
| `ns` | who serves the zone |

None of them is an invoice, and none says what anything costs. A verification
token proves an account existed at the moment somebody set it up; it does not
prove the plan is paid, or that it is still in use. A `google-site-verification`
token in particular is used by Search Console as well as Workspace, so on its
own it means "a Google product was verified against this domain" — the MX record
is what says there are mailboxes.

**A vendor that does not appear was not found in this organization's public
DNS**, which is not the same fact as not being in use.

### The subdomains it asks about

The apex records cost one query each. CNAMEs cost one query *per name per
domain*, so the list is short and every name on it is a convention rather than a
guess: `www`, `app`, `mail`, `status`, `help`, `support`, `docs`, `blog`,
`careers`, `pay`, `billing`. Those are where Statuspage, Zendesk, Intercom, Help
Scout, GitBook, Mintlify, Ghost, Webflow, Greenhouse, Lever, Ashby, Stripe's
hosted pages and Chargebee actually live. Anything rarer is a `dig` away.

### How far SPF is followed

One level, and only into the organization's own zone.

Both halves matter. SPF records get split, so the apex says
`include:_spf.acme.com` and every vendor the organization actually invited is
one name further along — not following would miss all of them. But following
anywhere else finds the wrong thing: `sendgrid.net`'s own record includes
SendGrid's netblocks and whatever SendGrid resells, none of which this
organization chose. Attributing a vendor's vendors to the customer is worse than
missing one.

## Nothing secret, and nothing wholesale

DNS is public, so this is mostly safe by construction — but `dns.json` is a file
that gets committed to a docs repo, and a zone dump is not a finding. Only the
records that matched a signal in `lib/vendors.tsv` are recorded. Everything else
is counted and thrown away, and the count is reported:

```
10 vendor(s) across 2 domain(s), from 32 queries — 45 of 94 records matched the catalogue
```

Within one vendor, three records of each domain and record kind are kept and the
rest are counted — five `google-site-verification` tokens on one domain are five
copies of one finding.

## The evidence line

```
TXT anthropic.com "atlassian-domain-verification=I9Xbb3XhdwM5exlpz4aYPu3j6WwEaPCBQwANPQ…" (dig 2026-08-19)
```

The record type, the exact name queried, the record text and the day it was
read — enough to run the same check and see the same thing. A TXT record runs to
255 characters and a DKIM key runs well past it, so a long one is cut; the whole
of it is one `dig` away.

## Where it shows up

- **`map/DNS.md`** — the page, one section per vendor, published with the rest
  of the map.
- **`orgami advise`** — vendors from DNS are unioned with the ones from code.
  Each row of every evidence table says `code` or `dns`, a vendor both agree on
  says so, and a vendor only DNS found gets its own proposal kind:
  `dns-only-vendor:<id>`. See [advise.md](advise.md).
- **`orgami weekly`** refreshes a reading that already exists, and never starts
  one. A timer that began querying somebody's domains because it was installed
  is not a timer anyone asked for.

## Staleness

A DNS record changes far less often than a running deployment, so the threshold
is 90 days rather than the seven `orgami live` uses. Past that, `DNS.md` and the
advise report say the reading's age out loud — a domain can be moved to a
different provider in an afternoon.

## Config

```json
{
  "domains": ["acme.com", "acme.co.uk"],
  "dns_max_domains": 8
}
```

Neither is required. Without `domains`, the apexes come from the map; without
`dns_max_domains`, five domains are queried and the rest are named and skipped.
