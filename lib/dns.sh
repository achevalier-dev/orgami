# shellcheck shell=bash
# orgami dns — the third parties an organization has an account with, read from
# its own public DNS.
#
# `orgami scan` finds what the code *calls*. That is the checkable half of the
# bill and it is also the smaller one: no repository will ever mention Google
# Workspace, Microsoft 365, Greenhouse, DocuSign or Zoom, and on most
# organizations those are the top of the invoice. DNS finds them, because a
# vendor that has been set up leaves a record behind — a verification token is
# that vendor saying *this organization proved to us that it owns this domain*.
# That is an account, not a mention.
#
# Like `orgami live`, this is deliberately not part of `orgami scan`, and for
# the same reason: the graph is committed evidence, every edge carries a
# file:line, and two people scanning the same org get the same map. A DNS
# reading has no file:line — it is a point in time. So it lives in its own file,
# `map/dns.json`, carries its own timestamp, and `orgami scan` never touches it.
#
# It differs from `live.json` in one way that matters, and the difference is why
# this one publishes by default: a DNS record is public. Anyone holding the
# report can run the same `dig` and see the same answer, which makes a DNS
# finding reproducible and checkable in a way a reading of somebody's cloud
# account never is.
#
# Nothing is authenticated, nothing is written, and nothing secret is recorded.
# The queries are the ones any resolver on the internet will answer. Only the
# records that matched a catalogue signal reach the artifact; the rest are
# counted and thrown away, so this never becomes a dump of somebody's zone.

DNS_STALE_DAYS=90

# Five is a working organization's domain count — the product, the marketing
# site, maybe a legacy brand. Past that the list is usually parked domains and
# redirects, which cost queries and tell nobody anything. `dns_max_domains` in
# the company config raises it, and whatever is left out is named out loud.
DNS_MAX_DOMAINS=5

# Seconds per query, with a single try. One unreachable resolver then costs
# three seconds rather than stalling the run.
DNS_TIMEOUT=3

# The only names asked for beyond the apex, and the only part of this that costs
# a query per name per domain — so each one has to earn its place by being a
# convention rather than a guess. Each is a name organizations actually publish,
# pointed at a vendor that bills them:
#
#   www app     the site and the product, which name the host and often the CDN
#   mail        webmail, where a workspace vendor puts its front door
#   status      Statuspage, Better Stack — bought precisely to be a subdomain
#   help support the support desk: Zendesk, Intercom, Help Scout, Freshdesk
#   docs        GitBook, Mintlify, ReadMe
#   blog        Ghost, Webflow, HubSpot
#   careers     Greenhouse, Lever, Ashby — an applicant tracker, always a seat bill
#   pay billing Stripe's hosted pages, Chargebee
#
# Anything rarer is a guess, and a guess costs a query on every domain to find
# nothing. `dig` on a specific name is one command away for whoever wants more.
DNS_SUBDOMAINS=(www app mail status help support docs blog careers pay billing)

# Domains a provider owns rather than the organization. Reading the DNS of
# `vercel.app` describes Vercel's zone and says nothing at all about this org,
# and asking looks like diligence while producing noise — so an apex that lands
# here is dropped and reported as dropped.
DNS_PROVIDER_DOMAINS='^(vercel\.app|vercel-dns\.com|fly\.dev|fly\.io|herokuapp\.com|herokudns\.com|netlify\.app|netlify\.com|github\.io|githubusercontent\.com|amazonaws\.com|elasticbeanstalk\.com|cloudfront\.net|windows\.net|azurewebsites\.net|azure-dns\.com|pages\.dev|workers\.dev|onrender\.com|render\.com|railway\.app|ondigitalocean\.app|digitaloceanspaces\.com|run\.app|appspot\.com|firebaseapp\.com|firebaseio\.com|web\.app|supabase\.co|neon\.tech|planetscale\.com|psdb\.cloud|upstash\.io|now\.sh|surge\.sh|gitbook\.io|readthedocs\.io|zendesk\.com|statuspage\.io|myshopify\.com|wixsite\.com|squarespace\.com|webflow\.io|ngrok\.io|ngrok\.app|trycloudflare\.com|cloudflarestorage\.com|googleapis\.com|gstatic\.com|akamaized\.net|fastly\.net|jsdelivr\.net|unpkg\.com|cdn\.sh)$'

