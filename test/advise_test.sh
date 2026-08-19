#!/usr/bin/env bash
# `orgami advise` may only propose what the map already proves, and it may only
# propose it once. Four judgements are under test:
#
#   - two vendors in one category is a duplicate; one vendor in two repos is not
#     a single-repo vendor
#   - a vendor wired into a repo nobody has pushed to is an orphan; one in a repo
#     pushed to last week is not
#   - a vendor matched only by an env signal is a ghost; the same vendor matched
#     by a package manifest anywhere in that repo is not
#   - the same map produces the same proposal ids twice running, because a
#     rejection recorded against an id has to still match next Monday
#
# And then the loop that makes the whole thing worth running: rejecting a
# proposal writes a note, and the note takes the proposal off the report.
#
# Runs against a hand-written graph.json — no scan, no checkouts, no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC2034  # ROOT is how advise.sh finds advise.jq and vendors.tsv
ROOT=$PWD

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/notes.sh
source lib/notes.sh
# shellcheck source=../lib/advise.sh
source lib/advise.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

DIR="$fixture"
# shellcheck disable=SC2034  # COMPANY titles the rendered report
COMPANY=acme
# shellcheck disable=SC2034  # ORG is written into the artifact header, not read here
ORG=acme
mkdir -p "$DIR/map" "$DIR/notes"

old=$(date_shift "$(date -u +%Y-%m-%d)" -400)
new=$(date_shift "$(date -u +%Y-%m-%d)" -3)

# Two payments vendors — stripe in two repos, paddle in one — so the duplicate
# fires, paddle is the consolidation candidate, and stripe must not be reported
# as a single-repo vendor. sentry is alone in its category and alone in `legacy`,
# which has not been pushed to in over a year: one single-repo vendor and one
# orphan, from the same edge. twilio is declared in `api` by an env file only.
cat >"$DIR/map/graph.json" <<JSON
{"company": "acme", "org": "acme", "generated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
 "nodes": [
   {"id": "repo:api", "kind": "repo", "name": "api", "meta": {"pushed_at": "${new}T09:00:00Z"}},
   {"id": "repo:web", "kind": "repo", "name": "web", "meta": {"pushed_at": "${new}T09:00:00Z"}},
   {"id": "repo:legacy", "kind": "repo", "name": "legacy", "meta": {"pushed_at": "${old}T09:00:00Z"}},
   {"id": "vendor:stripe", "kind": "vendor", "name": "Stripe", "meta": {"category": "payments"}},
   {"id": "vendor:paddle", "kind": "vendor", "name": "Paddle", "meta": {"category": "payments"}},
   {"id": "vendor:sentry", "kind": "vendor", "name": "Sentry", "meta": {"category": "error-tracking"}},
   {"id": "vendor:twilio", "kind": "vendor", "name": "Twilio", "meta": {"category": "sms"}}],
 "edges": [
   {"from": "repo:api", "to": "vendor:stripe", "kind": "uses",
    "evidence": "package.json:31", "signal": "pkg", "confidence": "extracted"},
   {"from": "repo:web", "to": "vendor:stripe", "kind": "uses",
    "evidence": "package.json:12", "signal": "pkg", "confidence": "extracted"},
   {"from": "repo:api", "to": "vendor:paddle", "kind": "uses",
    "evidence": "package.json:44", "signal": "pkg", "confidence": "extracted"},
   {"from": "repo:legacy", "to": "vendor:sentry", "kind": "uses",
    "evidence": "requirements.txt:8", "signal": "pkg", "confidence": "extracted"},
   {"from": "repo:api", "to": "vendor:twilio", "kind": "uses",
    "evidence": ".env.example:14", "signal": "env", "confidence": "extracted"},
   {"from": "repo:api", "to": "tool:docker", "kind": "uses",
    "evidence": "Dockerfile", "confidence": "extracted"}]}
JSON

