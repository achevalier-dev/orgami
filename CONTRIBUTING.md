# Contributing to orgami

orgami is Bash. There is no build step and nothing to compile — clone it, run it,
edit it.

The most valuable reports are not crashes. They are **organizations orgami got
wrong**: an edge it drew that is not real, a service it missed, a framework it
did not recognize, a deploy target it could not see. The scan is pattern
matching over committed files, so every organization it has never met is a gap
in it. Those reports need no fix attached to be useful — the
[wrong map](https://github.com/achevalier-dev/orgami/issues/new?template=wrong-map.yml)
template asks for the file it should have matched.

## Getting set up

```bash
git clone https://github.com/achevalier-dev/orgami
cd orgami
./bin/orgami --help          # runs straight out of the checkout, nothing to install
```

You need `bash`, `git`, `jq` and `gh`; `fzf` and `gum` for the interactive parts,
`python3` for the MCP server. `shellcheck` if you want to run the linter locally.

Never install over your real config while developing. Point `ORGAMI_HOME`
somewhere disposable:

```bash
export ORGAMI_HOME=/tmp/orgami-dev
```

## Testing without an organization

The deterministic half of orgami needs no GitHub token, no organization and no
model at all:

```bash
./script/check         # bash -n, shellcheck, and the stats program on a fixture week
```

That is exactly what CI runs. `test/fixtures/week.json` is a fake week of merged
pull requests — the same shape `orgami pull` caches — so anything that reads pull
requests can be exercised against it:

```bash
jq -f lib/stats.jq test/fixtures/week.json          # every number in the report
```

If your change touches `lib/stats.jq`, add a case to the fixture and an assertion
to `script/check`.

## Testing the parts that need an org

Point orgami at any organization your `gh` token can see — your own account's
org, or a public one — with a disposable home and no docs repo, so nothing is
ever pushed:

```bash
ORGAMI_HOME=/tmp/orgami-dev ./bin/orgami init sandbox --org <some-org>
ORGAMI_HOME=/tmp/orgami-dev ./bin/orgami scan --jobs 4
ORGAMI_HOME=/tmp/orgami-dev ./bin/orgami view
```

To exercise a single repository's profile without a full scan:

```bash
ORGAMI_HOME=/tmp/orgami-dev ./bin/orgami scan --only <repo>
```

For interactive or destructive paths, stub the tool instead of running it: put a
fake `gum` or `gh` earlier on `PATH`, pop scripted answers off a queue file, and
assert on the JSON that got written. That is how the setup wizard and the
repo-creation branch are covered without creating a repository.

**Never test by running a command that pushes.** `publish` and `sync` write to
someone's repository; `--dry-run` is there for a reason.

## The shape of a good change

[AGENTS.md](AGENTS.md) is the full house style — it is written for coding agents,
and it is the same set of rules a human should follow. The load-bearing ones:

- **Every edge carries its evidence.** Nothing enters the graph without the
  `file:line`, URL or pull request it came from. If a new inference cannot cite
  itself, it is not ready to ship.
- **Numbers come from `jq`, prose comes from the model.** Never ask a model to
  count.
- **Data on stdout, progress on stderr.** Anything that captures a command's
  output must get only its result.
- **Fail with `die`**, and say what to do next, not just what went wrong.
- **No new dependencies.** If a change needs one, it probably needs a different
  design.
- **Interactive is a layer, never a requirement.** Everything the menu does must
  be reachable through flags, because the weekly timer runs with no terminal.
- **Say what the tool cannot know.** A missing edge means "not found in committed
  configuration", never "not connected".

## Before you open a pull request

```bash
./script/check
```

`shellcheck --severity=warning` must be clean. A sourced library needs
`# shellcheck shell=bash` on line 1; a genuine false positive gets a
`# shellcheck disable=SCxxxx` with the reason on the same line.

Commits are [conventional](https://www.conventionalcommits.org), present tense,
small and atomic. The subject says what changed; the body says why it was worth
changing. No emoji, no co-author trailer.

A pull request should say what an organization looked like before and after, when
that is what changed. A diff of `map/graph.json` from a real scan is the most
convincing thing you can attach.

## Adding a subcommand

A `cmd_<name>` function in the `lib/` file that owns its area, plus a case arm in
`bin/orgami`, plus a line in `usage()`. Nothing else — flag parsing lives in the
subcommand, never in the dispatcher.

## Reporting a security issue

Notes and reports are screened for credentials before they are written or pushed.
If you find a way past that screening, or any other way orgami leaks one client's
information into another's, do not open a public issue — email
ad@antoinedv.com instead.
