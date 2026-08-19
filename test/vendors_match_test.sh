#!/usr/bin/env bash
# A vendor edge is a claim that an organization is paying somebody, so it has to
# be as checkable as every other edge: one vendor per repository, the strongest
# evidence, and a file:line that opens. This runs against three hand-written
# checkouts — no clone, no network, no token.
#
# The two things most likely to go quietly wrong are covered on purpose. A
# near-miss package (`stripe-mock`, `not-sentry`) must not be read as the vendor
# it resembles. And sentry.io sits in scan.sh's NOISE_DOMAINS, which keeps it out
# of the host nodes — a URL pointing at it must still find Sentry the vendor.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC2034  # ROOT is where lib/vendors.sh looks for the catalogue
ROOT=$PWD

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/scan.sh
source lib/scan.sh
# shellcheck source=../lib/profile.sh
source lib/profile.sh
# shellcheck source=../lib/vendors.sh
source lib/vendors.sh

# Read back inside jq, to assert the two lists still disagree on purpose.
export NOISE_DOMAINS

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# paid: uses Stripe two ways at once, Resend only through its environment, and
# OpenAI only through a URL in the source.
mkdir -p "$fixture/paid/src"
cat >"$fixture/paid/package.json" <<'JSON'
{
  "name": "paid",
  "dependencies": {
    "express": "^4.18.0",
    "stripe": "^14.0.0",
    "@sentry/node": "^7.100.0"
  },
  "devDependencies": {
    "typescript": "^5.4.0"
  }
}
JSON
cat >"$fixture/paid/.env.example" <<'ENV'
STRIPE_SECRET_KEY=
RESEND_API_KEY=
SLACK_WEBHOOK_URL=
ENV
cat >"$fixture/paid/src/index.ts" <<'TS'
export const model = "gpt-4o";
export const url = "https://api.openai.com/v1/chat/completions";
TS

# lookalike: nothing here is a vendor. `stripe-mock` is a test double, `not-sentry`
# is a joke, and the anthropic.com URL is a JSON schema — none of them may be read
# as the real thing.
mkdir -p "$fixture/lookalike"
cat >"$fixture/lookalike/plugin.json" <<'JSON'
{
  "$schema": "https://anthropic.com/claude-code/plugin.schema.json",
  "name": "lookalike"
}
JSON
cat >"$fixture/lookalike/package.json" <<'JSON'
{
  "name": "lookalike",
  "dependencies": {
    "stripe-mock": "^1.0.0",
    "not-sentry": "^2.0.0",
    "sentry-webpack-plugin": "^1.0.0"
  }
}
JSON

# infra: a Sentry URL and nothing else Sentry-shaped, plus one terraform
# provider. sentry.io is a NOISE_DOMAIN; the vendor still has to be found.
mkdir -p "$fixture/infra"
cat >"$fixture/infra/app.rb" <<'RB'
# frozen_string_literal: true
REPORT_TO = "https://sentry.io/api/1234/store/"
RB
cat >"$fixture/infra/main.tf" <<'TF'
provider "datadog" {
  api_url = "https://api.datadoghq.com/"
}
TF

EMITDIR=$(mktemp -d)
trap 'rm -rf "$fixture" "$EMITDIR"' EXIT
EMIT="$EMITDIR/e.ndjson"
: >"$EMIT"

vendors_scan paid "$fixture/paid"
vendors_scan lookalike "$fixture/lookalike"
vendors_scan infra "$fixture/infra"

emitted=$(jq -s . "$EMIT")

fail=0
assert() {
  local what=$1 want=$2 got
  got=$(jq -r "$3" <<<"$emitted")
  if [[ $got != "$want" ]]; then
    echo "FAIL $what: expected '$want', got '$got'" >&2
    fail=1
  else
    echo "ok   $what"
  fi
}

# --- a package name, and only one edge for a vendor found twice ---------------

assert "a dependency finds the vendor" "1" \
  '[.[] | select(.t == "edge" and .from == "repo:paid" and .to == "vendor:stripe")] | length'
assert "and the manifest beats the environment variable" "package.json:5" \
  '[.[] | select(.t == "edge" and .from == "repo:paid" and .to == "vendor:stripe")
   | .evidence] | first'
assert "a scoped package matches its prefix" "package.json:6" \
  '[.[] | select(.t == "edge" and .from == "repo:paid" and .to == "vendor:sentry")
   | .evidence] | first'

# --- an environment variable, and a host ---------------------------------------

assert "an env var name alone is enough" ".env.example:2" \
  '[.[] | select(.t == "edge" and .from == "repo:paid" and .to == "vendor:resend")
   | .evidence] | first'
