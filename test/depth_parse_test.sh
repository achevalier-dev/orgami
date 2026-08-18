#!/usr/bin/env bash
# The language table in lib/depth.py against real grammars: a definition in each
# language comes back with the line the parser reported, what each language uses
# to mean "exported" is honoured, and a symbol defined in a test directory never
# reaches the repo's surface.
#
# Skips itself when tree-sitter is not installed — the grammars are an optional
# extra, and a machine without them still has a complete orgami.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PY=${ORGAMI_DEPTH_PYTHON:-$HOME/.orgami/.venv/depth/bin/python}
if ! "$PY" -c 'import tree_sitter_language_pack' >/dev/null 2>&1; then
  if python3 -c 'import tree_sitter_language_pack' >/dev/null 2>&1; then
    PY=python3
  else
    echo "tree-sitter not installed — skipping (orgami depth --setup installs it)" >&2
    exit 0
  fi
fi

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

src="$fixture/src/demo"
mkdir -p "$src/lib" "$src/test"

cat >"$src/lib/pay.py" <<'EOF'
import json
from acme.shared import Ledger


def charge_customer(amount):
    return amount


def _private_helper():
    return None
EOF

cat >"$src/lib/api.ts" <<'EOF'
import { Ledger } from "@acme/shared";

export function chargeCustomer(amount: number) {
  return amount;
}

function notExported() {
  return 1;
}
EOF

cat >"$src/lib/store.js" <<'EOF'
const shared = require("@acme/shared");

function chargeAgain(n) { return n; }
function hidden(n) { return n; }

module.exports = { chargeAgain };
EOF

cat >"$src/lib/main.go" <<'EOF'
package main

import "github.com/acme/shared"

func ChargeCustomer(n int) int { return n }

func unexported(n int) int { return n }
EOF

cat >"$src/test/pay_test.py" <<'EOF'
def helper_that_is_not_surface():
    return 1
EOF

out="$fixture/depth.json"
"$PY" lib/depth.py --src "$fixture/src" --out "$out" --jobs 1 >/dev/null

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}
sym() { jq -r "[.repos[0].symbols[] | select(.name == \"$1\")] | first | $2" "$out"; }

check "python: a public function is exported" "$(sym charge_customer .exported)" "true"
check "python: on the line the parser reported" "$(sym charge_customer .line)" "5"
check "python: a leading underscore is not surface" \
  "$(jq '[.repos[0].symbols[] | select(.name == "_private_helper")] | length' "$out")" "0"

check "typescript: an exported function is exported" "$(sym chargeCustomer .exported)" "true"
check "typescript: an unexported one is not listed" \
  "$(jq '[.repos[0].symbols[] | select(.name == "notExported")] | length' "$out")" "0"

check "commonjs: module.exports counts as exported" "$(sym chargeAgain .exported)" "true"
check "commonjs: a private function is not listed" \
  "$(jq '[.repos[0].symbols[] | select(.name == "hidden")] | length' "$out")" "0"

check "go: a capitalised function is exported" "$(sym ChargeCustomer .exported)" "true"
check "go: a lowercase one is not listed" \
  "$(jq '[.repos[0].symbols[] | select(.name == "unexported")] | length' "$out")" "0"

check "a test directory contributes no surface" \
  "$(jq '[.repos[0].symbols[] | select(.file | test("^test/"))] | length' "$out")" "0"

# One row per module, however many files import it — `@acme/shared` is reached
# from both the TypeScript and the CommonJS file, and Python spells the same
# package with dots.
check "every language's import of the shared package is seen" \
  "$(jq '[.repos[0].imports[] | select(.module | test("acme[./]shared"))] | length' "$out")" "3"
check "and the same specifier from two files is counted twice" \
  "$(jq -r '[.repos[0].imports[] | select(.module == "@acme/shared") | .n] | first' "$out")" "2"

check "every language in the fixture parsed" \
  "$(jq '.repos[0].languages | keys | length' "$out")" "4"

check "nothing failed to parse" "$(jq '.repos[0].errors' "$out")" "0"

exit "$fail"
