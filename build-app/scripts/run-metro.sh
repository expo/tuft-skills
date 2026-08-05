#!/bin/bash
# run-metro.sh — publish a Metro port through `tuft host`, then run Metro under
# launchd with EXPO_PACKAGER_PROXY_URL pinned to the public URL, and verify the
# whole path end to end: local status, public status, and the manifest itself.
#
# Usage: run-metro.sh <project-dir> <host-name> [port]
#
# The order matters: the tuft host binding is created first because Metro embeds
# EXPO_PACKAGER_PROXY_URL in every manifest and bundle URL it serves — the public
# URL has to exist before Metro starts. The env var lives in the plist, so every
# restart (manual or crash) serves public URLs.
set -euo pipefail

PROJECT=$(cd "$1" && pwd)
NAME=$2
LABEL="com.tuft.metro.$NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="/tmp/metro-$NAME.log"

# 0) Stop this project's own agent first so its port reads as free below.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

# 1) Resolve the port. Precedence: explicit argument, then the existing binding
#    (so restarts keep their public URL and port), then the first free port from
#    8081 — several projects run Metro on one machine, and a taken port makes
#    non-interactive Metro exit instead of starting.
BOUND=$(tuft host list | awk -v n="$NAME" '$1 == n {sub(":", "", $2); print $2}')
if [ -n "${3:-}" ]; then
  PORT=$3
elif [ -n "$BOUND" ]; then
  PORT=$BOUND
else
  PORT=8081
  while lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do PORT=$((PORT + 1)); done
fi

# 2) Publish the port. Reuse a matching binding; repoint only this name's own
#    binding when its port changed.
if [ -z "$BOUND" ]; then
  tuft host add "$PORT" --name "$NAME" >/dev/null
elif [ "$BOUND" != "$PORT" ]; then
  tuft host add "$PORT" --name "$NAME" --force >/dev/null
fi
URL=$(tuft host list | awk -v n="$NAME" '$1 == n {print $3}')
[ -n "$URL" ] || { echo "error: tuft host has no binding named $NAME" >&2; exit 1; }

# 3) Write the launchd agent and start it. A fresh bootstrap each run keeps the
#    plist authoritative: whatever this script last wrote is what runs.
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>WorkingDirectory</key><string>$PROJECT</string>
  <key>EnvironmentVariables</key><dict>
    <key>EXPO_PACKAGER_PROXY_URL</key><string>$URL</string>
  </dict>
  <key>ProgramArguments</key><array>
    <string>/bin/zsh</string><string>-lc</string>
    <string>npx expo start --dev-client --port $PORT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST
launchctl bootstrap "gui/$UID" "$PLIST"

# 4) Verify: local status, public status, then that the manifest Metro hands to
#    the dev client is this project's and references the public host.
for _ in $(seq 1 45); do
  curl -fsS --max-time 2 "http://127.0.0.1:$PORT/status" 2>/dev/null | grep -q packager-status:running && break
  sleep 2
done
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/status" | grep -q packager-status:running \
  || { echo "error: Metro did not come up; log tail:" >&2; tail -40 "$LOG" >&2; exit 1; }
curl -fsS --max-time 10 "$URL/status" | grep -q packager-status:running \
  || { echo "error: $URL/status is unreachable; check tuft host list" >&2; exit 1; }

MANIFEST=$(curl -fsS --max-time 10 -H 'expo-platform: ios' "http://127.0.0.1:$PORT/") \
  || { echo "error: no manifest served on port $PORT; log tail:" >&2; tail -40 "$LOG" >&2; exit 1; }
SLUG=$(jq -r '.expo.slug // empty' "$PROJECT/app.json" 2>/dev/null || true)
SERVED_SLUG=$(echo "$MANIFEST" | jq -r '.extra.expoClient.slug // empty')
if [ -n "$SLUG" ] && [ "$SERVED_SLUG" != "$SLUG" ]; then
  echo "error: port $PORT is serving '$SERVED_SLUG', not '$SLUG' — another Metro owns this port; rerun with a free port" >&2
  exit 1
fi
HOSTPART=${URL#https://}
echo "$MANIFEST" | grep -q "$HOSTPART" \
  || { echo "error: manifest lacks $HOSTPART — EXPO_PACKAGER_PROXY_URL was not applied" >&2; exit 1; }

# 5) Hand back everything the session needs.
SCHEME=$(jq -r '.expo.scheme // empty | if type == "array" then .[0] else . end' "$PROJECT/app.json" 2>/dev/null || true)
ENC=$(jq -rn --arg u "$URL" '$u|@uri')
echo "Metro is running and verified end to end."
echo "  project:     $PROJECT"
echo "  public URL:  $URL"
if [ -n "$SCHEME" ]; then
  echo "  dev client:  $SCHEME://expo-development-client/?url=$ENC"
else
  echo "  dev client:  <scheme>://expo-development-client/?url=$ENC   (scheme is unset in app.json; read it from the app config)"
fi
echo "  log:         $LOG"
echo "  restart:     launchctl kickstart -k gui/$UID/$LABEL"
echo "  stop:        launchctl bootout gui/$UID/$LABEL"
