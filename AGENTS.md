# orgami development context

## Stack

Bash, `jq`, `gh`, `git`, `fzf`, `gum`, and one Claude call where prose is
genuinely needed. No daemon, no database, no build step, no runtime that has to
be installed. If a change needs a new dependency, it probably needs a different
design.

## Structure

```
bin/orgami         dispatcher — flag parsing lives in the subcommands, not here
lib/common.sh      paths, config, company selection, die/log/linkify
lib/<topic>.sh     one file per area, exporting cmd_<name> functions
lib/*.jq           jq programs long enough to deserve their own file
prompts/*.md       every prompt sent to a model, versioned like code
skills/orgami/     the Claude Code skill
systemd/           the weekly timer
```

A new subcommand is a `cmd_<name>` function in the `lib/` file that owns its
area, plus a case arm in `bin/orgami`. Nothing else.

## Run & test

```bash
bash -n bin/orgami lib/*.sh          # syntax, after every edit
ORGAMI_HOME=/tmp/scratch/orgami-test ./bin/orgami scan --jobs 4
```

There is no test suite. Test against a real organization with `ORGAMI_HOME`
pointed somewhere disposable, and against stubs when the path is interactive or
destructive: put a fake `gum` and `gh` earlier on `PATH`, pop scripted answers
off a queue file, then assert on the JSON that got written. That is how the
setup wizard and the repo-creation branch are covered without creating a repo.

Never test by running a command that pushes.

## Conventions

### Data on stdout, progress on stderr

Every command's stdout is its result and nothing else, so `$(...)` and pipes
stay clean. Progress, warnings and spinners go to stderr through `log`.

**Preferred:**
```bash
log "listing repos in $ORG"
echo "$out  ($(jq '.nodes | length' "$out") nodes)"
```

**Avoid:**
```bash
echo "listing repos in $ORG"     # pollutes anything that captures this
```

### Fail with `die`, never with a bare exit

`die` prints `orgami: <message>` to stderr and exits 1. The message says what to
do next, not just what went wrong.

**Preferred:**
```bash
[[ -f $g ]] || die "no map yet — run: orgami scan"
```

**Avoid:**
```bash
[[ -f $g ]] || { echo "missing graph"; exit 1; }
```

### jq owns JSON

Never `grep`, `sed` or `cut` a JSON file. Read it, transform it and write it
with `jq`. Anything longer than a screen goes in its own `.jq` file.

### Write to a temp file, then move

Config and generated artefacts are replaced atomically, so an interrupted run
never leaves a half-written file that the next run parses.

**Preferred:**
```bash
tmp=$(mktemp)
jq '.default = $c' "$config" >"$tmp"
mv "$tmp" "$config"
```

**Avoid:**
```bash
jq '.default = $c' "$config" >"$config"   # truncates before it reads
```

### One repo's failure never aborts the run

A scan across forty repositories will hit a broken clone, a missing branch, a
repository the token cannot read. Collect the failure, keep going, report the
list at the end.

### Every edge carries its evidence

Nothing enters the graph without the `file:line`, URL or pull request it came
from. A claim a user cannot open and check does not belong in the output. This
is the rule the whole tool rests on — if a new inference cannot cite itself,
it is not ready to ship.

### Numbers come from jq, prose comes from the model

`lib/stats.jq` computes every figure in the weekly report. The model is handed
those figures and told to write around them, never to count. A model asked to
both count and narrate does neither reliably.

The same split applies everywhere: derive what can be derived, and spend the
model only on the part that genuinely needs language.

### Links are generated, never written by the model

The model writes `org/repo#123`; `linkify_prs` turns it into a URL afterwards.
That way a link cannot be invented — the reference has to exist first.

### Generated sections disappear when empty

A heading with "none this week" underneath is noise in every future diff. Omit
the section entirely.

### Say what the tool cannot know

Generated prose states its limits in the place a reader would otherwise assume
completeness: a missing edge means "not found in committed configuration", never
"not connected"; `changes-with` is correlation, not dependency; a stale
`generated` date gets said out loud.

### Voice of generated output

Plain and dry. No praise, no filler, no "great work this week". Prefer the
concrete noun to the category, the short word to the long one. Never pad to look
thorough.

### Comments explain why

The code says what it does. A comment earns its place by explaining a decision
that is not visible — why the `.github` repo is skipped, why a barrier exists,
why a threshold is three and not ten.

**Preferred:**
```bash
# The docs repo holds orgami's own output; scanning it links every repo to it.
```

**Avoid:**
```bash
# Loop over the repos
```

### Interactive is a layer, never a requirement

Everything the wizard and the menu do is reachable through flags, because the
systemd timer and any script run without a terminal. New interactive work goes
in `lib/ui.sh` on top of a subcommand that already works headless.

### Never push without being asked

`publish` and `sync` write to someone's repository. They confirm unless given
`--yes`, and nothing else in the tool pushes at all.

## Commits

Conventional commits, present tense, small and atomic. The subject says what
changed; the body says why it was worth changing. No emoji, no co-author trailer.
