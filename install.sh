#!/usr/bin/env bash
# install.sh — install mf-sync on a machine and (optionally) start syncing a memoryfield
#              into a shared db9 database.
#
# usage:
#   ./install.sh                       # install binary symlink + systemd timer (5 min)
#   ./install.sh --db memoryfield --field ~/.memoryfields/work --interval 5
#   ./install.sh --no-timer            # only install mf-sync
#   ./install.sh --hooks               # also patch the local-memoryfield skill hooks (mnew/mdream)
#   ./install.sh --skill               # also install/refresh the memoryfield skill (SKILL.md + mnew/msearch/mdream)
#   ./install.sh --launchd             # force a macOS LaunchAgent (default on macOS)
#   ./install.sh --cron                # crontab line instead of timer/LaunchAgent
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${MEMORYFIELD_DB9:-memoryfield}"
FIELD="${MEMORYFIELD:-$HOME/.memoryfields/work}"
INTERVAL=5
TIMER=1
HOOKS=0
SKILL=0
USE_CRON=0
USE_LAUNCHD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --db)       DB="$2"; shift 2 ;;
    --field)    FIELD="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --no-timer) TIMER=0; shift ;;
    --cron)     USE_CRON=1; shift ;;
    --launchd)  USE_LAUNCHD=1; shift ;;
    --hooks)    HOOKS=1; shift ;;
    --skill)    SKILL=1; shift ;;
    -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

FIELD="${FIELD/#\~/$HOME}"
fail=0
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; fail=1; }; }
need python3
need psql
need db9
[ $fail = 1 ] && exit 1

chmod +x "$HERE/mf-sync"
mkdir -p "$HOME/.local/bin"
ln -sf "$HERE/mf-sync" "$HOME/.local/bin/mf-sync"
echo "installed: ~/.local/bin/mf-sync -> $HERE/mf-sync"

mkdir -p "$HOME/.config/memoryfield-sync"
cat > "$HOME/.config/memoryfield-sync/env" <<EOF
MEMORYFIELD=$FIELD
MEMORYFIELD_DB9=$DB
MF_SYNC=$HERE/mf-sync
EOF
echo "config:    ~/.config/memoryfield-sync/env (MEMORYFIELD=$FIELD, db=$DB)"

if [ ! -d "$FIELD" ]; then
  mkdir -p "$FIELD" && echo "created field dir: $FIELD (first --sync will pull everything the hub has for field '$(basename "$FIELD")')"
fi

# --- connectivity check -------------------------------------------------------
if ! db9 status >/dev/null 2>&1; then
  echo "! not logged in to db9. run: db9 login   (must be the same account/project that"
  echo "  hosts the '$DB' database), then re-run: mf-sync --status"
else
  echo "db9: $(db9 status 2>/dev/null | head -1)"
  "$HERE/mf-sync" --db "$DB" --field "$FIELD" --status 2>&1 | head -6
fi

# --- periodic sync ------------------------------------------------------------
# macOS has no systemd user instance: use a LaunchAgent (StartInterval).
if [ $TIMER = 1 ] && { [ $USE_LAUNCHD = 1 ] || { [ "$(uname -s)" = Darwin ] && [ $USE_CRON = 0 ]; }; }; then
  LABEL="com.c4pt0r.memoryfield-sync"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  LOGDIR="$HOME/.local/state/memoryfield-sync"
  mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>. $HOME/.config/memoryfield-sync/env; exec '$HERE/mf-sync' --sync --strict</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>MEMORYFIELD</key><string>$FIELD</string>
    <key>MEMORYFIELD_DB9</key><string>$DB</string>
  </dict>
  <key>StartInterval</key><integer>$((INTERVAL * 60))</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOGDIR/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/launchd.err.log</string>
