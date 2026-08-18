# Layout

```
bin/orgami             dispatcher
lib/common.sh          paths, config, company selection
lib/init.sh            init / use / list
lib/pull.sh            GraphQL fetch of merged PRs
lib/prs.graphql        the query
lib/stats.jq           every number in the report
lib/report.sh          stats + Claude -> reports/
lib/daily.jq           every number in the daily digest
lib/daily.sh           one day: merged, opened, waiting, commits
lib/scan.sh            repo scan -> map/graph.json
lib/doc.sh             graph.json -> ARCHITECTURE.md
lib/view.sh            orgami query, and the legacy show/open entry points
lib/tui.sh             the browser: tabs, rows, previews, key bindings
lib/style.sh           one palette for everything orgami prints
lib/profile.sh         what a repo is: framework, commands, env, routes
lib/card.sh            repo pages and `orgami context`
lib/coupling.sh        which repos change together
lib/runbook.sh         how a repo runs, ships and breaks
lib/notes.sh           the shared note memory
lib/autonote.sh        notes drafted from a session that has ended
lib/schedule.sh        the weekly and daily timers, per platform
lib/mcp.py             the MCP server, standard library only
lib/agents.sh          AGENTS.md and Cursor rules, MCP config snippets
lib/ui.sh              the menu and the setup wizard
lib/publish.sh         commit to the docs repo, weekly runner
prompts/recap.md       the recap prompt
prompts/decisions.md   the decision-mining prompt
prompts/daily.md       the daily digest prompt
hooks/                 the SessionStart hook
commands/              /orgami:context and /orgami:note
.claude-plugin/        plugin and marketplace manifests
skills/orgami/         the Claude Code skill
script/check           everything CI runs, runnable locally
test/fixtures/         a fake week and a fake day, for testing with no org
bootstrap.sh           the one-command install for macOS, Linux and WSL
bootstrap.ps1          the same for Windows
systemd/               orgami-weekly@.service and .timer
                       the daily units are rendered, not copied: the hour
                       is a company setting
```

Company state, never in this repo:

```
~/.orgami/
  config.json          default company, and an optional "orgs" picker filter
~/.orgami/<company>/
  config.json          org, docs repo, include/exclude, model
  cache/prs/           raw GraphQL responses, one file per week
  cache/daily/         one file per day: merged, opened, open, commits
  cache/repos/         the org's repo list
  cache/src/           shallow clones
  cache/docs/          the docs repo checkout
  reports/             one markdown recap per week
  reports/daily/       one digest per day, quiet days skipped
  notes/               one file per note, plus notes/archive/
  map/graph.json       nodes and edges
  map/repos.json       one profile per repo
  map/coupling.json    which repos change together
  map/ARCHITECTURE.md  rendered from the graph
  map/CONVENTIONS.md   the org's own agent instructions, gathered
  map/DECISIONS.md     decisions mined from pull requests, one section per week
  map/RUNBOOK.md       the operational half, org-wide
  map/runbooks/        one runbook per repo
  map/repos/<repo>.md  a page per repo
  map/decisions/       one fragment per week, assembled into DECISIONS.md
```