cat >"$DIR/map/repos.json" <<JSON
[{"name": "api", "meta": {"pushed_at": "${new}T09:00:00Z"}},
 {"name": "legacy", "meta": {"pushed_at": "${old}T09:00:00Z"}},
 {"name": "web", "meta": {"pushed_at": "${new}T09:00:00Z"}}]
JSON

artifact="$DIR/map/advise.json"
advise_compute "$artifact" 180

fail=0
assert() {
  local what=$1 want=$2 got
  got=$(jq -r "$3" "$artifact")
  if [[ $got != "$want" ]]; then
    echo "FAIL $what: expected '$want', got '$got'" >&2
    fail=1
  else
    echo "ok   $what"
  fi
}

# --- the four proposals -------------------------------------------------------

assert "two payments vendors are one duplicate-category proposal" 1 \
  '[.proposals[] | select(.kind == "duplicate-category")] | length'
assert "the duplicate names both vendors" "paddle,stripe" \
  '[.proposals[] | select(.kind == "duplicate-category")][0].vendors | join(",")'
assert "the vendor in the fewest repos is the candidate" paddle \
  '[.proposals[] | select(.kind == "duplicate-category")][0].candidate'
assert "and it is high confidence" high \
  '[.proposals[] | select(.kind == "duplicate-category")][0].confidence'
assert "the duplicate carries every file:line" \
  "package.json:12,package.json:31,package.json:44" \
  '[.proposals[] | select(.kind == "duplicate-category")][0].evidence
   | map(.at) | sort | join(",")'

assert "paddle, sentry and twilio are single-repo vendors" "paddle,sentry,twilio" \
  '[.proposals[] | select(.kind == "single-repo-vendor") | .vendors[0]] | sort | join(",")'
assert "a vendor in two repos is not a single-repo vendor" 0 \
  '[.proposals[] | select(.kind == "single-repo-vendor")
   | select(.vendors[0] == "stripe")] | length'
assert "single-repo is medium confidence" medium \
  '[.proposals[] | select(.kind == "single-repo-vendor")][0].confidence'

assert "the vendor in the quiet repo is an orphan" sentry \
  '[.proposals[] | select(.kind == "orphan-vendor")][0].vendors[0]'
assert "only that one" 1 \
  '[.proposals[] | select(.kind == "orphan-vendor")] | length'
assert "the orphan reports how long the repo has been quiet" true \
  '[.proposals[] | select(.kind == "orphan-vendor")][0].days_since_push > 180'
assert "and keeps the edge it was matched on" "requirements.txt:8" \
  '[.proposals[] | select(.kind == "orphan-vendor")][0].evidence[0].at'

assert "the env-only vendor is a ghost" twilio \
  '[.proposals[] | select(.kind == "ghost-env-var")][0].vendors[0]'
assert "a vendor with a package manifest behind it is not" 0 \
  '[.proposals[] | select(.kind == "ghost-env-var")
   | select(.vendors[0] != "twilio")] | length'
assert "the ghost cites the declaring line" ".env.example:14" \
  '[.proposals[] | select(.kind == "ghost-env-var")][0].evidence[0].at'

assert "a tool edge is not mistaken for a vendor" 0 \
  '[.vendors[] | select(.id == "docker")] | length'

# --- ranking ------------------------------------------------------------------

assert "high confidence is ranked above medium" true \
  '([.proposals[] | select(.confidence == "high") | .rank] | max)
   < ([.proposals[] | select(.confidence == "medium") | .rank] | min)'
assert "and blast radius puts the widest proposal first" "duplicate-category 2" \
  '.proposals[0] | .kind + " " + (.repo_count | tostring)'

# --- ids are stable ------------------------------------------------------------
#
# A rejection is stored against an id. If the id moved between runs the
# rejection would silently stop matching, and the report would ask again.

first=$(jq -Sc '[.proposals[].id] | sort' "$artifact")
advise_compute "$artifact" 180
second=$(jq -Sc '[.proposals[].id] | sort' "$artifact")
if [[ $first == "$second" ]]; then
  echo "ok   the same map produces the same ids twice running"
