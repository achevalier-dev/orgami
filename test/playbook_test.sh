#!/usr/bin/env bash
# A playbook is the one file in the map whose prose a model writes, so the
# gathering that feeds it has to be exact: the instances it counts, the pull
# requests it decides are the same job, and the refusal to write anything at all
# from a single instance — a procedure invented from one case is a guess with a
# heading on it.
#
# Runs against hand-written notes and a hand-written pull request cache. No
# model call, no network: this is the evidence, not the writing.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck disable=SC2034  # ROOT is read by the library, not by this test
ROOT=$PWD
# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/notes.sh
source lib/notes.sh
# shellcheck source=../lib/playbook.sh
source lib/playbook.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

DIR="$fixture"
# shellcheck disable=SC2034  # COMPANY is read by the library, not by this test
COMPANY=acme
# shellcheck disable=SC2034  # read by the library, not by this test
ORG=acme
mkdir -p "$DIR/notes" "$DIR/map" "$DIR/cache/prs"

note() { # note <id> <repo> <topic> <tags> <body>
  cat >"$DIR/notes/$1.md" <<EOF
---
id: $1
author: tester
date: 2026-08-1${1: -1}T09:00:00Z
repo: $2
${3:+topic: $3}
tags: [$4]
---

$5
EOF
}

note 20260810-090000-a scraphome broken-fetcher pattern \
  "The Carmax fetcher returned an empty list instead of throwing when the site moved to a client-side table."
note 20260811-090001-b scraphome broken-fetcher pattern \
  "The IAAI fetcher read only the first page after they paginated, so the job succeeded with half the lots."
note 20260812-090002-c scraphome new-endpoint pattern \
  "Adding an endpoint means a route, a schema and a line in the worker manifest."
note 20260813-090003-d WinIt-backend "" gotcha \
  "The health endpoint answers before Parse is connected, so it is not a readiness check."
note 20260814-090004-e scraphome "" gotcha \
  "Every fetcher shares one proxy pool; exhausting it in one job starves the rest."

cat >"$DIR/map/repos.json" <<'JSON'
[{"name": "scraphome", "meta": {"language": "TypeScript"}, "frameworks": ["Fastify"],
  "commands": {"package_manager": "npm", "scripts": {"build:worker": "node scripts/build-worker.js"}}},
 {"name": "WinIt-backend", "meta": {"language": "JavaScript"}, "frameworks": [],
  "commands": {"package_manager": "npm", "scripts": {}}}]
JSON

cat >"$DIR/cache/prs/2026-W33.json" <<'JSON'
{"prs": [
  {"number": 10, "title": "fix(carmax): headless path for the broken fetcher",
   "bodyText": "The fetcher returned nothing.", "mergedAt": "2026-08-11T00:00:00Z",
   "author": {"login": "tester"}, "repository": {"name": "scraphome"},
   "reviewThreads": {"nodes": [{"comments": {"nodes": [{"path": "src/fetchers/carmax.ts"}]}}]}},
  {"number": 11, "title": "chore(deps): bump fastify",
   "bodyText": "Routine.", "mergedAt": "2026-08-12T00:00:00Z",
   "author": {"login": "tester"}, "repository": {"name": "scraphome"},
   "reviewThreads": {"nodes": []}},
  {"number": 12, "title": "fix(fetcher): retry the broken pool",
   "bodyText": "Not this repository.", "mergedAt": "2026-08-12T00:00:00Z",
   "author": {"login": "tester"}, "repository": {"name": "WinIt-backend"},
   "reviewThreads": {"nodes": []}}
]}
JSON

fail() { echo "playbook: $*" >&2; exit 1; }

# --- the instances -----------------------------------------------------------

got=$(playbook_instance_count scraphome broken-fetcher)
[[ $got == 2 ]] || fail "expected 2 instances of broken-fetcher, got $got"

got=$(playbook_instance_count scraphome new-endpoint)
[[ $got == 1 ]] || fail "expected 1 instance of new-endpoint, got $got"

# A gotcha is a standing fact, not an instance, even on a repo that has both.
got=$(playbook_topics scraphome | sort | paste -sd, -)
[[ $got == "broken-fetcher,new-endpoint" ]] || fail "topics should be the pattern notes only, got '$got'"

got=$(playbook_topics WinIt-backend | wc -l)
[[ $got == 0 ]] || fail "a repo with no pattern note has no topics, got $got"

# --- the refusal -------------------------------------------------------------

# One instance is not a procedure. Nothing is written, and nothing is claimed.
if playbook_write scraphome new-endpoint >/dev/null 2>&1; then
  fail "wrote a playbook from a single instance"
fi
[[ ! -f $(playbook_file scraphome new-endpoint) ]] ||
  fail "a refused playbook left a file behind"

# --- what counts as the same job ---------------------------------------------

re=$(playbook_regex broken-fetcher)
[[ $re == *fetcher* ]] || fail "the topic's own word should be searched for, got '$re'"

# Words every repository uses match every pull request, which is the same as
# matching none of them.
re=$(playbook_regex fix-the-new-job)
[[ $re != *"fix"* && $re != *"the"* && $re != *"new"* ]] ||
  fail "common words should not be searched for, got '$re'"

prs=$(playbook_prs scraphome broken-fetcher)
grep -q 'scraphome#10' <<<"$prs" || fail "the matching pull request was not found"
grep -q 'scraphome#11' <<<"$prs" && fail "an unrelated pull request was pulled in"
grep -q '#12' <<<"$prs" && fail "another repository's pull request was pulled in"
grep -q 'src/fetchers/carmax.ts' <<<"$prs" || fail "the reviewed file was not carried through"

# --- what the model is handed ------------------------------------------------

evidence=$(playbook_evidence scraphome broken-fetcher)
grep -q 'script build:worker: node scripts/build-worker.js' <<<"$evidence" ||
  fail "the evidence must carry the commands the procedure ends in"
grep -q 'Carmax fetcher returned an empty list' <<<"$evidence" ||
  fail "the evidence must carry the instances"
grep -q 'Every fetcher shares one proxy pool' <<<"$evidence" ||
  fail "a standing fact naming the topic belongs in the evidence"
grep -q 'health endpoint answers before Parse' <<<"$evidence" &&
  fail "another repository's note reached the evidence"

# --- what a card shows -------------------------------------------------------

[[ -z $(playbook_section scraphome) ]] ||
  fail "a repo with no playbook file must show no section"

mkdir -p "$(playbook_dir)"
: >"$(playbook_file scraphome broken-fetcher)"
grep -q 'broken fetcher' <<<"$(playbook_section scraphome)" ||
  fail "the written playbook is missing from the repo card"
grep -q 'broken-fetcher' <<<"$(playbook_brief scraphome)" ||
  fail "the written playbook is missing from the session brief"
[[ -z $(playbook_brief WinIt-backend) ]] ||
  fail "a repo with no playbook must add nothing to the brief"

echo "playbook: instances counted, one instance refused, the same job matched"