# Public suffixes of more than one label, so `acme.co.uk` is not read as
# `co.uk`. This is a hand-kept list and not the Public Suffix List: orgami has
# no build step and will not download and parse a file to split a domain name.
# It covers the country second-levels an organization plausibly sits under.
DNS_MULTI_SUFFIXES='co.uk org.uk ac.uk gov.uk me.uk net.uk sch.uk ltd.uk plc.uk
co.jp ne.jp or.jp ac.jp go.jp co.nz net.nz org.nz com.au net.au org.au edu.au
gov.au id.au co.za org.za web.za com.br net.br org.br com.mx com.ar com.co
com.pe com.uy com.ve com.ec com.bo com.py com.sg com.hk com.tw com.cn net.cn
org.cn co.in net.in org.in co.kr or.kr co.il org.il net.il ac.il com.tr com.ua
com.my com.ph com.vn co.id co.th in.th com.pl net.pl org.pl com.ng com.eg
com.sa com.kw com.qa co.ke co.tz co.ug co.zw com.pk com.bd com.np co.ma com.tn
com.es com.pt com.gr com.cy co.at or.at com.hr com.ru net.ru org.ru'

# The generic words a country's second level is made of. See dns_apex: these are
# how a suffix this list has never heard of is caught rather than queried.
DNS_SUFFIX_WORDS='com co net org gov edu ac ne or go web id sch ltd plc mil
info biz name gob gouv'

dns_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Recorded rather than printed: cmd_dns reports every error once, at the end,
# the way cmd_live does. A domain that will not resolve is a line on the report,
# never a failed run.
dns_err() {
  jq -cn --arg d "$1" --arg m "$2" '{domain:$d, message:$m}' >>"$DNS_ERRORS"
}

# --- one query ----------------------------------------------------------------

# `dig` once per (type, name) for the whole run, cached on disk. Five domains
# following SPF will ask three different zones for `_spf.google.com`, and the
# cache is also how the run reports how many queries it actually made.
#
# The answers are normalised here so nothing downstream has to know what dig's
# output looks like: a long TXT record is split into several quoted strings on
# the wire, and dig prints them as `"part one" "part two"`.
dns_query() {
  local type=$1 name=$2 f
  f="$DNS_CACHE/$type-$(printf '%s' "$name" | tr -c 'a-zA-Z0-9._-' '_')"
  if [[ ! -f $f ]]; then
    dig +short "+time=$DNS_TIMEOUT" +tries=1 "$type" "$name" 2>/dev/null |
      sed -e 's/" "//g' -e 's/^"//' -e 's/"$//' -e 's/[[:space:]]*$//' |
      awk 'NF' >"$f" 2>/dev/null || : >"$f"
  fi
  cat "$f"
}

