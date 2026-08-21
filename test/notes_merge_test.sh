#!/usr/bin/env bash
# A note that is written, screened, reviewed and then left sitting in an unmerged
# pull request is the same as a note nobody wrote. The two refusals a docs repo
# actually produces — a protected base branch, and a base that moved between the
# read and the merge — are ordinary, and each has its own answer. Anything else
# has to be reported rather than swallowed.
#
# Runs against a stub `gh` and a stub `git`. No network, no repository, no push.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck disable=SC2034  # ROOT is read by the library, not by this test
ROOT=$PWD
# shellcheck source=../lib/common.sh
source lib/common.sh
# shellcheck source=../lib/notes.sh
source lib/notes.sh

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

DIR="$fixture"
mkdir -p "$DIR" "$fixture/bin" "$fixture/work"
echo '{"docs_repo": "git@github.com:acme/orgami-reports.git"}' >"$DIR/config.json"

# The stub answers from $SCENARIO and records every call it was given.
cat >"$fixture/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
case $SCENARIO in
  clean) exit 0 ;;
  protected)
    if [[ $* == *--auto* ]]; then exit 0; fi
    echo "Pull request acme/orgami-reports#7 is not mergeable: the base branch policy prohibits the merge." >&2
    exit 1
    ;;
  moved)
    # Fails once with a moved base, then succeeds against the branch as it is.
    n=$(wc -l <"$GH_LOG")
    if [[ $n -le 1 ]]; then
      echo "GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)" >&2
      exit 1
    fi
    exit 0
    ;;
  unmergeable)
    if [[ $* == *--auto* ]]; then
      echo "Auto-merge is not allowed for this repository" >&2
      exit 1
    fi
    echo "Pull request acme/orgami-reports#7 is not mergeable: the base branch policy prohibits the merge." >&2
    exit 1
    ;;
  broken)
    echo "could not resolve host: github.com" >&2
    exit 1
    ;;
esac
STUB
cat >"$fixture/bin/git" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$fixture/bin/gh" "$fixture/bin/git"
PATH="$fixture/bin:$PATH"

fail() { echo "notes_pr_merge: $*" >&2; exit 1; }

run() { # run <scenario> — prints stdout, sets RC and GH_LOG contents
  SCENARIO=$1
  export SCENARIO
  GH_LOG="$fixture/calls.log"
  export GH_LOG
  : >"$GH_LOG"
  RC=0
  OUT=$(notes_pr_merge "$fixture/work" 7 "$2" 2>"$fixture/err") || RC=$?
  ERR=$(cat "$fixture/err")
  CALLS=$(cat "$GH_LOG")
}

# --- a repository with nothing to say about it -------------------------------

run clean "— teammates get it on their next sync"
[[ $RC == 0 ]] || fail "a clean merge should succeed, got $RC"
grep -q '^merged #7 — teammates' <<<"$OUT" || fail "a clean merge should say so, got '$OUT'"
[[ $(grep -c . <<<"$CALLS") == 1 ]] ||
  fail "a clean merge should take one call, took $(grep -c . <<<"$CALLS")"
grep -q -- '--auto' <<<"$CALLS" && fail "a clean merge must not queue an auto-merge"

# --- the branch policy the docs repo actually had ----------------------------

run protected ""
[[ $RC == 0 ]] || fail "a protected branch is not a failure of the note, got $RC"
grep -q -- '--auto' <<<"$CALLS" || fail "a protected branch should be queued with --auto"
grep -q 'will merge once' <<<"$OUT" ||
  fail "a queued merge must not be reported as merged, got '$OUT'"

# --- the other refusal in the log --------------------------------------------

run moved ""
[[ $RC == 0 ]] || fail "a moved base should be retried and succeed, got $RC"
grep -q '^merged #7' <<<"$OUT" || fail "the retry should report a merge, got '$OUT'"
grep -q -- '--auto' <<<"$CALLS" && fail "a moved base is a retry, not an auto-merge"

# --- refused every way --------------------------------------------------------

run unmergeable ""
[[ $RC == 1 ]] || fail "a merge nobody can do must report failure, got $RC"
grep -q 'gh pr merge 7' <<<"$ERR" || fail "the user needs the command to run themselves, got '$ERR'"
grep -q 'acme/orgami-reports' <<<"$ERR" || fail "the failure should name the docs repo, got '$ERR'"
[[ -z $OUT ]] || fail "nothing was merged, so stdout must stay empty, got '$OUT'"

# --- anything else -------------------------------------------------------------

run broken ""
[[ $RC == 1 ]] || fail "an unrecognised failure must not be swallowed, got $RC"
grep -q 'could not merge #7' <<<"$ERR" || fail "the reason should be quoted, got '$ERR'"
grep -q -- '--auto' <<<"$CALLS" && fail "an unrecognised failure must not be queued blindly"

echo "notes: a protected branch queues, a moved base retries, anything else reports"
