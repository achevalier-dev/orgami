# orgami advise — every proposal, and every number in every proposal.
#
# Nothing here is a guess and nothing here is written by a model. The input is
# the committed map: vendor nodes, the `uses` edges that carry the file:line a
# vendor was matched on, the repo profiles, and the notes a human has already
# rejected a proposal with. The output is a ranked list, each row carrying the
# evidence you can open.
#
# There are two sources of vendor evidence and they answer different questions.
# The graph says what the code *calls*, with a file:line. `map/dns.json` says
# what the organization has an *account* with, with a DNS record anyone can look
# up. Neither subsumes the other: no repository mentions Google Workspace, and
# no DNS record mentions the Stripe SDK. So the two are unioned per vendor, and
# every piece of evidence keeps a `source` of `code` or `dns` all the way
# through to the report — a proposal resting only on DNS has to say so, and a
# vendor both agree on is a stronger claim and reads as one.
#
# Input is map/graph.json. Arguments:
#   $profiles  --slurpfile of map/repos.json (or /dev/null when there is none)
#   $dns       --slurpfile of map/dns.json (or /dev/null when nobody has run
#              `orgami dns`)
#   $cat       lib/vendors.tsv, parsed to
#              [{id,name,category,signals,portal,flags}]
#   $sup       [{id, reason, author, date, note}] — proposals a human rejected
#   $now       epoch seconds
#   $stale     a repo quieter than this many days makes its vendors orphans
#   $dns_stale a DNS reading older than this many days is reported with its age
#   $company, $org  for the artifact header

def strip_prefix($p): if startswith($p) then .[($p | length):] else . end;

def repos_word($n): if $n == 1 then "1 repo" else (($n | tostring) + " repos") end;

def domains_word($n): if $n == 1 then "1 domain" else (($n | tostring) + " domains") end;

