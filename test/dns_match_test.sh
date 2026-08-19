#!/usr/bin/env bash
# `orgami dns` claims an organization has an *account* with somebody, which is a
# stronger claim than `orgami scan` ever makes — so every one of them has to
# rest on a record a reader can look up, and a record that only resembles one
# has to be left alone.
#
# Runs against a stub `dig` reading a recorded zone off disk. **No query leaves
# this machine.** That is not a convenience: a test that resolved real names
# would pass or fail on somebody else's DNS.
#
# Five things are under test, and one of them is the quiet one:
#
#   - an MX, an SPF include, a TXT verification token and a CNAME each find the
#     vendor behind them, and a near miss finds nothing
#   - SPF is followed one level and only into the organization's own zone, so a
#     vendor hidden behind the usual `include:_spf.<domain>` split is found and
#     the vendors a provider resells to itself are not attributed here
#   - the catalogue parser knows the DNS kinds. A kind missing from
#     VENDOR_SIGNAL_KINDS raises no error — it is swallowed into the regex in
#     front of it and the vendor silently stops matching. That is the failure
#     mode most likely to go unnoticed, so it is asserted twice: once on the
#     list, once on behaviour
#   - a vendor both the code and the DNS name is one vendor with two pieces of
#     evidence, each tagged with where it came from
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC2034  # ROOT is where the libs look for vendors.tsv and advise.jq
ROOT=$PWD

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/scan.sh
source lib/scan.sh
# shellcheck source=../lib/vendors.sh
source lib/vendors.sh
# shellcheck source=../lib/dns.sh
source lib/dns.sh
# shellcheck source=../lib/notes.sh
source lib/notes.sh
# shellcheck source=../lib/advise.sh
source lib/advise.sh

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT

export ORGAMI_HOME="$home"
echo '{"default": "acme"}' >"$home/config.json"
mkdir -p "$home/acme/map" "$home/acme/notes" "$home/bin" "$home/zone"
echo '{"org": "acme"}' >"$home/acme/config.json"

# --- the recorded zone ---------------------------------------------------------
#
# One domain, carrying one of each kind of record the reader knows how to read,
# plus three things that must not be read as vendors: a TXT token that only
# begins like Google's, a CNAME to a host that only ends like Zendesk's, and a
# TXT record that names nobody.
zone="$home/zone"

cat >"$zone/TXT-acme.com" <<'REC'
"v=spf1 include:_spf.acme.com include:sendgrid.net ~all"
"google-site-verification=abc123def456"
"notgoogle-site-verification=this-is-not-google"
"atlassian-domain-verification=xY9zKq"
"MS=ms12345678"
"docusign=11112222-3333-4444-5555-666677778888"
"nothing-anybody-bills-for=true"
REC

# One level down from the apex SPF: the vendor the organization itself invited.
cat >"$zone/TXT-_spf.acme.com" <<'REC'
"v=spf1 include:mailgun.org ~all"
REC

# A provider's own record. Whatever SendGrid includes is SendGrid's supplier,
# not this organization's, so this file must never be read.
cat >"$zone/TXT-sendgrid.net" <<'REC'
"v=spf1 include:_spf.klaviyomail.com ~all"
REC

cat >"$zone/MX-acme.com" <<'REC'
1 aspmx.l.google.com.
5 alt1.aspmx.l.google.com.
REC

cat >"$zone/TXT-_dmarc.acme.com" <<'REC'
"v=DMARC1; p=quarantine; rua=mailto:9f0b41@dmarc.postmarkapp.com"
REC

cat >"$zone/NS-acme.com" <<'REC'
dana.ns.cloudflare.com.
rick.ns.cloudflare.com.
REC

cat >"$zone/CNAME-status.acme.com" <<'REC'
acme.statuspage.io.
REC

cat >"$zone/CNAME-careers.acme.com" <<'REC'
acme-jobs.greenhouse.io.
REC

cat >"$zone/CNAME-help.acme.com" <<'REC'
help.notzendesk.com.
REC

# The stub. Answers only what was recorded, and answers nothing — exit 0, no
# output — for everything else, which is what a resolver does for a name that
# carries no record of that type.
cat >"$home/bin/dig" <<'STUB'
#!/usr/bin/env bash
type=""; name=""
for a in "$@"; do
  case $a in
    +*) continue ;;
    *) if [[ -z $type ]]; then type=$a; else name=$a; fi ;;
  esac