# The evidence line. It has to let a reader run the same check and see the same
# thing, so it carries the record type, the exact name queried, the record text
# and the day it was read.
#
# A TXT record runs to 255 characters and a DKIM key runs well past that. The
# head of a record is what identifies a vendor, so a long one is cut rather than
# poured into the artifact whole — the full record is one `dig` away.
dns_evidence() {
  local type=$1 name=$2 rec=$3
  [[ ${#rec} -le 110 ]] || rec="${rec:0:110}…"
  printf '%s %s "%s" (dig %s)' "$type" "$name" "$rec" "$DNS_DATE"
}

# --- which domains are the organization's -------------------------------------

# The registrable apex of a hostname: `api.staging.acme.co.uk` is `acme.co.uk`.
# Prints nothing, and says nothing, when it cannot be certain — an address, a
# bare label, or a suffix DNS_MULTI_SUFFIXES has never heard of.
#
# That last case is the one worth being careful about, because the failure is
# asymmetric: guessing `com.br` for `shop.acme.com.br` would send queries at a
# public suffix and attribute whatever came back to this organization. So when
# the last label is two characters — a country, which is where the multi-label
# suffixes live — and the label in front of it is one of the generic words those
# suffixes are built from, this refuses to answer instead of guessing. Passing
# the domain with `--domain` is the way through.
dns_apex() {
  local host n last2 first
  host=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  host=${host%.}
  case $host in
    *[a-z]*) ;;
    *) return 0 ;;
  esac
  [[ $host == *.* ]] || return 0

  local IFS=. parts
  read -ra parts <<<"$host"
  n=${#parts[@]}
  [[ $n -ge 2 ]] || return 0

  last2="${parts[n - 2]}.${parts[n - 1]}"
  case " $(printf '%s' "$DNS_MULTI_SUFFIXES" | tr '\n' ' ') " in
    *" $last2 "*)
      [[ $n -ge 3 ]] || return 0
      printf '%s.%s\n' "${parts[n - 3]}" "$last2"
      return 0
      ;;
  esac

  first=${parts[n - 2]}
  if [[ ${#parts[n - 1]} -eq 2 ]]; then
    case " $(printf '%s' "$DNS_SUFFIX_WORDS" | tr '\n' ' ') " in
      *" $first "*) return 0 ;;
    esac
  fi
  printf '%s\n' "$last2"
}

dns_is_provider() {
  local d=$1
  if printf '%s' "$d" | grep -qiE "$DNS_PROVIDER_DOMAINS"; then return 0; fi
  # Whatever the scanner already refuses to make a host node out of is not a
  # domain worth asking about either. NOISE_DOMAINS is only defined when
  # lib/scan.sh has been sourced, which the `dns` arm does.
  if [[ -n ${NOISE_DOMAINS:-} ]] && printf '%s' "$d" | grep -qE "$NOISE_DOMAINS"; then
    return 0
  fi
  return 1
}

# The `domains` array in the company config, which is authoritative: somebody
# wrote down what this organization owns, and that beats anything derived.
dns_domains_configured() { cfg 'domains[]?'; }

# Otherwise, the apexes of the hosts the map already found, most-referenced
# first — the domain the organization's own services answer on is the one the
# most repositories point at, and that is the one worth the query budget.
dns_domains_from_graph() {
  local g="$DIR/map/graph.json" h a tmp undecided=0
  [[ -f $g ]] || return 0
  tmp=$(mktemp)
  while IFS= read -r h; do
    [[ -n $h ]] || continue
    a=$(dns_apex "$h")
    if [[ -z $a ]]; then
      undecided=$((undecided + 1))
      continue
    fi
    echo "$a" >>"$tmp"
  done < <(jq -r '.nodes[]? | select(.kind == "host") | .name' "$g" 2>/dev/null)
  [[ $undecided -eq 0 ]] ||
    log "$undecided host(s) in the map gave no registrable domain — an address, a single label, or a public suffix orgami will not split"
  sort "$tmp" | uniq -c | sort -k1,1nr -k2,2 | awk '{print $2}'
  rm -f "$tmp"
}

# --- what the records say ------------------------------------------------------

# Every `include:` and `redirect=` in one SPF record, and then one level down —
# but only into the organization's own zone.
#
# Both halves of that rule are the point. An SPF record is routinely split, so
# the apex says `include:_spf.acme.com` and every vendor the organization
# actually invited is one name further along. Not following would miss all of
# them. Following anywhere else would find the wrong thing: `sendgrid.net`'s own
# record includes SendGrid's netblocks and whatever SendGrid resells, and none
# of that is a supplier this organization chose — it would attribute a vendor's
# vendors to the customer.
#
# So the follow is one level, and only where the target sits under the apex
# being read. Everything past that belongs to somebody else, and the RFC's own
# limit of ten lookups exists for the same reason: this fans out fast.
dns_spf_facts() {
  local apex=$1 name=$2 rec=$3 depth=$4 tok target sub ev followed=0
  local -a toks
  ev=$(dns_evidence TXT "$name" "$rec")
  read -ra toks <<<"$rec"
  for tok in "${toks[@]}"; do
    case $tok in
      include:*) target=${tok#include:} ;;
      redirect=*) target=${tok#redirect=} ;;
      *) continue ;;
    esac
    target=${target%.}
    [[ -n $target && $target == *.* ]] || continue
    printf 'spf\t%s\t%s\n' "$target" "$ev"
    [[ $depth -lt 2 ]] || continue
    [[ $target == "$apex" || $target == *".$apex" ]] || continue
    followed=$((followed + 1))
    [[ $followed -le 6 ]] || continue
    while IFS= read -r sub; do
      case $sub in v=spf1*) ;; *) continue ;; esac
      dns_spf_facts "$apex" "$target" "$sub" $((depth + 1))
    done < <(dns_query TXT "$target")
  done
}