assert "a literal URL alone is enough" "src/index.ts:2" \
  '[.[] | select(.t == "edge" and .from == "repo:paid" and .to == "vendor:openai")
   | .evidence] | first'

# --- the near miss --------------------------------------------------------------

assert "stripe-mock is not Stripe" "0" \
  '[.[] | select(.t == "edge" and .from == "repo:lookalike" and .to == "vendor:stripe")] | length'
assert "not-sentry is not Sentry" "0" \
  '[.[] | select(.t == "edge" and .from == "repo:lookalike" and .to == "vendor:sentry")] | length'
assert "a schema URL is a reference, not a supplier" "0" \
  '[.[] | select(.t == "edge" and .from == "repo:lookalike" and .to == "vendor:anthropic")] | length'
assert "a repo that buys nothing gets no edges" "0" \
  '[.[] | select(.t == "edge" and .from == "repo:lookalike")] | length'

# --- the NOISE_DOMAINS overlap, and terraform -----------------------------------

assert "sentry.io is a noise domain and still finds Sentry" "app.rb:2" \
  '[.[] | select(.t == "edge" and .from == "repo:infra" and .to == "vendor:sentry")
   | .evidence] | first'
assert "and it is still noise as a host" "true" \
  '"sentry.io" | test($ENV.NOISE_DOMAINS)'
assert "a terraform provider finds the vendor" "main.tf:1" \
  '[.[] | select(.t == "edge" and .from == "repo:infra" and .to == "vendor:datadog")
   | .evidence] | first'

# --- the shape every vendor edge and node has to have ---------------------------

assert "every vendor edge is extracted, never inferred" "0" \
  '[.[] | select(.t == "edge" and (.to | startswith("vendor:")))
   | select(.confidence != "extracted")] | length'
