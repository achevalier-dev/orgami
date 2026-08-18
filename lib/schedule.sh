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

# The daily timer's hour lives in the company config, so the unit is rendered
# rather than copied. Weekly stays a plain copy: it has no knob.
schedule_daily_unit() {
  local dir=$1 at=$2 hour=${2%%:*} minute=${2##*:}
  cat >"$dir/orgami-daily@.service" <<UNIT
[Unit]
Description=orgami daily digest for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=ORGAMI_COMPANY=%i
ExecStart=%h/.local/bin/orgami daily --yesterday
TimeoutStartSec=15min
UNIT
  cat >"$dir/orgami-daily@.timer" <<UNIT
[Unit]
Description=Daily orgami digest for %i at $at

[Timer]
OnCalendar=Mon..Fri $hour:$minute
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
UNIT
}

schedule_plist() {
  local company=$1 label=$2 bin=$3 kind=${4:-weekly} at=${5:-08:00}
  local args when hour=${at%%:*} minute=${at##*:}
  if [[ $kind == daily ]]; then
    args='    <string>daily</string>
    <string>--yesterday</string>'
    # Monday to Friday, 08:00. launchd takes one dict per day.
    local d
    when='  <array>'
    for d in 1 2 3 4 5; do
      when+="
    <dict><key>Weekday</key><integer>$d</integer><key>Hour</key><integer>$((10#$hour))</integer><key>Minute</key><integer>$((10#$minute))</integer></dict>"
    done
    when+='
  </array>'
  else
    args='    <string>weekly</string>'
    when='  <dict>
    <key>Weekday</key><integer>5</integer>
    <key>Hour</key><integer>17</integer>
    <key>Minute</key><integer>0</integer>
  </dict>'
  fi
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$bin</string>
$args
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ORGAMI_COMPANY</key><string>$company</string>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StartCalendarInterval</key>
$when
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/orgami-$company.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/orgami-$company.log</string>
</dict>
</plist>
PLIST
}

cmd_schedule() {
  load_company
  local off=0 kind=weekly want_at=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --off | --disable) off=1; shift ;;
      --daily) kind=daily; shift ;;
      --weekly) kind=weekly; shift ;;
      --at) want_at=$2; kind=daily; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [[ -z $want_at || $want_at =~ ^[0-2][0-9]:[0-5][0-9]$ ]] ||
    die "--at wants HH:MM, got '$want_at'"

  local at
  at=${want_at:-$(cfg daily_at "08:00")}
  [[ $at =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || at="08:00"

  # Turning the digest on or off is a property of the company, not of this
  # machine — a second laptop reading the same config should agree.
  if [[ $kind == daily ]]; then
    local want=true
    [[ $off == 1 ]] && want=false
    local tmp
    tmp=$(mktemp)
    jq --argjson d "$want" --arg at "$at" '.daily = $d | .daily_at = $at' \
      "$DIR/config.json" >"$tmp" && mv "$tmp" "$DIR/config.json"
  fi

  local platform bin
  platform=$(schedule_kind)
  bin=$(command -v orgami 2>/dev/null || echo "$ORGAMI_BIN")

  case $platform in
    systemd)
      local unit="orgami-$kind@$COMPANY.timer"
      local dir="$HOME/.config/systemd/user"
      mkdir -p "$dir"
      if [[ $kind == daily ]]; then
        schedule_daily_unit "$dir" "$at"
      else
        cp -f "$ROOT/systemd/orgami-weekly@.service" "$ROOT/systemd/orgami-weekly@.timer" "$dir/"
      fi
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
      local label="dev.orgami.$kind.$COMPANY"
      local plist="$HOME/Library/LaunchAgents/$label.plist"
      if [[ $off == 1 ]]; then
        launchctl bootout "gui/$UID/$label" 2>/dev/null ||
          launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        echo "$label removed"
        return
      fi
      mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
      schedule_plist "$COMPANY" "$label" "$bin" "$kind" "$at" >"$plist"
      launchctl bootout "gui/$UID/$label" 2>/dev/null || true
      launchctl bootstrap "gui/$UID" "$plist" 2>/dev/null ||
        launchctl load -w "$plist" 2>/dev/null ||
        die "could not load $plist — load it by hand with: launchctl load -w $plist"
      if [[ $kind == daily ]]; then
        echo "$plist — weekdays at $at, logging to ~/Library/Logs/orgami-$COMPANY.log"
      else
        echo "$plist — Fridays at 17:00, logging to ~/Library/Logs/orgami-$COMPANY.log"
      fi
      ;;

    cron)
      local line="0 17 * * 5 ORGAMI_COMPANY=$COMPANY $bin weekly"
      [[ $kind == daily ]] &&
        line="$((10#${at##*:})) $((10#${at%%:*})) * * 1-5 ORGAMI_COMPANY=$COMPANY $bin daily --yesterday"
      cat <<EOF
No systemd or launchd here. Add this line to your crontab (\`crontab -e\`):

  $line >/dev/null 2>&1

On Windows, run orgami inside WSL and use the WSL crontab, or point Task
Scheduler at: wsl.exe -e $bin weekly
EOF
      ;;
  esac
}