done
f="$ZONE/$type-$name"
[[ -f $f ]] && cat "$f"
exit 0
STUB
chmod +x "$home/bin/dig"
export ZONE="$zone"
PATH="$home/bin:$PATH"

fail=0
assert() {
  local what=$1 want=$2 got
  got=$(jq -r "$3" "$4")
  if [[ $got != "$want" ]]; then
    echo "FAIL $what: expected '$want', got '$got'" >&2
    fail=1
  else
    echo "ok   $what"
  fi
}

# --- the apex, before any query is made ----------------------------------------
#
# Nothing is ever asked about a domain the organization does not own, so the
# derivation is checked on its own.
apex() {
  local what=$1 want=$2 got
  got=$(dns_apex "$3")
  if [[ $got != "$want" ]]; then
    echo "FAIL $what: dns_apex '$3' expected '$want', got '$got'" >&2
    fail=1
  else
    echo "ok   $what"
  fi
}

apex "a subdomain reduces to its apex" acme.com api.acme.com
apex "however deep it is" acme.com api.staging.eu.acme.com
apex "a known two-part suffix is not the apex" acme.co.uk api.staging.acme.co.uk
apex "an apex is already an apex" acme.com acme.com
apex "an address has none" "" 10.0.0.1
apex "a single label has none" "" localhost
apex "and a suffix orgami cannot split is refused, not guessed" "" shop.acme.com.zz

# --- the reading ---------------------------------------------------------------

out="$home/acme/map/dns.json"
# Progress goes to stderr, kept rather than discarded: what the command
# says it queried is part of what is under test.
cmd_dns --yes --domain acme.com >/dev/null 2>"$home/run.log" ||
  { cat "$home/run.log" >&2; echo "FAIL: orgami dns did not run" >&2; exit 1; }
grep -q "asking about acme.com" "$home/run.log" ||
  { echo "FAIL: the run must say which domain it queried" >&2; fail=1; }

# --- one of each kind of record ------------------------------------------------

assert "an MX record finds the mail provider" 1 \
  '[.vendors[] | select(.id == "google-workspace")] | length' "$out"
assert "and keeps the record it was read from" \
  'MX acme.com "1 aspmx.l.google.com." (dig '"$(date -u +%Y-%m-%d)"')' \
  '[.vendors[] | select(.id == "google-workspace") | .evidence[]
    | select(.signal == "mx") | .at] | first' "$out"

assert "an SPF include finds the sender" 1 \
  '[.vendors[] | select(.id == "sendgrid")] | length' "$out"
assert "and the evidence is the whole SPF record" true \
  '[.vendors[] | select(.id == "sendgrid") | .evidence[].at]
   | first | test("^TXT acme.com \"v=spf1 .*include:sendgrid.net")' "$out"

assert "a verification token finds the account" 1 \
  '[.vendors[] | select(.id == "atlassian")] | length' "$out"
assert "so does another vendor's" 1 \
  '[.vendors[] | select(.id == "docusign")] | length' "$out"
assert "and Microsoft's, which is two characters long" 1 \
  '[.vendors[] | select(.id == "microsoft365")] | length' "$out"

assert "a CNAME on a conventional name finds the vendor" 1 \
  '[.vendors[] | select(.id == "statuspage")] | length' "$out"
assert "including the applicant tracker no repo will ever name" 1 \
  '[.vendors[] | select(.id == "greenhouse")] | length' "$out"

assert "a DMARC destination is a vendor" 1 \
  '[.vendors[] | select(.id == "postmark")] | length' "$out"
assert "and the nameservers name one too" 1 \
  '[.vendors[] | select(.id == "cloudflare")] | length' "$out"

# --- SPF is followed one level, into the org's own zone and nowhere else -------

assert "a vendor behind the org's own include: split is still found" 1 \
  '[.vendors[] | select(.id == "mailgun")] | length' "$out"
assert "a provider's own record is its supplier list, not the org's" 0 \
  '[.vendors[] | select(.id == "klaviyo")] | length' "$out"

# --- the near misses -----------------------------------------------------------