else
  echo "FAIL ids moved between runs:" >&2
  echo "  $first" >&2
  echo "  $second" >&2
  fail=1
fi

case $first in
  *'"duplicate-category:payments:paddle+stripe"'*)
    echo "ok   the id says what it is about, without a hash" ;;
  *)
    echo "FAIL the duplicate id is not the readable one: $first" >&2; fail=1 ;;
esac

before=$(jq '.counts.proposals' "$artifact")

# --- suppression ---------------------------------------------------------------
#
# Written by hand in the shape cmd_note writes, so the test needs no gh, no git
# identity and no company config: what is under test is that advise reads the
# team's notes back, not that cmd_note can write a file.
cat >"$DIR/notes/20260101-000000-ada-two-payments-on-purpose.md" <<'NOTE'
---
id: 20260101-000000-ada-two-payments-on-purpose
author: ada
date: 2026-01-01T00:00:00Z
tags: [advise-suppressed]
---

Paddle bills the EU entity and Stripe bills everything else. Two payment
processors is the tax setup, not an oversight.

<!-- orgami advise: suppressed duplicate-category:payments:paddle+stripe -->
NOTE

advise_compute "$artifact" 180

assert "the rejected proposal is off the report" 0 \
  '[.proposals[] | select(.kind == "duplicate-category")] | length'
assert "one fewer proposal than before" "$((before - 1))" '.counts.proposals'
assert "it is counted as suppressed, not lost" 1 '.counts.suppressed'
assert "and can still be read back" "duplicate-category:payments:paddle+stripe" \
  '.suppressed[0].id'
assert "with the reason, which is the half worth keeping" true \
  '.suppressed[0].suppression.reason | test("tax setup")'
assert "and who said it" ada '.suppressed[0].suppression.author'
assert "nothing else was suppressed by accident" 5 '.counts.proposals'
assert "the ranks close up behind it" "1,2,3,4,5" \
  '[.proposals[].rank] | sort | join(",")'

# --- the report ----------------------------------------------------------------

page=$(advise_render "$artifact" 0)
grep -q '^# acme — vendor advisories' <<<"$page" ||
  { echo "FAIL: the report has no title" >&2; fail=1; }
grep -q 'legacy/requirements.txt:8' <<<"$page" ||
  { echo "FAIL: the report drops the evidence path" >&2; fail=1; }
grep -q 'not found in committed configuration' <<<"$page" ||
  { echo "FAIL: the report must say what it cannot know" >&2; fail=1; }
grep -q 'orgami advise --all' <<<"$page" ||
  { echo "FAIL: a suppressed proposal must be reachable" >&2; fail=1; }
grep -q 'tax setup' <<<"$page" &&
  { echo "FAIL: a suppressed proposal leaked into the default report" >&2; fail=1; }

page_all=$(advise_render "$artifact" 1)
grep -q 'tax setup' <<<"$page_all" ||
  { echo "FAIL: --all must show the reason a proposal was dropped" >&2; fail=1; }

# --- the empty state is a good outcome, not an error ---------------------------

empty=$(mktemp -d)
mkdir -p "$empty/map" "$empty/notes"
jq '{company, org, generated, nodes: [.nodes[] | select(.kind == "repo")], edges: []}' \
  "$DIR/map/graph.json" >"$empty/map/graph.json"
cp "$DIR/map/repos.json" "$empty/map/repos.json"
saved=$DIR
DIR="$empty"
advise_compute "$empty/map/advise.json" 180
empty_page=$(advise_render "$empty/map/advise.json" 0)
DIR="$saved"
grep -q 'has no vendor nodes' <<<"$empty_page" ||
  { echo "FAIL: a map with no vendors must say so plainly" >&2; echo "$empty_page" >&2; fail=1; }
rm -rf "$empty"

if [[ $fail -eq 0 ]]; then
  echo "advise: every proposal carries its file:line, ids hold still, and a rejection sticks"
else
  exit 1
fi