# One domain's records as facts, in the `<kind>\t<value>\t<evidence>` shape
# `vendors_match` reads.
#
# Every record read becomes a fact, matching or not. The ones the catalogue
# recognises reach the artifact; the rest are only ever counted. That is what
# keeps this a list of findings rather than a copy of somebody's zone file, and
# it is why the count of unmatched records is reported — a domain where nothing
# matched and nothing was read are two different facts.
dns_facts() {
  local d=$1 rec host sub m ev

  # In value order: a verification token first, because it is the only record
  # here that is a vendor's own statement about this organization.
  while IFS= read -r rec; do
    [[ -n $rec ]] || continue
    case $rec in
      v=spf1*) dns_spf_facts "$d" "$d" "$rec" 1 ;;
      *) printf 'txt\t%s\t%s\n' "$rec" "$(dns_evidence TXT "$d" "$rec")" ;;
    esac
  done < <(dns_query TXT "$d")

  while IFS= read -r rec; do
    [[ -n $rec ]] || continue
    # `10 aspmx.l.google.com.` — the exchanger is the last field.
    host=${rec##* }
    printf 'mx\t%s\t%s\n' "${host%.}" "$(dns_evidence MX "$d" "$rec")"
  done < <(dns_query MX "$d")

  # DMARC aggregate reports go somewhere, and that somewhere is a vendor:
  # nobody reads their own DMARC XML by hand.
  while IFS= read -r rec; do
    case $rec in v=DMARC1*) ;; *) continue ;; esac
    ev=$(dns_evidence TXT "_dmarc.$d" "$rec")
    while IFS= read -r m; do
      [[ -n $m ]] || continue
      printf 'dmarc\t%s\t%s\n' "${m%.}" "$ev"
      # Split on the separators DMARC uses, so a second destination after a
      # comma is its own line rather than the tail of the first.
    done < <(printf '%s\n' "$rec" | tr ',; ' '\n\n\n' |
      sed -n -e 's/^ru[af]=mailto:[^@]*@\([A-Za-z0-9.-]*\).*/\1/p' \
        -e 's/^mailto:[^@]*@\([A-Za-z0-9.-]*\).*/\1/p')
  done < <(dns_query TXT "_dmarc.$d")

  for sub in "${DNS_SUBDOMAINS[@]}"; do
    while IFS= read -r rec; do
      [[ -n $rec ]] || continue
      printf 'cname\t%s\t%s\n' "${rec%.}" "$(dns_evidence CNAME "$sub.$d" "$rec")"
    done < <(dns_query CNAME "$sub.$d")
  done

  while IFS= read -r rec; do
    [[ -n $rec ]] || continue
    printf 'ns\t%s\t%s\n' "${rec%.}" "$(dns_evidence NS "$d" "$rec")"
  done < <(dns_query NS "$d")
}

# One domain, from the queries to the matched rows. Appends ndjson to $DNS_ROWS
# and one summary line to $DNS_SEEN.
dns_domain_scan() {
  local d=$1 facts read_n matched_n=0 id name category portal kind ev
  facts=$(mktemp)
  dns_facts "$d" >"$facts"
  read_n=$(grep -c '' "$facts" 2>/dev/null || true)
  read_n=${read_n:-0}
  if [[ $read_n -eq 0 ]]; then
    dns_err "$d" "nothing came back — no NS, MX or TXT record, so either it does not resolve or nothing is published on it"
    rm -f "$facts"
    return 0
  fi
  while IFS=$'\t' read -r id name category portal kind ev; do
    [[ -n $id && -n $ev ]] || continue
    matched_n=$((matched_n + 1))
    jq -cn --arg d "$d" --arg id "$id" --arg name "$name" --arg c "$category" \
      --arg p "$portal" --arg k "$kind" --arg ev "$ev" \
      '{domain:$d, id:$id, name:$name, category:$c, portal:$p,
        signal:$k, at:$ev}' >>"$DNS_ROWS"
  done < <(vendors_match "$facts" all)
  jq -cn --arg d "$d" --argjson r "$read_n" --argjson m "$matched_n" \
    '{domain:$d, records:$r, matched:$m}' >>"$DNS_SEEN"
  rm -f "$facts"
}

