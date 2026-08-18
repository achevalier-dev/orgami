#!/usr/bin/env bash
# map/graph.html has to be openable from a file:// URL on a laptop with no
# network, and it has to say the same thing map/graph.json says. So: nothing
# fetched from anywhere, the data block still parses as JSON after being pasted
# into HTML, and every node and edge survives the trip — including a repository
# whose description is trying to close the script tag.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/html.sh
source lib/html.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

DIR="$fixture"
COMPANY="Ac<me> & Co"
mkdir -p "$DIR/map"

cat >"$DIR/map/graph.json" <<'JSON'
{"company": "acme", "org": "acme", "generated": "2026-08-18T00:00:00Z",
 "nodes": [
   {"id": "repo:web", "kind": "repo", "name": "web",
    "meta": {"language": "TypeScript", "url": "https://github.com/acme/web",
             "description": "storefront </script><script>alert(1)</script>"}},
   {"id": "repo:billing", "kind": "repo", "name": "billing", "meta": {}},
   {"id": "host:api.acme.com", "kind": "host", "name": "api.acme.com", "meta": {}},
   {"id": "service:postgres", "kind": "service", "name": "postgres", "meta": {}}],
 "edges": [
   {"from": "repo:web", "to": "repo:billing", "kind": "references",
    "evidence": "package.json:14", "confidence": "extracted"},
   {"from": "repo:web", "to": "host:api.acme.com", "kind": "deploys-to",
    "evidence": "vercel.json", "confidence": "extracted"},
   {"from": "repo:billing", "to": "repo:web", "kind": "shares-config",
    "evidence": "API_BASE_URL"},
   {"from": "repo:billing", "to": "service:postgres", "kind": "depends-on",
    "evidence": "docker-compose.yml", "confidence": "extracted"}]}
JSON

html_render
page="$DIR/map/graph.html"

fail=0
check() {
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else
    echo "FAIL $1: expected '$3', got '$2'" >&2; fail=1
  fi
}

[[ -f $page ]] || { echo "FAIL nothing rendered" >&2; exit 1; }

# Nothing fetched. A CDN would break the page inside a private repo, on a
# plane, and in every environment that blocks outbound traffic.
remote=$(grep -ciE '(src|href)="(https?:)?//|@import|url\((https?:)?//' "$page" || true)
check "no resource is loaded from anywhere" "$remote" "0"

# The data block must still be JSON after the escaping that keeps `</script>`
# from ending it early.
data=$(sed -n '/<script id="data"/,/<\/script>/p' "$page" | sed '1d;$d')
echo "$data" | jq -e . >/dev/null 2>&1 &&
  echo "ok   the data block parses as JSON" ||
  { echo "FAIL the data block is not JSON" >&2; fail=1; }

check "every node survives" "$(jq '.nodes | length' <<<"$data")" "4"
check "every edge survives" "$(jq '.edges | length' <<<"$data")" "4"

check "a hostile description cannot close the tag" \
  "$(grep -c '</script><script>alert' "$page" || true)" "0"
check "and is still there in the data" \
  "$(jq -r '[.nodes[] | select(.name == "web") | .description] | first | test("alert")' <<<"$data")" "true"

# The point of the whole exercise: an edge nobody declared must not arrive
# looking like one somebody did.
check "an untagged shares-config edge reads as inferred" \
  "$(jq -r '[.edges[] | select(.kind == "shares-config") | .confidence] | first' <<<"$data")" "inferred"
check "a tagged edge keeps its tag" \
  "$(jq -r '[.edges[] | select(.kind == "references") | .confidence] | first' <<<"$data")" "extracted"
check "every edge carries one" \
  "$(jq '[.edges[] | select(.confidence == null)] | length' <<<"$data")" "0"

check "the company name is escaped into the page" \
  "$(grep -c 'Ac&lt;me&gt; &amp; Co' "$page")" "2"

exit "$fail"