</dict>
</plist>
EOF
  if [ "$(uname -s)" = Darwin ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load -w "$PLIST"
    echo "launchd: $LABEL loaded every ${INTERVAL}min (mode=--sync)"
    echo "         tail -f $LOGDIR/launchd.err.log"
  else
    echo "launchd: wrote $PLIST (not macOS, not loaded)"
  fi
elif [ $TIMER = 1 ] && [ $USE_CRON = 0 ] && systemctl --user is-system-running >/dev/null 2>&1; then
  U="$HOME/.config/systemd/user"
  mkdir -p "$U"
  cat > "$U/memoryfield-db9-sync.service" <<EOF
[Unit]
Description=Mirror \$HOME memoryfield to db9 database "$DB"

[Service]
Type=oneshot
Environment=HOME=$HOME
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=MEMORYFIELD=$FIELD
Environment=MEMORYFIELD_DB9=$DB
ExecStart=$HERE/mf-sync --sync --strict
Nice=10
EOF
  cat > "$U/memoryfield-db9-sync.timer" <<EOF
[Unit]
Description=Every $INTERVAL min: two-way sync memoryfield with db9

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}min
RandomizedDelaySec=30
Persistent=true
Unit=memoryfield-db9-sync.service

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now memoryfield-db9-sync.timer
  systemctl --user start memoryfield-db9-sync.service
  echo "timer:     memoryfield-db9-sync.timer every ${INTERVAL}min (mode=--sync)"
  echo "           journalctl --user -u memoryfield-db9-sync.service -f"
elif [ $TIMER = 1 ]; then
  echo "no systemd user instance; add this crontab line instead (note: cron's HOME/PATH are bare,"
  echo "  db9 needs HOME, so prefer the LaunchAgent above or set them in the line):"
  echo "  */$INTERVAL * * * * HOME=$HOME PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin $HERE/mf-sync --sync --strict --field $FIELD --db $DB >>$HOME/.memoryfield-sync-cron.log 2>&1"
fi

# --- optional: install/refresh the memoryfield skill from this repo ------------
if [ $SKILL = 1 ]; then
  SKDIR="$HOME/.agents/skills/local-memoryfield"
  [ -d "$SKDIR" ] || { mkdir -p "$SKDIR" && echo "skill:      created $SKDIR"; }
  if [ -f "$HERE/skill/SKILL.md" ]; then
    if [ ! -f "$SKDIR/SKILL.md" ]; then
      cp "$HERE/skill/SKILL.md" "$SKDIR/SKILL.md"
      echo "skill:      installed $SKDIR/SKILL.md"
    elif ! cmp -s "$HERE/skill/SKILL.md" "$SKDIR/SKILL.md"; then
      cp "$SKDIR/SKILL.md" "$SKDIR/SKILL.md.bak.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
      cp "$HERE/skill/SKILL.md" "$SKDIR/SKILL.md"
      echo "skill:      refreshed $SKDIR/SKILL.md (previous version kept as .bak.*; it is itself a memory page, diff it if you customized it)"
    else
      echo "skill:      SKILL.md already current"
    fi
  fi
  # helper scripts (mnew/msearch/mdream) + symlinks back to this repo's mf-sync
  mkdir -p "$SKDIR/scripts"
  for s in mnew msearch mdream; do
    src="$HERE/skill/scripts/$s"; dst="$SKDIR/scripts/$s"
    [ -f "$src" ] || continue
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
      echo "skill:      scripts/$s already current"
    else
      [ -f "$dst" ] && cp "$dst" "$dst.bak.$(date -u +%Y%m%dT%H%M%SZ)"
      cp "$src" "$dst" && chmod +x "$dst"
      echo "skill:      installed scripts/$s"
    fi
  done
  ln -sf "$HERE/mf-sync" "$SKDIR/scripts/mf-sync"
  ln -sf "$HERE/mf-sync-schema.sql" "$SKDIR/scripts/mf-sync-schema.sql"
fi

# --- optional skill hooks -----------------------------------------------------
if [ $HOOKS = 1 ]; then
  for s in mnew mdream; do
    f="$HOME/.agents/skills/local-memoryfield/scripts/$s"
    [ -f "$f" ] || { echo "skip hook: $f not found"; continue; }
    grep -q 'mf-sync hook' "$f" && { echo "hook already present: $s"; continue; }
    cat >> "$f" <<EOF

# mf-sync hook: push/pull the memoryfield right after this script changes it
nohup "\${MF_SYNC:-$HOME/.local/bin/mf-sync}" --sync >/dev/null 2>&1 &   # hook marker
EOF
    echo "hook added: $s"
  done
fi

cat <<EOF

done. next steps
  mf-sync --status              # what the hub has for this field
  mf-sync --sync --dry-run      # preview what would move which way
  mf-sync --check               # local vs hub consistency (exit 1 on drift)
EOF