# --- the command ---------------------------------------------------------------

cmd_dns() {
  load_company

  local yes=0 as_json=0 maxd="" d s
  local -a want=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --domain | -d) want+=("$2"); shift 2 ;;
      --max-domains) maxd=$2; shift 2 ;;
      --yes | -y) yes=1; shift ;;
      --json) as_json=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  # After the flags, so a typo in one is reported as a typo rather than as a
  # missing dependency.
  need dig "the package is called bind on Arch, bind-tools on Alpine, dnsutils on Debian and Ubuntu"

  # Where the list comes from, in the order that puts the most reliable source
  # first. `--domain` is a one-off and stands alone: somebody asking about one
  # domain does not want four others queried alongside it.
  local origin
  local -a domains=()
  if [[ ${#want[@]} -gt 0 ]]; then
    domains=("${want[@]}")
    origin="--domain"
  else
    while IFS= read -r d; do [[ -n $d ]] && domains+=("$d"); done \
      < <(dns_domains_configured)
    if [[ ${#domains[@]} -gt 0 ]]; then
      origin="the domains list in $DIR/config.json"
    else
      while IFS= read -r d; do [[ -n $d ]] && domains+=("$d"); done \
        < <(dns_domains_from_graph)
      origin="the host nodes in map/graph.json"
    fi
  fi

  local -a keep=() dropped=()
  for d in ${domains[@]+"${domains[@]}"}; do
    d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')
    d=${d%.}
    [[ -n $d && $d == *.* ]] || { dropped+=("$d — not a domain name"); continue; }
    if dns_is_provider "$d"; then
      dropped+=("$d — owned by a provider, not by this organization")
      continue
    fi
    case " ${keep[*]-} " in *" $d "*) continue ;; esac
    keep+=("$d")
  done

  [[ -n $maxd ]] || maxd=$(cfg dns_max_domains "$DNS_MAX_DOMAINS")
  [[ $maxd =~ ^[0-9]+$ ]] || die "--max-domains takes a number of domains, not '$maxd'"
  local capped=0
  if [[ ${#keep[@]} -gt $maxd ]]; then
    local i
    for ((i = maxd; i < ${#keep[@]}; i++)); do
      dropped+=("${keep[i]} — past the cap of $maxd domains")
      capped=$((capped + 1))
    done
    keep=("${keep[@]:0:maxd}")
  fi

  # A truncated list that says nothing reads as "that was everything", so this
  # one always says what it left out and how to get it back.
  for s in ${dropped[@]+"${dropped[@]}"}; do log "not querying $s"; done
  [[ $capped -eq 0 ]] ||
    log "raise the cap with dns_max_domains in $DIR/config.json, or name one with --domain"

  [[ ${#keep[@]} -gt 0 ]] ||
    die "no domain to ask about — orgami dns --domain <domain>, or add a \"domains\" array to $DIR/config.json"

  echo "public DNS for ${#keep[@]} domain(s), from $origin:" >&2
  printf '  %s\n' "${keep[@]}" >&2
  if [[ $yes == 0 ]]; then
    [[ -t 0 ]] || die "nothing to confirm on — pass --yes"
    local ans
    read -rp "query these? [y/N] " ans
    [[ $(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]') == y* ]] || die "aborted"
  fi

  DNS_CACHE=$(mktemp -d)
  DNS_ROWS=$(mktemp)
  DNS_SEEN=$(mktemp)
  DNS_ERRORS=$(mktemp)
  DNS_DATE=$(date -u +%Y-%m-%d)

  for d in "${keep[@]}"; do
    log "asking about $d"
    dns_domain_scan "$d"
  done

  local queries
  queries=$(find "$DNS_CACHE" -type f 2>/dev/null | grep -c '' || true)

  local out="$DIR/map/dns.json" tmp
  tmp=$(mktemp)
  jq -n --arg company "$COMPANY" --arg org "$ORG" \
    --arg at "$(dns_now)" --argjson epoch "$(date -u +%s)" \
    --argjson queries "${queries:-0}" \
    --arg origin "$origin" \
    --argjson domains "$(printf '%s\n' "${keep[@]}" |
      jq -Rsc 'split("\n") | map(select(. != ""))')" \
    --argjson skipped "$(printf '%s\n' ${dropped[@]+"${dropped[@]}"} |
      jq -Rsc 'split("\n") | map(select(. != ""))')" \
    --slurpfile rows "$DNS_ROWS" \
    --slurpfile seen "$DNS_SEEN" \
    --slurpfile errors "$DNS_ERRORS" \
    '($rows | group_by(.id)
      | map(([group_by(.domain + " " + .signal)[] | sort_by(.at)[0:3][]]) as $kept
            | {id: .[0].id, name: .[0].name, category: .[0].category,
               portal: .[0].portal,
               domains: (map(.domain) | unique),
               signals: (map(.signal) | unique | sort),
               # A domain carrying five google-site-verification tokens is
               # carrying five copies of one finding. Three of each domain and
               # record kind is enough for anyone to check it; the rest are
               # counted, which is also what keeps this off being a zone dump.
               evidence: ($kept | map({domain, signal, at})
                          | sort_by(.domain, .signal, .at)),
               evidence_omitted: (length - ($kept | length))})
      | sort_by(.id)) as $vendors
     | {company: $company, org: $org,
        generated: $at, generated_epoch: $epoch,
        origin: $origin,
        domains: $domains,
        skipped: $skipped,
        counts: {domains: ($domains | length),
                 skipped: ($skipped | length),
                 queries: $queries,
                 vendors: ($vendors | length),
                 records: ([$seen[].records] | add // 0),
                 records_matched: ([$seen[].matched] | add // 0),
                 records_unmatched: (([$seen[].records] | add // 0)
                                     - ([$seen[].matched] | add // 0))},
        read: $seen,
        vendors: $vendors,
        errors: $errors}' >"$tmp" || {
    rm -f "$tmp"
    die "could not write $out"
  }
  mv "$tmp" "$out"

  rm -rf "$DNS_CACHE"
  rm -f "$DNS_ROWS" "$DNS_SEEN" "$DNS_ERRORS"

  local page="$DIR/map/DNS.md"
  dns_render "$out" >"$page"

  if [[ $as_json == 1 ]]; then
    cat "$out"
    return 0
  fi

  jq -r '.vendors[]
    | "  " + .name + "  " + (.signals | join(",")) + "  " + (.domains | join(" "))' "$out"
  [[ $(jq '.counts.vendors' "$out") -gt 0 ]] && echo

  log "$out"
  log "$page"
  jq -r '"\(.counts.vendors) vendor(s) across \(.counts.domains) domain(s), from "
         + "\(.counts.queries) quer\(if .counts.queries == 1 then "y" else "ies" end) — "
         + "\(.counts.records_matched) of \(.counts.records) records matched the catalogue"' "$out"
  [[ $(jq '.errors | length' "$out") -eq 0 ]] ||
    jq -r '.errors[] | "  " + .domain + ": " + .message' "$out"
  return 0
}

# --- reading it back -----------------------------------------------------------

# How old the reading is, in whole days. A DNS record changes far less often
# than a running deployment, so the threshold is months rather than a week — but
# a reading from before the last renewal season is still worth labelling.
dns_age_days() {
  local f="$DIR/map/dns.json" was now
  [[ -f $f ]] || return 1
  was=$(jq -r '.generated_epoch // empty' "$f" 2>/dev/null)
  [[ -n $was ]] || return 1
  now=$(date -u +%s)
  echo $(((now - was) / 86400))
}

dns_age_phrase() {
  local age=${1:-}
  if [[ -z $age || $age == "?" ]]; then echo "at some point"
  elif [[ $age -le 0 ]]; then echo "today"
  elif [[ $age == 1 ]]; then echo "yesterday"
  elif [[ $age -lt 60 ]]; then echo "$age days ago"
  else echo "$((age / 30)) months ago"
  fi
}

# --- the page ------------------------------------------------------------------

dns_render() {
  local f=$1 age
  age=$(dns_age_days 2>/dev/null || echo "?")

  echo "# $COMPANY — what the DNS says the org has an account with"
  echo
  echo "Read from public DNS $(dns_age_phrase "$age"), from $(jq -r '.origin' "$f")."
  echo
  cat <<'EOF'
Every line below is a record anyone can look up. Re-run the `dig` in the
evidence column and you will see the same thing, which is what makes this
checkable in a way a reading of somebody's cloud account is not.

What a record proves is narrow and worth being exact about. A verification
token is the vendor stating that this organization proved it owns the domain —
that is an account. An MX record says where the mail goes. An SPF `include:`
says a service was given permission to send as the organization. A CNAME says a
subdomain was pointed somewhere on purpose. None of them is an invoice, and
none of them says what anything costs.

A vendor that does not appear here was **not found in this organization's
public DNS**, which is not the same fact as not being in use.
EOF
  echo

  if [[ $(jq -r '.counts.vendors' "$f") == 0 ]]; then
    jq -r '"Nothing in the \(.counts.records) record(s) read across "
           + "\(.counts.domains) domain(s) matched the catalogue."' "$f"
    echo
  else
    jq -r '
      [.vendors[]
       | "### \(.name)",
         "",
         "`vendor:\(.id)` · \(.category) · \(.domains | join(", "))"
           + (if .portal == "" then "" else " · [what it costs](\(.portal))" end),
         "",
         "| Record | Evidence |",
         "|---|---|",
         (.evidence[] | "| `\(.signal)` | `\(.at)` |"),
         (if (.evidence_omitted // 0) > 0
          then "", "<sub>\(.evidence_omitted) further record(s) of the same kind matched"
               + " the same signals and are not repeated here.</sub>"
          else empty end),
         ""]
      | .[]' "$f"
  fi

  jq -r '"Read \(.counts.records) record(s) across \(.counts.domains) domain(s) in "
         + "\(.counts.queries) quer\(if .counts.queries == 1 then "y" else "ies" end). "
         + "\(.counts.records_unmatched) matched nothing in the catalogue and were not "
         + "recorded — only the records behind a finding are kept."' "$f"
  echo

  if [[ $(jq -r '.skipped | length' "$f") -gt 0 ]]; then
    echo "Not queried:"
    echo
    jq -r '.skipped[] | "- " + .' "$f"
    echo
  fi

  if [[ $(jq -r '.errors | length' "$f") -gt 0 ]]; then
    echo "Did not answer:"
    echo
    jq -r '.errors[] | "- **" + .domain + "** — " + .message' "$f"
    echo
  fi

  if [[ $age != "?" && $age -ge $DNS_STALE_DAYS ]]; then
    echo "**Read $(dns_age_phrase "$age") and not since** — a domain can be moved to a"
    echo "different provider in an afternoon. Re-run \`orgami dns\`."
    echo
  fi
}

# The org-level block, for whatever renders the whole map. Silent until somebody
# has run the command.
dns_overview() {
  local f="$DIR/map/dns.json" age n
  [[ -f $f ]] || return 0
  n=$(jq -r '.counts.vendors' "$f" 2>/dev/null || echo 0)
  [[ ${n:-0} -gt 0 ]] || return 0
  age=$(dns_age_days || echo "?")

  echo "## What the DNS says is paid for"
  echo
  jq -r '.vendors[]
    | "- **" + .name + "** — " + .category + " · " + (.domains | join(", "))
      + " · " + (.signals | join(", "))' "$f"
  echo
  echo "Read from public DNS $(dns_age_phrase "$age") with \`orgami dns\`. These are"
  echo "records anybody can look up, so unlike a cloud reading they can be checked"
  echo "afterwards — but a record is evidence of an account, never of a price."
  echo
}
