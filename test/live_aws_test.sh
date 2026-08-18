#!/usr/bin/env bash
# The AWS reader must enumerate what is running rather than trusting the tagging
# API — on a real account most resources carry no tags at all — and must still
# attribute only what a tag, a mapped host or a whole repo name accounts for.
# Runs against a stub `aws`, so no credentials and no network.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/live.sh
source lib/live.sh

fixture=$(mktemp -d)
LIVE_ROWS=$(mktemp)
LIVE_ERRORS=$(mktemp)
trap 'rm -rf "$fixture" "$LIVE_ROWS" "$LIVE_ERRORS"' EXIT

DIR="$fixture"
mkdir -p "$DIR/map" "$DIR/bin"
echo '{"aws_region": "us-east-1"}' >"$DIR/config.json"

cat >"$DIR/map/repos.json" <<'JSON'
[{"name": "WinIt-backend"}, {"name": "reports"}, {"name": "ticket-api"}]
JSON

cat >"$DIR/map/graph.json" <<'JSON'
{"nodes": [{"id": "repo:ticket-api", "kind": "repo", "name": "ticket-api"}],
 "edges": [{"from": "repo:ticket-api", "to": "host:ticket-api-prod.us-east-1.elasticbeanstalk.com",
            "kind": "deploys-to", "evidence": ".github/workflows/deploy.yml:20"}]}
JSON

# A stub account: one tagged lambda, one lambda named after a repo in a
# different case, two that name nothing, an ECS service, and a Beanstalk
# environment whose hostname the map already points at. The tagging API returns
# only the tagged one — which is the whole point of not relying on it.
cat >"$DIR/bin/aws" <<'STUB'
#!/usr/bin/env bash
svc=$1; op=$2
case "$svc $op" in
  "sts get-caller-identity") echo '{"Account": "111122223333"}' ;;
  "resourcegroupstaggingapi get-resources")
    cat <<'JSON'
{"ResourceTagMappingList": [
  {"ResourceARN": "arn:aws:lambda:us-east-1:111122223333:function:nightly-reports",
   "Tags": [{"Key": "Repository", "Value": "reports"}, {"Key": "env", "Value": "prod"}]}]}
JSON
    ;;
  "lambda list-functions")
    cat <<'JSON'
{"Functions": [
  {"FunctionName": "nightly-reports", "LastModified": "2026-08-01T10:00:00Z",
   "FunctionArn": "arn:aws:lambda:us-east-1:111122223333:function:nightly-reports"},
  {"FunctionName": "winit-backend", "LastModified": "2026-08-02T10:00:00Z",
   "FunctionArn": "arn:aws:lambda:us-east-1:111122223333:function:winit-backend"},
  {"FunctionName": "scraphome-api", "LastModified": "2026-08-03T10:00:00Z",
   "FunctionArn": "arn:aws:lambda:us-east-1:111122223333:function:scraphome-api"},
  {"FunctionName": "testalevy", "LastModified": "2026-08-04T10:00:00Z",
   "FunctionArn": "arn:aws:lambda:us-east-1:111122223333:function:testalevy"}]}
JSON
    ;;
  "ecs list-clusters") echo '{"clusterArns": ["arn:aws:ecs:us-east-1:111122223333:cluster/main"]}' ;;
  "ecs list-services") echo '{"serviceArns": ["arn:aws:ecs:us-east-1:111122223333:service/main/winit-preview-1"]}' ;;
  "ecs describe-services")
    cat <<'JSON'
{"services": [{"serviceName": "winit-preview-1", "status": "ACTIVE",
               "runningCount": 2, "desiredCount": 2,
               "serviceArn": "arn:aws:ecs:us-east-1:111122223333:service/main/winit-preview-1"}]}
JSON
    ;;
  "elasticbeanstalk describe-environments")
    cat <<'JSON'
{"Environments": [{"EnvironmentName": "ticket-api-prod", "Status": "Ready", "Health": "Green",
                   "EnvironmentArn": "arn:aws:elasticbeanstalk:us-east-1:111122223333:environment/x/ticket-api-prod",
                   "CNAME": "ticket-api-prod.us-east-1.elasticbeanstalk.com"}]}
JSON
    ;;
  *) echo "{}" ;;
esac
STUB
chmod +x "$DIR/bin/aws"
PATH="$DIR/bin:$PATH"

live_aws

rows=$(jq -s . "$LIVE_ROWS")
fail=0
assert() {
  local what=$1 want=$2 got
  got=$(jq -r "$3" <<<"$rows")
  [[ $got == "$want" ]] || { echo "FAIL: $what — expected '$want', got '$got'" >&2; fail=1; }
}

# Enumerated, not read off the tagging API: that API knows about one of these.
assert "every resource is enumerated" 6 'length'
assert "lambdas are read" 4 '[.[] | select(.source | startswith("aws:lambda"))] | length'
assert "ecs services are read" 1 '[.[] | select(.source | startswith("aws:ecs"))] | length'
assert "beanstalk environments are read" 1 \
  '[.[] | select(.source | startswith("aws:beanstalk"))] | length'

assert "a Repository tag attributes it" reports '.[] | select(.name == "nightly-reports") | .repo'
assert "and says the tag did it" tag '.[] | select(.name == "nightly-reports") | .match'
assert "a whole repo name in another case matches" WinIt-backend \
  '.[] | select(.name == "winit-backend") | .repo'
assert "and keeps the map's spelling" name '.[] | select(.name == "winit-backend") | .match'
assert "a mapped hostname attributes it" ticket-api \
  '.[] | select(.name == "ticket-api-prod") | .repo'
assert "and says the map did it" map '.[] | select(.name == "ticket-api-prod") | .match'
assert "the hostname is carried" ticket-api-prod.us-east-1.elasticbeanstalk.com \
  '.[] | select(.name == "ticket-api-prod") | .urls[0]'

# The two that name nothing must stay unattributed, however suggestive.
assert "a prefix is not a match" null '.[] | select(.name == "scraphome-api") | .repo'
assert "nor is a stray name" null '.[] | select(.name == "testalevy") | .repo'
assert "nor is a preview service" null '.[] | select(.name == "winit-preview-1") | .repo'
assert "ecs state carries running counts" "ACTIVE 2/2" \
  '.[] | select(.name == "winit-preview-1") | .state'

# Every row is the same fixed shape: no tag values, no environment, nothing a
# resource happened to carry beyond its name and where it answers.
assert "rows carry a fixed set of fields" \
  "account match name provider repo source state updated urls" \
  '[.[] | keys[]] | unique | join(" ")'

if [[ $fail -eq 0 ]]; then
  echo "live/aws: enumerated every resource, attributed only what a tag, host or whole name supports"
else
  exit 1
fi
