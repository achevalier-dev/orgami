#!/usr/bin/env bash
# `orgami live` must only tie a deployment to a repository when something says
# so: the map's own deploys-to edge, or a name that is exactly a repo name.
# Everything else has to stay unmatched. Runs against a stub flyctl, so no
# credentials and no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/live.sh
source lib/live.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

DIR="$fixture"
# shellcheck disable=SC2034  # ORG is read by the vercel reader, not by this test
ORG=acme
mkdir -p "$DIR/map" "$DIR/bin"

# Three repos. `api` deploys to a fly host the map already knows about under a
# different app name; `web` shares its name with a fly app; `docs` deploys
# nowhere.
cat >"$DIR/map/repos.json" <<'JSON'
[{"name": "api"}, {"name": "web"}, {"name": "docs"}]
JSON

cat >"$DIR/map/graph.json" <<'JSON'
{"nodes": [{"id": "repo:api", "kind": "repo", "name": "api"},
           {"id": "host:acme-api-prod.fly.dev", "kind": "host", "name": "acme-api-prod.fly.dev"}],
 "edges": [{"from": "repo:api", "to": "host:acme-api-prod.fly.dev",
            "kind": "deploys-to", "evidence": "fly.toml"}]}
JSON

# A stub flyctl: four apps, only two of which anything ties to a repo.
cat >"$DIR/bin/flyctl" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[{"Name": "acme-api-prod", "Status": "deployed", "Organization": {"Slug": "acme"}},
 {"Name": "web", "Status": "deployed", "Organization": {"Slug": "acme"}},
 {"Name": "some-old-thing", "Status": "suspended", "Organization": {"Slug": "acme"}},
 {"Name": "api-staging", "Status": "deployed", "Organization": {"Slug": "acme"}}]
JSON
STUB
chmod +x "$DIR/bin/flyctl"
PATH="$DIR/bin:$PATH"

LIVE_ROWS=$(mktemp)
LIVE_ERRORS=$(mktemp)
trap 'rm -rf "$fixture" "$LIVE_ROWS" "$LIVE_ERRORS"' EXIT

live_fly

rows=$(jq -s . "$LIVE_ROWS")
fail=0
assert() {
  local what=$1 want=$2 got
  got=$(jq -r "$3" <<<"$rows")
  [[ $got == "$want" ]] || { echo "FAIL: $what — expected '$want', got '$got'" >&2; fail=1; }
}

assert "four apps read" 4 'length'
assert "the map's deploys-to edge wins" api \
  '.[] | select(.name == "acme-api-prod") | .repo'
assert "and says where the match came from" map \
  '.[] | select(.name == "acme-api-prod") | .match'
assert "an exact repo name matches" web '.[] | select(.name == "web") | .repo'
assert "and says so" name '.[] | select(.name == "web") | .match'
assert "an app nothing points at stays unmatched" null \
  '.[] | select(.name == "some-old-thing") | .repo'
assert "a near-miss name is not guessed at" null \
  '.[] | select(.name == "api-staging") | .repo'
assert "the hostname is derived, not invented" acme-api-prod.fly.dev \
  '.[] | select(.name == "acme-api-prod") | .urls[0]'
assert "no environment values are carried" 0 \
  '[.[] | keys[]] | unique | map(select(. == "env" or . == "secrets")) | length'

# Freshness: the reading has to date itself, and go quiet once it is too old.
cat >"$DIR/map/live.json" <<JSON
{"generated": "$(live_now)", "generated_epoch": $(($(date -u +%s) - 3 * 86400)),
 "providers": ["fly"], "deployments": [{"provider": "fly", "name": "web", "repo": "web",
 "match": "name", "state": "deployed", "urls": ["web.fly.dev"], "account": "acme"}],
 "unmatched": [], "errors": []}
JSON
[[ $(live_age_days) == 3 ]] || { echo "FAIL: age should be 3 days, got $(live_age_days)" >&2; fail=1; }

# Captured first, not piped: `grep -q` exits on the first match and would leave
# the writer with a broken pipe, which pipefail then reports as a failure.
fresh_brief=$(live_brief web)
fresh_page=$(live_section web)
grep -q 'deployed (read 3 days ago)' <<<"$fresh_brief" ||
  { echo "FAIL: a fresh reading should reach the session brief" >&2; fail=1; }
grep -q 'Running now' <<<"$fresh_page" ||
  { echo "FAIL: a fresh reading should reach the repo page" >&2; fail=1; }

jq --argjson e "$(($(date -u +%s) - 30 * 86400))" '.generated_epoch = $e' \
  "$DIR/map/live.json" >"$DIR/map/live.tmp" && mv "$DIR/map/live.tmp" "$DIR/map/live.json"
[[ -z $(live_brief web) ]] ||
  { echo "FAIL: a month-old reading must not be injected as fact" >&2; fail=1; }
stale_page=$(live_section web)
grep -q 'rumour' <<<"$stale_page" ||
  { echo "FAIL: a month-old reading must be labelled on the repo page" >&2; fail=1; }

# A run where nothing could be read must not replace a good reading with a blank
# one: a missing token is not the same fact as an empty organization.
home=$(mktemp -d)
mkdir -p "$home/acme/map"
echo '{"default": "acme"}' >"$home/config.json"
echo '{"org": "acme"}' >"$home/acme/config.json"
cp "$DIR/map/repos.json" "$DIR/map/graph.json" "$home/acme/map/"
cp "$DIR/map/live.json" "$home/acme/map/live.json"
before=$(cat "$home/acme/map/live.json")

if ORGAMI_HOME="$home" ORGAMI_COMPANY=acme ./bin/orgami live --provider bogus 2>/dev/null; then
  echo "FAIL: a run with no readable provider should not report success" >&2
  fail=1
fi
[[ $(cat "$home/acme/map/live.json") == "$before" ]] ||
  { echo "FAIL: a failed run overwrote the previous reading" >&2; fail=1; }
rm -rf "$home"

if [[ $fail -eq 0 ]]; then
  echo "live: matched only what the map or an exact name supports, dated it, and kept it on failure"
else
  exit 1
fi