assert "a token that only starts like Google's is not Google" 1 \
  '[.vendors[] | select(.id == "google-workspace") | .evidence[]
    | select(.signal == "txt")] | length' "$out"
assert "a host that only ends like Zendesk's is not Zendesk" 0 \
  '[.vendors[] | select(.id == "zendesk")] | length' "$out"
assert "a TXT record nobody bills for matches nothing" true \
  '.counts.records_unmatched > 0' "$out"

# --- the shape of the artifact -------------------------------------------------

assert "every finding carries a domain, a record kind and a record" 0 \
  '[.vendors[] | .evidence[]
    | select((.domain // "") == "" or (.signal // "") == "" or (.at // "") == "")]
   | length' "$out"
assert "every finding names a category" 0 \
  '[.vendors[] | select((.category // "") == "")] | length' "$out"
assert "the reading is dated" true '(.generated_epoch // 0) > 0' "$out"
assert "and says where the domain list came from" "--domain" '.origin' "$out"
assert "the records that matched nothing are counted, not recorded" true \
  '.counts.records == (.counts.records_matched + .counts.records_unmatched)' "$out"

# Nothing secret, and nothing wholesale: the only record text in the file is
# text that matched a signal in the catalogue.
assert "an unmatched TXT record is nowhere in the artifact" 0 \
  '[.. | strings | select(test("nothing-anybody-bills-for"))] | length' "$out"

# --- the parsing guard ---------------------------------------------------------
#
# The one failure this whole file exists to catch. A `|mx:` that VENDOR_SIGNAL_
# KINDS does not know about is not rejected — it is glued onto the end of the
# regex before it, and every vendor behind it stops matching with no error
# anywhere. Asserted on the list first, then on behaviour.
for k in mx spf txt cname ns dmarc; do
  case "|$VENDOR_SIGNAL_KINDS|" in
    *"|$k|"*) ;;
    *)
      echo "FAIL VENDOR_SIGNAL_KINDS does not list '$k' — lib/dns.sh emits it and every signal of that kind is being swallowed" >&2
      fail=1
      ;;
  esac
done

cat >"$home/mini.tsv" <<'TSV'
probe	Probe	test	pkg:^probe$|mx:(^|\.)probe\.example$	https://example.invalid
TSV
printf 'mx\tmail.probe.example\tMX probe.test\n' >"$home/mini.facts"
mini=$(VENDOR_CATALOG="$home/mini.tsv" vendors_match "$home/mini.facts" all)
# Six fields and no seventh: a row with no flags leaves the column off the line
# rather than ending in a tab, because an empty field is not something
# `IFS=$'\t' read` can hand back.
if [[ $mini == $'probe\tProbe\ttest\thttps://example.invalid\tmx\tMX probe.test' ]]; then
  echo "ok   a DNS kind after a code kind opens its own signal"
else
  echo "FAIL a signal after 'pkg:' was swallowed instead of opening a new one: '$mini'" >&2
  fail=1
fi

# And the same thing on the real catalogue: google-workspace lists three `mx:`
# signals before its first `txt:` one, so a broken parser loses all three.
printf 'mx\taspmx.l.google.com\tMX acme.com\n' >"$home/real.facts"
if vendors_match "$home/real.facts" all | grep -q '^google-workspace	'; then
  echo "ok   the shipped catalogue's mx signals survive parsing"
else
  echo "FAIL lib/vendors.tsv's mx signals do not match an MX fact" >&2
  fail=1
fi

# --- one vendor, two independent pieces of evidence ----------------------------
#
# The point of keeping DNS out of graph.json and unioning it in `advise`
# instead: SendGrid is in the code *and* in the SPF record, and that has to
# surface as one vendor the two sources agree on rather than two vendors.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
recent=$(date_shift "$(date -u +%Y-%m-%d)" -3)
cat >"$home/acme/map/graph.json" <<JSON
{"company": "acme", "org": "acme", "generated": "$now",
 "nodes": [
   {"id": "repo:web", "kind": "repo", "name": "web",
    "meta": {"pushed_at": "${recent}T09:00:00Z"}},
   {"id": "vendor:sendgrid", "kind": "vendor", "name": "SendGrid",
    "meta": {"category": "email", "portal": "https://app.sendgrid.com/account/billing"}}],
 "edges": [
   {"from": "repo:web", "to": "vendor:sendgrid", "kind": "uses",
    "evidence": "package.json:9", "signal": "pkg", "confidence": "extracted"}]}