assert "every vendor edge carries evidence" "0" \
  '[.[] | select(.t == "edge" and (.to | startswith("vendor:")))
   | select((.evidence // "") == "")] | length'
assert "every vendor node carries its category" "0" \
  '[.[] | select(.t == "node" and .kind == "vendor")
   | select((.meta.category // "") == "")] | length'
assert "every vendor node carries its portal" "0" \
  '[.[] | select(.t == "node" and .kind == "vendor")
   | select((.meta.portal // "") == "")] | length'
assert "every vendor node carries a flags list, empty or not" "0" \
  '[.[] | select(.t == "node" and .kind == "vendor")
   | select((.meta.flags | type) != "array")] | length'
assert "a flagged vendor's node says so" "no-sdk" \
  '[.[] | select(.t == "node" and .id == "vendor:slack")][0].meta.flags | join(",")'
assert "and an unflagged one carries an empty list, not a missing key" "0" \
  '[.[] | select(.t == "node" and .id == "vendor:stripe")][0].meta.flags | length'

# --- the sixth column ----------------------------------------------------------
#
# `flags` was added to the end of a row that had five columns for a year, and a
# positional parser that reads one field too many or too few does not fail — it
# quietly puts the portal in the signals column and the vendor stops matching.
# So the parse is asserted field by field: a row that carries a flag, a row that
# does not, and then the shipped catalogue.

mkdir -p "$fixture/six"
cat >"$fixture/six/cat.tsv" <<'TSV'
plain	Plain	test	pkg:^plain$	https://plain.example/billing
flagged	Flagged	test	pkg:^flagged$	https://flagged.example/billing	no-sdk
TSV
printf 'pkg\tplain\tpackage.json:2\npkg\tflagged\tpackage.json:3\n' >"$fixture/six/facts"
six=$(VENDOR_CATALOG="$fixture/six/cat.tsv" vendors_match "$fixture/six/facts")

want=$'flagged\tFlagged\ttest\thttps://flagged.example/billing\tpkg\tpackage.json:3\tno-sdk\nplain\tPlain\ttest\thttps://plain.example/billing\tpkg\tpackage.json:2'
if [[ $six == "$want" ]]; then
  echo "ok   a flagged row gains a seventh field and an unflagged one keeps six"
else
  echo "FAIL the flags column moved another field:" >&2
  printf '%s\n' "$six" | cat -A >&2
  fail=1
fi

# The reason the column is last and omitted rather than empty: `IFS=$'\t' read`
# treats a tab as whitespace, so an empty field in the middle of the line does
# not arrive empty — it vanishes and everything after it shifts left. Asserted
# through `read` itself, since that is how both callers consume these lines.
IFS=$'\t' read -r r_id r_name r_cat r_portal r_kind r_ev r_flags \
  <<<"$(VENDOR_CATALOG="$fixture/six/cat.tsv" vendors_match "$fixture/six/facts" | tail -1)"
if [[ $r_id == plain && $r_name == Plain && $r_cat == test &&
      $r_portal == "https://plain.example/billing" &&
      $r_kind == pkg && $r_ev == "package.json:2" && -z $r_flags ]]; then
  echo "ok   a row with no flags survives IFS=tab read with every field in place"
else
  echo "FAIL a flagless row shifted under read:" >&2
  echo "  id=$r_id name=$r_name category=$r_cat portal=$r_portal" >&2
  echo "  kind=$r_kind ev=$r_ev flags=$r_flags" >&2
  fail=1
fi

# A row that never had flags has to parse exactly as it did before the column
# existed. Stripe carries the longest signals list in the catalogue, so a
# mis-split shows up here first.
tsvf=$(mktemp)
printf 'pkg\tstripe\tpackage.json:9\n' >"$tsvf"
stripe=$(vendors_match "$tsvf")
if [[ $stripe == $'stripe\tStripe\tpayments\thttps://dashboard.stripe.com/settings/billing\tpkg\tpackage.json:9' ]]; then
  echo "ok   an unflagged catalogue row parses exactly as it did with five columns"
else
  echo "FAIL an unflagged row was changed by the new column: '$stripe'" >&2
  fail=1
fi

# And the flag actually reaches the graph, which is the only reason it exists.
printf 'env\tSLACK_WEBHOOK_URL\t.env.example:4\n' >"$tsvf"
slack=$(vendors_match "$tsvf")
rm -f "$tsvf"
if [[ $slack == *$'\tenv\t.env.example:4\tno-sdk' ]]; then
  echo "ok   a flagged vendor carries no-sdk out of the catalogue"
else
  echo "FAIL slack lost its no-sdk flag: '$slack'" >&2
  fail=1
fi

# A signal whose kind is misspelled matches nothing and says nothing about it, so
# the catalogue's own shape is checked here rather than discovered by a gap in
# somebody's map a month later.
catalogue=$(awk -F'\t' -v kinds="^($VENDOR_SIGNAL_KINDS):" '
  /^#/ || /^[[:space:]]*$/ { next }
  {
    # Five columns, or six when the row carries flags. A row with more has a
    # stray tab in it, which would shift portal into signals and take the
    # vendor off the map without saying so.
    if (NF != 5 && NF != 6) { print "row " NR ": " NF " fields, expected 5 or 6"; bad = 1 }
    if (NF == 6) {
      if ($6 == "") { print "row " NR " (" $1 "): empty flags column — end the row at portal instead"; bad = 1 }
      nfl = split($6, fl, ",")
      for (j = 1; j <= nfl; j++)
        if (fl[j] != "no-sdk") { print "row " NR " (" $1 "): unknown flag " fl[j]; bad = 1 }
    }
    n = split($4, part, "|"); cur = ""; count = 0
    for (i = 1; i <= n; i++) {
      if (part[i] ~ kinds) { if (cur != "") count++; cur = part[i] }
      else if (cur != "") cur = cur "|" part[i]
      else { print "row " NR " (" $1 "): " part[i] " names no known kind"; bad = 1 }
    }
    if (cur != "") count++
    if (count == 0) { print "row " NR " (" $1 "): no signals"; bad = 1 }
    seen[$1]++
    if (seen[$1] > 1) { print "row " NR ": " $1 " appears twice"; bad = 1 }
  }
  END { exit bad }' lib/vendors.tsv) || {
  echo "FAIL the catalogue is malformed:" >&2
  echo "$catalogue" >&2
  fail=1
}
[[ -n $catalogue ]] || echo "ok   every catalogue row names a kind orgami looks for"

# The whole point: every citation opens. Not "the file exists" — the line exists.
while IFS= read -r cite; do
  [[ -n $cite ]] || continue
  repo=${cite%% *}
  ref=${cite#* }
  file="$fixture/$repo/${ref%:*}"
  line=${ref##*:}
  if [[ ! -f $file ]]; then
    echo "FAIL evidence names a file that is not there: $cite" >&2
    fail=1
  elif [[ $line -lt 1 || $line -gt $(grep -c '' "$file") ]]; then
    echo "FAIL evidence names a line that is not there: $cite" >&2
    fail=1
  fi
done < <(jq -r '.[] | select(.t == "edge" and (.to | startswith("vendor:")))
                | (.from | sub("^repo:"; "")) + " " + .evidence' <<<"$emitted")
[[ $fail == 0 ]] && echo "ok   every citation points at a line that exists"

exit "$fail"
