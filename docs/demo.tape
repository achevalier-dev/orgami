# The README demo, recorded with vhs — https://github.com/charmbracelet/vhs
#
#   vhs docs/demo.tape        # writes docs/demo.gif, run from the repo root
#
# It records against a mapped copy of a public organization, so nothing in the
# GIF belongs to a client. Reproduce that first — it takes about a minute:
#
#   export ORGAMI_HOME=/tmp/orgami-demo
#   orgami init demo --org honojs
#   orgami scan --jobs 8 && orgami doc && orgami pull --last 1
#   orgami note --repo hono "a line for the Notes tab to show"
#
# Never record against a client's organization. Repository names, hostnames and
# IP addresses end up in every frame, and orgami's note screening does not cover
# a GIF. The --week below is the week that was current when this was recorded;
# `orgami pull --last 1` and the matching week is the pair to change.

Output docs/demo.gif

Set Shell bash
Set FontSize 14
Set Width 1200
Set Height 720
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms
Set WindowBar Colorful
Set BorderRadius 8

Env ORGAMI_HOME "/tmp/orgami-demo"

Hide
Type "unset PROMPT_COMMAND; PS1='❯ '; clear" Enter
Show

Sleep 600ms

# What a coding agent is handed at session start, before you type anything.
Type "orgami brief honox" Sleep 500ms Enter
Sleep 4500ms

Type "clear" Enter
Sleep 400ms

# One node, and both directions of every edge — each with the file:line it was
# read out of, so nothing here is a model's guess.
Type "orgami query hono" Sleep 500ms Enter
Sleep 5500ms

Type "clear" Enter
Sleep 400ms

# The map, the repos, the team's notes and the recaps — one screen, four tabs.
Type "orgami view" Sleep 500ms Enter
Sleep 3s
Type "mid"
Sleep 2s
Backspace 3
Sleep 500ms
Tab
Sleep 3s
Down Sleep 700ms
Down Sleep 1500ms
Tab
Sleep 3s
Down Sleep 1800ms
Escape
Sleep 700ms

Type "clear" Enter
Sleep 400ms

# Every number in the weekly recap is computed by jq, never by a model.
Set TypingSpeed 25ms
Type "orgami report --stats-only --week 2026-W33 |" Enter
Type "  jq '{merged, repos_touched, median_hours_to_merge, merged_without_review}'" Sleep 500ms Enter
Sleep 4500ms