# How much of the organization a vendor touches, in the words that fit whatever
# actually found it. A DNS-only vendor has no repositories to count, and saying
# "0 repos" about Google Workspace is true and useless.
def reach_word:
  if .repo_count > 0 then repos_word(.repo_count)
  else domains_word((.domains // []) | length) end;

# Every row a proposal shows, flattened to the one shape the report renders, and
# carrying where it came from. `repo` is empty on a DNS row and `domain` is
# empty on a code row, because neither has the other's kind of address.
def ev_rows:
  map({vendor: .vendor, repo: (.repo // ""), domain: (.domain // ""),
       at: .at, source: .source});

# --- the step-1 schema, read in exactly one place ------------------------------
#
# `lib/vendors.sh` does not record which signal matched — it keeps only the
# strongest one per repo and vendor (pkg, then tf, then action, then env, then
# host) and writes its `path:line` as the edge's evidence. So the kind is read
# back off that path, from the filenames a package manifest, an env file, a
# terraform file or a workflow actually has. If a future scan does record the
# kind, the field wins and this classification is never reached.
#
# Anything unrecognised falls to "host", the safe end of the guess: only the
# ghost-env-var proposal reads this, and it fires only when every piece of
# evidence is an env declaration. A misclassification therefore costs a missed
# proposal, never a false one.
def signal_kind:
  (.signal // .signal_kind // (.meta.signal? // null)) as $s
  | if ($s | type) == "string" and $s != "" then $s
    else ((.evidence // "") | ascii_downcase) as $e
      | if $e == "" then "unknown"
        elif $e | test("(^|/)\\.env|\\.env($|[./:])|env\\.example|env\\.sample") then "env"
        elif $e | test("package(-lock)?\\.json|pnpm-lock|yarn\\.lock|requirements[^/]*\\.txt|pyproject\\.toml|poetry\\.lock|pipfile|go\\.(mod|sum)|gemfile|cargo\\.toml|composer\\.json|build\\.gradle|pom\\.xml|mix\\.exs|pubspec\\.yaml|\\.csproj") then "pkg"
        elif $e | test("\\.tf($|[.:])|\\.tfvars") then "tf"
        elif $e | test("\\.github/workflows/") then "action"
        else "host"
        end
    end;

# --- advice policy: the categories whose vendors are substitutes ---------------
#
# `duplicate-category` says two vendors are doing one job, and says it at high
# confidence. That is only true where the members of a category actually replace
# one another. A 39-repository organization on AWS, Google Cloud, Heroku, Vercel
# and Netlify is not paying five times for one thing — those are five different
# workloads, and "Azure is the least wired in, so fold it into the others",
# derived from a single TypeScript line, is worse than saying nothing. A wrong
# high-confidence proposal costs the whole report its reader; a missed one costs
# nothing but itself. So this is an allow-list, and the default is silence.
#
# A category earns a place here when its rows are homogeneous — same job, same
# audience, and one of them is enough for an organization to function:
#
#   payments, billing     one processor takes the money, one ledger bills for it
#   error-tracking        exceptions land in one place or they land nowhere
#   incident-response     two rotas paging two sets of people is the failure mode
#   sms, email            one sender owns the reputation of the sending domain
#   email-security        a mail gateway sits in front of the MX; there is one MX
#   dmarc-reporting       one `rua=` destination processes the reports
#   workspace             mail, identity and documents for staff, once
#   support               one inbox customers reach, or they reach neither
#   recruiting            one applicant tracker, or candidates fall between them
#   feature-flags         two flag services means two answers to "is this on"
#   status-page           two status pages disagreeing in an incident
#   e-signature           one signature is legally one signature
#
# Everything else is a category whose vendors coexist by design, and the reason
# in each case is that the category names a shape rather than a job:
#
#   hosting, cdn          different workloads live in different places
#   database, vector-db   a cache, a document store and a warehouse are not one
#   search                site search, log search and a self-hosted index differ
#   ai                    model providers are chosen per task, and swapped often
#   auth                  staff SSO and customer identity are separate products
#   observability         uptime, logs, traces and dashboards are four purchases
#   analytics             a CDP feeds the product analytics that feeds the rest
#   communication         Slack for staff and Discord for a community
#   project-management    issues, wiki and roadmap are rarely one tool
#   cms, docs, media      a marketing site, an API reference and video encoding
#   marketing-email       a newsletter and lifecycle messaging are two audiences
#   crm                   marketing automation is routinely bought beside sales
#   code-quality          coverage and static analysis are not the same reading
#   security, storage     these stack rather than replace
#   design, whiteboard    creative suites overlap and nobody consolidates them
#   video, advertising    conferencing and ad platforms are bought per audience
#   dns                   zones get served wherever they were registered
#
# This is advice policy, not a fact about a vendor, which is why it lives here
# and not in lib/vendors.tsv. The catalogue says what a vendor looks like in
# somebody's code; that does not change when this list changes its mind.
def substitutable_categories:
  ["billing", "dmarc-reporting", "e-signature", "email", "email-security",
   "error-tracking", "feature-flags", "incident-response", "payments",
   "recruiting", "sms", "status-page", "support", "workspace"];

def days_since($now):
  if . == null or . == "" then null
  else (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) as $t
    | if $t == null then null else (($now - $t) / 86400 | floor) end
  end;

# --- the world ----------------------------------------------------------------

. as $graph
| (($profiles[0]) // []) as $repos
| (($dns[0]) // null) as $reading
| ([$graph.nodes[]? | select(.kind == "vendor")]) as $vnodes
| ([$graph.edges[]?
    | select(.kind == "uses" and ((.to // "") | startswith("vendor:")))
    | {vendor: (.to | strip_prefix("vendor:")),
       repo: (.from | strip_prefix("repo:")),
       at: (.evidence // ""),
       signal: signal_kind,
       source: "code"}]) as $uses

# The DNS reading, flattened to the same row shape. One row per record that
# matched, so a domain whose MX points at Google and whose apex carries a
# google-site-verification token contributes both — a reader checking the
# finding wants the records, not a summary of them.
| ([($reading.vendors // [])[] | . as $v | ($v.evidence // [])[]
    | {vendor: $v.id, repo: null, domain: .domain, at: .at,
       signal: .signal, source: "dns",
       name: ($v.name // ""), category: ($v.category // ""),
       portal: ($v.portal // ""), flags: ($v.flags // [])}]) as $dnsrows

| (($cat // []) | map({key: .id, value: .}) | from_entries) as $bycat
| ((([$vnodes[] | .id | strip_prefix("vendor:")])
    + [$uses[].vendor] + [$dnsrows[].vendor]) | unique) as $ids
| ([$ids[] as $id
    | (($bycat[$id]) // {}) as $c
    | ([$vnodes[] | select((.id | strip_prefix("vendor:")) == $id)] | first // {}) as $n
    | ([$dnsrows[] | select(.vendor == $id)] | first // {}) as $d
    | {id: $id,
       name: (($n.name // "") | if . == "" then ($c.name // $d.name // $id) else . end),
       category: (($n.meta.category? // "")
                  | if . == "" then ($c.category // $d.category // "") else . end),
       portal: (($n.meta.portal? // "")
                | if . == "" then ($c.portal // $d.portal // "") else . end),
       # The node's own flags win, and the catalogue stands in when it has
       # none — which is every map scanned before the column existed. Reading
       # the catalogue here is what lets a newly flagged vendor take effect on
       # the next `orgami advise` rather than on the next full scan.
       flags: (($n.meta.flags? // [])
               | if length == 0 then (($c.flags // $d.flags) // []) else . end),
       rows: [$uses[] | select(.vendor == $id)],
       dns: [$dnsrows[] | select(.vendor == $id)]}
    | .repos = (.rows | map(.repo) | unique)
    | .repo_count = (.repos | length)
    | .domains = (.dns | map(.domain) | unique)
    | .sources = (((if (.rows | length) > 0 then ["code"] else [] end)
                   + (if (.dns | length) > 0 then ["dns"] else [] end)))]) as $vendors

# Last push per repo. The profiles are the primary source; the graph's own repo
# nodes carry the same field and stand in when a profile is missing.
| (([$graph.nodes[]? | select(.kind == "repo")]
    | map({key: .name, value: (.meta.pushed_at? // "")})
    | from_entries | with_entries(select(.value != null and .value != "")))) as $push_g
| ((($repos // []) | map({key: .name, value: (.meta.pushed_at? // "")})
    | from_entries | with_entries(select(.value != null and .value != "")))) as $push_p
| ($push_g + $push_p) as $pushed

# --- 1. two vendors billed for the same job -----------------------------------
#
# A vendor only DNS found counts here. Two workspace suites, or an applicant
# tracker beside another applicant tracker, are the duplicates code was never
# going to see, and they are usually the expensive ones.
#
# The consolidation candidate is the one wired in least: fewest repositories and
# domains first, then fewest pieces of evidence. That second term matters once
# DNS is in the picture. Two workspace suites both sit on every domain the
# organization owns, so the first term ties — and the one holding the MX records
# has the mailboxes while the one holding a lone verification token may be a
# single-sign-on tenant nobody has migrated. Naming the wrong one is the
# difference between a sensible proposal and an absurd one.
| ([$vendors[]
    | select(.category != "" and (.repo_count > 0 or ((.dns | length) > 0)))]
   | group_by(.category)
   | map(select(length > 1))
   | map(sort_by(.repo_count + (.domains | length),
                 (.rows | length) + (.dns | length), .id))) as $groups
| substitutable_categories as $subst
| ([$groups[] | . as $g | select($subst | index($g[0].category))]) as $subgroups
| ([$groups[] | . as $g | select(($subst | index($g[0].category)) | not)]) as $coexgroups

| ($subgroups
   | map(. as $g
     | {kind: "duplicate-category",
        id: ("duplicate-category:" + $g[0].category + ":" + ([$g[].id] | sort | join("+"))),
        confidence: "high",
        category: $g[0].category,
        vendors: ([$g[].id] | sort),
        candidate: $g[0].id,
        repos: ([$g[].repos[]] | unique),
        repo_count: ([$g[].repos[]] | unique | length),
        domains: ([$g[].domains[]] | unique),
        sources: ([$g[].sources[]] | unique | sort),
        evidence: ([$g[] | .id as $v | (.rows + .dns)[] | . + {vendor: $v}] | ev_rows),
        claim: (($g | length | tostring) + " " + $g[0].category + " vendors are in the map — "
                + ([($g | reverse)[] | .name + " (" + reach_word + ")"] | join(", "))
                + ". " + $g[0].name + " is the least wired in of the "
                + ($g | length | tostring) + " — fewest places to touch, so it is the "
                + "cheapest to fold into the others.")})) as $dup

# The categories this rule was held back on, named rather than dropped. A reader
# who thinks two search vendors *is* a duplicate can see that the map found two,
# see that the policy above disagreed, and go and argue with the list.
| ($coexgroups
   | map(. as $g
     | {kind: "duplicate-category",
        id: ("duplicate-category:" + $g[0].category + ":"
             + ([$g[].id] | sort | join("+"))),
        category: $g[0].category,
        vendors: ([$g[].id] | sort),
        names: ([($g | reverse)[] | .name]),
        repo_count: ([$g[].repos[]] | unique | length),
        reason: ("vendors in " + $g[0].category
                 + " coexist by design, so two of them is not two bills for "
                 + "one job")})) as $dup_excluded

# --- 2. one repo away from being droppable ------------------------------------
| ([$vendors[] | select(.repo_count == 1)]
   | map({kind: "single-repo-vendor",
          id: ("single-repo-vendor:" + .id),
          confidence: "medium",
          vendors: [.id],
          repos: .repos,
          repo_count: 1,
          domains: .domains,
          sources: .sources,
          evidence: ((.rows + .dns) | ev_rows),
          claim: (.name + " is wired into one repository only (" + .repos[0]
                  + "). Dropping it, or folding it into a vendor already in the map, "
                  + "changes one repository."
                  + (if (.dns | length) > 0
                     then " Public DNS also carries an account for it on "
                          + (.domains | join(", "))
                          + ", so dropping the code is not the same as dropping the bill."
                     else "" end))})) as $single

# --- 3. a live subscription behind a repo nobody touches ----------------------
| ([$vendors[] | . as $v | .repos[] as $r
    | (($pushed[$r]) // "") as $p
    | ($p | days_since($now)) as $age
    | select($age != null and $age > $stale)
    | {kind: "orphan-vendor",
       id: ("orphan-vendor:" + $v.id + "@" + $r),
       confidence: "high",
       vendors: [$v.id],
       repos: [$r],
       repo_count: 1,
       last_push: ($p[0:10]),
       days_since_push: $age,
       sources: $v.sources,
       evidence: ([$v.rows[] | select(.repo == $r)] | ev_rows),
       claim: ($v.name + " is wired into " + $r + ", which has not been pushed to since "
               + ($p[0:10]) + " — " + ($age | tostring) + " days. The code is idle; the "
               + "subscription behind it may not be.")}]) as $orphan

# --- 4. the variable that was declared and never used -------------------------
#
# Scoped to the pair, not to the repo: a vendor whose only trace in this
# repository is a variable name. What this cannot rule out is a hostname —
# `lib/vendors.sh` ranks a host below an env var and discards it when both
# match — so the claim says what was ruled out and stops there.
#
# The rule rests on one premise: that a package *would* have been installed if
# the integration were live. For a whole class of vendor that premise is simply
# false. A Slack incoming webhook is a URL you POST to, Google Analytics is a
# script tag, and Vercel injects `VERCEL_*` into its own builds — none of them
# has an SDK to be missing, so the variable standing alone is the finished
# integration. Those vendors carry `no-sdk` in lib/vendors.tsv and are skipped
# here rather than argued with in the claim, because a proposal whose premise
# does not hold is not a weaker proposal, it is a wrong one.
| ([$vendors[] | . as $v
    | select(($v.flags | index("no-sdk")) | not)
    | (.rows | group_by(.repo))[]
    | select(all(.[]; .signal == "env"))
    | .[0].repo as $r
    | {kind: "ghost-env-var",
       id: ("ghost-env-var:" + $v.id + "@" + $r),
       confidence: "medium",
       vendors: [$v.id],
       repos: [$r],
       repo_count: 1,
       sources: $v.sources,
       evidence: (ev_rows + ($v.dns | ev_rows)),
       claim: ($v.name + " is matched in " + $r + " by an environment variable and "
               + "nothing stronger — no package manifest, terraform provider or workflow "
               + "action in that repository names it. The variable is declared; the SDK "
               + "may never have been wired."
               + (if ($v.dns | length) > 0
                  then " Public DNS says the account is real, which makes the unused "
                       + "variable the more interesting half."
                  else "" end))}]) as $ghost

# The pairs the flag held back, listed for the same reason the categories are:
# somebody has to be able to see that Slack was found by an environment variable
# in six repositories and that this rule chose not to call that a finding.
| ([$vendors[] | . as $v
    | select($v.flags | index("no-sdk"))
    | (.rows | group_by(.repo))[]
    | select(all(.[]; .signal == "env"))
    | {kind: "ghost-env-var",
       id: ("ghost-env-var:" + $v.id + "@" + .[0].repo),
       vendor: $v.id,
       name: $v.name,
       repo: .[0].repo,
       reason: ("no SDK to install — a webhook URL, a script tag or a variable "
                + "the platform injects is the whole integration")}])
  as $ghost_excluded

# --- 5. an account nothing in the code accounts for ---------------------------
#
# The reason this feature exists. Code names what an organization calls; a
# verification token, an MX record or an SPF include names what it has an
# account with, and the two barely overlap at the top of a bill. A vendor here
# is not a duplicate and not an oversight — it is a subscription no repository
# was ever going to mention, put in front of whoever has to renew it.
#
# High when a record proves an account of its own: a verification token is the
# vendor's own statement that this organization owns the domain, an MX record is
# where the mailboxes are, a DMARC destination is a mailbox somebody set up to
# receive reports. An SPF include, a CNAME or a nameserver is weaker — it says a
# service was pointed at, or that somebody serves the zone, which is often
# infrastructure the map already knows about under another name.
| ([$vendors[] | select((.dns | length) > 0 and .repo_count == 0)
    | ([.dns[].signal] | unique) as $sigs
    | {kind: "dns-only-vendor",
       id: ("dns-only-vendor:" + .id),
       confidence: (if ([$sigs[] | select(. == "txt" or . == "mx" or . == "dmarc")]
                         | length) > 0 then "high" else "medium" end),
       vendors: [.id],
       repos: [],
       repo_count: 0,
       domains: .domains,
       sources: ["dns"],
       signals: $sigs,
       evidence: (.dns | ev_rows),
       claim: (.name + " has an account on " + (.domains | join(", "))
               + " — the " + ($sigs | join(", "))
               + (if ($sigs | length) == 1 then " record below says so"
                  else " records below say so" end)
               + " — and no repository in the map names it. Nothing in the code was "
               + "ever going to find this one.")}]) as $dnsonly

# --- rank, then subtract what a human already answered ------------------------
#
# Confidence first, blast radius second — repositories, then domains, since a
# vendor on every domain the organization owns is a wider fact than one on a
# single brand — and id last, so two runs on the same map produce the same order
# as well as the same ids.
| (($dup + $single + $orphan + $ghost + $dnsonly)
   | map(. as $p
     | (($sup // []) | map(select(.id == $p.id)) | first) as $s
     | $p + (if $s == null then {suppressed: false}
             else {suppressed: true, suppression: $s} end))
   | sort_by((if .confidence == "high" then 0 else 1 end),
             -(.repo_count), -((.domains // []) | length), .id)) as $all

| ([$all[] | select(.suppressed | not)] | to_entries | map(.value + {rank: (.key + 1)})) as $open
| ([$all[] | select(.suppressed)]) as $hidden

# The DNS reading, described rather than repeated: whoever reads the report has
# to know whether one exists and how old it is, because a vendor's absence means
# two different things depending on the answer.
| (if $reading == null then null
   else {generated: ($reading.generated // null),
         domains: ($reading.domains // []),
         age_days: (($reading.generated_epoch // null)
                    | if . == null then null else (($now - .) / 86400 | floor) end),
         stale_days: $dns_stale}
     | .stale = (if .age_days == null then false else .age_days >= $dns_stale end)
   end) as $dnsinfo

| {company: $company,
   org: $org,
   generated: ($now | todate),
   scanned: (($graph.generated // "")[0:10]),
   stale_days: $stale,
   dns: $dnsinfo,
   # Two rules do not fire everywhere they match, and both restraints are
   # written down here rather than left as an absence. A reader who disagrees
   # with either can see exactly what was withheld and where the policy that
   # withheld it lives.
   excluded: {duplicate_category: $dup_excluded,
              ghost_env_var: $ghost_excluded,
              substitutable_categories: $subst,
              policy: ("lib/advise.jq — substitutable_categories, "
                       + "and the no-sdk flag in lib/vendors.tsv")},
   counts: {proposals: ($open | length),
            suppressed: ($hidden | length),
            excluded: (($dup_excluded | length) + ($ghost_excluded | length)),
            vendors: ($vendors | length),
            repos: (($repos // []) | length),
            vendors_from_code: ([$vendors[] | select(.repo_count > 0)] | length),
            vendors_from_dns: ([$vendors[] | select((.dns | length) > 0)] | length),
            vendors_from_both: ([$vendors[] | select(.sources == ["code", "dns"])] | length),
            by_kind: ($open | group_by(.kind) | map({key: .[0].kind, value: length}) | from_entries),
            high: ([$open[] | select(.confidence == "high")] | length),
            medium: ([$open[] | select(.confidence == "medium")] | length)},
   vendors: ($vendors
             | map({id, name, category, portal, repos, repo_count, domains, sources})
             | sort_by(.id)),
   proposals: $open,
   suppressed: $hidden}
