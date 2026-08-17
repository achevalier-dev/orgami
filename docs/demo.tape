# The README demo, recorded with vhs — https://github.com/charmbracelet/vhs
#
#   brew install vhs        # or: pacman -S vhs, go install github.com/charmbracelet/vhs@latest
#   vhs docs/demo.tape      # writes docs/demo.gif
#
# Before recording, map an organization you are willing to publish. A client's
# repository names, hosts and IP addresses end up in every frame of this GIF, so
# record against a public org or one of your own — never a client's:
#
#   export ORGAMI_HOME=/tmp/orgami-demo
#   orgami init demo --org <a-public-org>
#   orgami scan
#
# Then set DEMO_REPO below to a repo in that org and run vhs.

Output docs/demo.gif

Set Shell bash
Set FontSize 16
Set Width 1200
Set Height 750
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set PlaybackSpeed 1.0

Env ORGAMI_HOME "/tmp/orgami-demo"
Env DEMO_REPO "CHANGE-ME"
Env PS1 "\033[38;5;12m❯\033[0m "

Hide
Type "clear" Enter
Show

# What an agent reads before it touches a repository.
Type "orgami context $DEMO_REPO" Sleep 500ms Enter
Sleep 6s

Hide
Type "clear" Enter
Show

# One node, and every edge that named it — with the file:line it came from.
Type "orgami query $DEMO_REPO" Sleep 500ms Enter
Sleep 5s

Hide
Type "clear" Enter
Show

# The whole map, browsable.
Type "orgami view" Sleep 500ms Enter
Sleep 3s
Type "api"
Sleep 2500ms
Down Sleep 700ms
Down Sleep 1200ms
Ctrl+C
Sleep 1s

Hide
Type "clear" Enter
Show

# This week, counted by jq and written by Claude.
Type "orgami latest" Sleep 500ms Enter
Sleep 6s
