# shellcheck shell=bash
# The weekly run, on whatever scheduler this machine has: systemd on Linux,
# launchd on macOS, a cron line to paste anywhere else.

schedule_kind() {
  if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
    echo systemd
  elif command -v launchctl >/dev/null && [[ $(uname -s) == Darwin ]]; then
    echo launchd
  else
    echo cron
  fi
}

schedule_plist() {
  local company=$1 label=$2 bin=$3
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$bin</string>
    <string>weekly</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ORGAMI_COMPANY</key><string>$company</string>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>5</integer>
    <key>Hour</key><integer>17</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/orgami-$company.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/orgami-$company.log</string>
</dict>
</plist>
PLIST
}

cmd_schedule() {
  load_company
  local off=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --off | --disable) off=1; shift ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  local kind bin
  kind=$(schedule_kind)
  bin=$(command -v orgami 2>/dev/null || echo "$ORGAMI_BIN")

  case $kind in
    systemd)
      local unit="orgami-weekly@$COMPANY.timer"
      local dir="$HOME/.config/systemd/user"
      mkdir -p "$dir"
      cp -f "$ROOT/systemd/orgami-weekly@.service" "$ROOT/systemd/orgami-weekly@.timer" "$dir/"
      systemctl --user daemon-reload 2>/dev/null || true
      if [[ $off == 1 ]]; then
        systemctl --user disable --now "$unit" 2>/dev/null || true
        echo "$unit disabled"
      else
        systemctl --user enable --now "$unit" &&
          echo "$unit — next run $(systemctl --user list-timers "$unit" --no-pager --no-legend 2>/dev/null | awk '{print $1, $2, $3}')"
      fi
      ;;

    launchd)
      local label="dev.orgami.weekly.$COMPANY"
      local plist="$HOME/Library/LaunchAgents/$label.plist"
      if [[ $off == 1 ]]; then
        launchctl bootout "gui/$UID/$label" 2>/dev/null ||
          launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        echo "$label removed"
        return
      fi
      mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
      schedule_plist "$COMPANY" "$label" "$bin" >"$plist"
      launchctl bootout "gui/$UID/$label" 2>/dev/null || true
      launchctl bootstrap "gui/$UID" "$plist" 2>/dev/null ||
        launchctl load -w "$plist" 2>/dev/null ||
        die "could not load $plist — load it by hand with: launchctl load -w $plist"
      echo "$plist — Fridays at 17:00, logging to ~/Library/Logs/orgami-$COMPANY.log"
      ;;

    cron)
      cat <<EOF
No systemd or launchd here. Add this line to your crontab (\`crontab -e\`):

  0 17 * * 5 ORGAMI_COMPANY=$COMPANY $bin weekly >/dev/null 2>&1

On Windows, run orgami inside WSL and use the WSL crontab, or point Task
Scheduler at: wsl.exe -e $bin weekly
EOF
      ;;
  esac
}
