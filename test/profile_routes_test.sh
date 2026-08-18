#!/usr/bin/env bash
# profile_routes must not surface routes declared in test files. Builds a
# fixture tree with one real route and several test-file routes, sources
# lib/profile.sh, and asserts only the real route lands in the endpoints list.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/profile.sh
source lib/profile.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# A route the repo actually serves.
mkdir -p "$fixture/server"
cat >"$fixture/server/app.js" <<'JS'
app.get('/health', () => {})
app.post('/users', () => {})
JS

# Routes that live in test files — these must not appear in the profile.
cat >"$fixture/server/index.test.ts" <<'TS'
app.get('/foo/:capture{ba(r|z)}', () => {})
TS
mkdir -p "$fixture/server/tests" "$fixture/server/spec" "$fixture/server/__tests__"
cat >"$fixture/server/tests/routes.test.js" <<'JS'
router.get('/bar', () => {})
JS
cat >"$fixture/server/spec/handler.spec.ts" <<'TS'
app.get('/spec-route', () => {})
TS
cat >"$fixture/server/__tests__/edge.test.js" <<'JS'
app.get('/edge', () => {})
JS

routes=$(profile_routes "$fixture")
echo "$routes" >&2

fail=0
grep -q '/health' <<<"$routes" || { echo "FAIL: /health missing" >&2; fail=1; }
grep -q '/users' <<<"$routes" || { echo "FAIL: /users missing" >&2; fail=1; }
for bad in '/foo' '/bar' '/spec-route' '/edge'; do
  if grep -q -- "$bad" <<<"$routes"; then
    echo "FAIL: test-file route $bad surfaced in profile" >&2
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then
  echo "profile_routes: test paths excluded, real routes kept"
else
  exit 1
fi