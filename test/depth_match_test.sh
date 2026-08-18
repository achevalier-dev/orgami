#!/usr/bin/env bash
# `orgami depth` may only call an edge `extracted` when the import statement
# resolves to exactly one repository on its own — a specifier carrying the
# organization. An import that merely happens to spell a repository name is a
# resemblance, and has to come out `inferred`. Neither may point a repo at
# itself.
#
# Runs against a hand-written depth.json, so no tree-sitter and no checkouts:
# this is the judgement, not the parser.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/depth.sh
source lib/depth.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

DIR="$fixture"
# shellcheck disable=SC2034  # ORG is read by depth_merge_graph, not by this test
ORG=acme
mkdir -p "$DIR/map"

cat >"$DIR/map/graph.json" <<'JSON'
{"org": "acme",
 "nodes": [{"id": "repo:web", "kind": "repo", "name": "web"},
           {"id": "repo:billing", "kind": "repo", "name": "billing"},
           {"id": "repo:shared", "kind": "repo", "name": "shared"},
           {"id": "repo:api", "kind": "repo", "name": "api"}],
 "edges": []}
JSON

# web: names the org outright, so it resolves and nothing else could match.
# billing: a bare specifier that is also a repo name — a guess.
# shared: imports itself by name, which is a directory next door, not an edge.
# api: three letters, too short to be worth matching on at all.
cat >"$DIR/map/depth.json" <<'JSON'
{"repos": [
  {"name": "web", "imports": [
    {"module": "@acme/shared", "file": "src/app.ts", "line": 3, "n": 9},
    {"module": "github.com/acme/billing/client", "file": "src/pay.ts", "line": 8, "n": 1},
    {"module": "react", "file": "src/app.ts", "line": 1, "n": 40}]},
  {"name": "billing", "imports": [
    {"module": "shared", "file": "lib/db.js", "line": 2, "n": 4},
    {"module": "../shared", "file": "lib/x.js", "line": 1, "n": 1}]},
  {"name": "shared", "imports": [
    {"module": "shared", "file": "index.js", "line": 1, "n": 1}]},
  {"name": "api", "imports": [
    {"module": "api", "file": "main.go", "line": 4, "n": 1}]}
]}
JSON

depth_merge_graph

fail=0
assert() {
  local what=$1 want=$2 got
  got=$(jq -r "$3" "$DIR/map/graph.json")
  if [[ $got != "$want" ]]; then
    echo "FAIL $what: expected '$want', got '$got'" >&2
    fail=1
  else
    echo "ok   $what"
  fi
}

assert "@acme/shared is extracted" "extracted" \
  '[.edges[] | select(.from == "repo:web" and .to == "repo:shared") | .confidence] | first // "none"'

assert "@acme/shared carries the line" "src/app.ts:3" \
  '[.edges[] | select(.from == "repo:web" and .to == "repo:shared")
   | .evidence | split(" — ")[0]] | first // "none"'

assert "github.com/acme/billing is extracted" "extracted" \
  '[.edges[] | select(.from == "repo:web" and .to == "repo:billing") | .confidence] | first // "none"'

assert "a bare name that is also a repo is inferred" "inferred" \
  '[.edges[] | select(.from == "repo:billing" and .to == "repo:shared") | .confidence] | first // "none"'

assert "no repo imports itself" "0" \
  '[.edges[] | select(.kind == "imports" and .from == .to)] | length'

assert "a relative path is never an edge" "0" \
  '[.edges[] | select(.evidence != null and (.evidence | test("\\.\\./")))] | length'

assert "an unmatched package is not an edge" "0" \
  '[.edges[] | select(.evidence != null and (.evidence | test("react")))] | length'

assert "a name under four characters is not matched" "0" \
  '[.edges[] | select(.to == "repo:api")] | length'

assert "every import edge says which kind it is" "0" \
  '[.edges[] | select(.kind == "imports" and (.confidence | not))] | length'

exit "$fail"