JSON
cat >"$home/acme/map/repos.json" <<JSON
[{"name": "web", "meta": {"pushed_at": "${recent}T09:00:00Z"}}]
JSON

DIR="$home/acme"
# shellcheck disable=SC2034  # COMPANY titles the rendered advise report
COMPANY=acme
# shellcheck disable=SC2034  # ORG is written into the advise artifact header
ORG=acme
artifact="$DIR/map/advise.json"
advise_compute "$artifact" 180

assert "a vendor both sources name is one vendor" 1 \
  '[.vendors[] | select(.id == "sendgrid")] | length' "$artifact"
assert "and it says both found it" "code,dns" \
  '[.vendors[] | select(.id == "sendgrid")][0].sources | join(",")' "$artifact"
assert "the proposal about it carries both pieces of evidence" 2 \
  '[.proposals[] | select(.id == "single-repo-vendor:sendgrid")][0].evidence | length' "$artifact"
assert "each tagged with where it came from" "code,dns" \
  '[.proposals[] | select(.id == "single-repo-vendor:sendgrid")][0].evidence
   | map(.source) | unique | join(",")' "$artifact"
assert "the code half still carries its file:line" "package.json:9" \
  '[.proposals[] | select(.id == "single-repo-vendor:sendgrid")][0].evidence
   | map(select(.source == "code")) | first | .at' "$artifact"
assert "and the DNS half carries a record anyone can look up" true \
  '[.proposals[] | select(.id == "single-repo-vendor:sendgrid")][0].evidence
   | map(select(.source == "dns")) | first | .at | test("^TXT acme.com ")' "$artifact"

assert "a vendor only DNS found gets a proposal of its own" 1 \
  '[.proposals[] | select(.id == "dns-only-vendor:google-workspace")] | length' "$artifact"
assert "which is high confidence, because a token is a statement" high \
  '[.proposals[] | select(.id == "dns-only-vendor:google-workspace")][0].confidence' "$artifact"
assert "a vendor the code already names is not a DNS-only one" 0 \
  '[.proposals[] | select(.id == "dns-only-vendor:sendgrid")] | length' "$artifact"
assert "two workspace suites are one duplicate-category proposal" 1 \
  '[.proposals[] | select(.kind == "duplicate-category" and .category == "workspace")]
   | length' "$artifact"

assert "the artifact says how old the DNS reading is" 0 '.dns.age_days' "$artifact"
assert "and that it is not stale yet" false '.dns.stale' "$artifact"
assert "the counts split code from DNS" "1 10 1" \
  '"\(.counts.vendors_from_code) \(.counts.vendors_from_dns) \(.counts.vendors_from_both)"' \
  "$artifact"

# --- and it reads back ---------------------------------------------------------

page=$(advise_render "$artifact" 0)
grep -q '| Vendor | Source | Where | Found in |' <<<"$page" ||
  { echo "FAIL: the report must say which source each row came from" >&2; fail=1; }
grep -q '| dns | acme.com |' <<<"$page" ||
  { echo "FAIL: a DNS row must name the domain it was read on" >&2; fail=1; }
grep -q 'web/package.json:9' <<<"$page" ||
  { echo "FAIL: a code row must keep its file:line" >&2; fail=1; }
grep -q 'not found in committed configuration' <<<"$page" ||
  { echo "FAIL: the report must still say what it cannot know" >&2; fail=1; }

dnspage="$DIR/map/DNS.md"
[[ -f $dnspage ]] ||
  { echo "FAIL: orgami dns writes no page" >&2; fail=1; }
grep -q 'not found in this organization' "$dnspage" ||
  { echo "FAIL: the DNS page must say what an absence means" >&2; fail=1; }
grep -q 'dig ' "$dnspage" ||
  { echo "FAIL: the DNS page must carry the command that re-runs the check" >&2; fail=1; }

if [[ $fail -eq 0 ]]; then
  echo "dns: every finding is a record you can look up, and the near misses were left alone"
else
  exit 1
fi
