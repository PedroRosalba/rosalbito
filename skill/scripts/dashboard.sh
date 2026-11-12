#!/usr/bin/env bash
# dashboard.sh — the run dashboard, live or as a snapshot. Local only: no CDN, nothing leaves the machine.
#
#   dashboard.sh --serve [--open]     live: dashboard-server.mjs on http://localhost:$ROSALBITO_PORT (7777);
#                                     the page updates itself as runs progress (Ctrl-C stops it)
#   dashboard.sh --install-service    keep the live server running in the background (macOS launchd,
#                                     starts at login); --uninstall-service removes it
#   dashboard.sh [--no-collect] [--open] [root ...]
#                                     snapshot: collect.sh, then $ROSALBITO_HOME/dashboard.html
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,10p' "$0"; exit 0; }
PORT="${ROSALBITO_PORT:-7777}"
LABEL="com.rosalbito.dashboard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
COLLECT=1; OPEN=0; SERVE=0; ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-collect) COLLECT=0; shift;;
    --open) OPEN=1; shift;;
    --serve) SERVE=1; shift;;
    --install-service)
      command -v launchctl >/dev/null || die "launchd not available (macOS only); use --serve"
      NODE="$(command -v node)" || die "node is required"
      mkdir -p "$(dirname "$PLIST")" "$ROSALBITO_HOME"
      cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$NODE</string><string>$SKILL_DIR/scripts/dashboard-server.mjs</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$PATH</string>
    <key>ROSALBITO_PORT</key><string>$PORT</string>
    <key>ROSALBITO_HOME</key><string>$ROSALBITO_HOME</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$ROSALBITO_HOME/dashboard-server.log</string>
  <key>StandardErrorPath</key><string>$ROSALBITO_HOME/dashboard-server.log</string>
</dict></plist>
EOF
      launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$PLIST" || die "launchctl bootstrap failed"
      echo "service $LABEL installed: http://localhost:$PORT (log $ROSALBITO_HOME/dashboard-server.log)"
      exit 0;;
    --uninstall-service)
      launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
      rm -f "$PLIST"; echo "service $LABEL removed"; exit 0;;
    *) ROOTS+=("$1"); shift;;
  esac
done

if [ "$SERVE" = 1 ]; then
  command -v node >/dev/null || die "node is required for --serve"
  [ "$OPEN" = 1 ] && command -v open >/dev/null && (sleep 1; open "http://localhost:$PORT") &
  exec env ROSALBITO_PORT="$PORT" node "$SKILL_DIR/scripts/dashboard-server.mjs"
fi

[ "$COLLECT" = 1 ] && { bash "$SKILL_DIR/scripts/collect.sh" ${ROOTS[@]+"${ROOTS[@]}"} || exit 1; }
INDEX="$ROSALBITO_HOME/runs.jsonl"
[ -f "$INDEX" ] || die "no index at $INDEX (run collect.sh)"
OUT="$ROSALBITO_HOME/dashboard.html"
DATA="$(mktemp)"; trap 'rm -f "$DATA"' EXIT
# `</` is escaped so no string in the data can close the <script> element
jq -sc --arg at "$(now_iso)" --arg index "$INDEX" --slurpfile p "$SKILL_DIR/config/pricing.json" \
  '{generated_at: $at, index: $index, pricing_as_of: $p[0].as_of, live: false, runs: .}' "$INDEX" | sed 's#</#<\\/#g' > "$DATA"
awk -v data="$DATA" '
  index($0, "__ROSALBITO_DATA__") { split($0, parts, "__ROSALBITO_DATA__"); printf "%s", parts[1];
    while ((getline line < data) > 0) printf "%s", line; print parts[2]; next }
  { print }' "$SKILL_DIR/templates/dashboard.html" > "$OUT"
echo "dashboard -> $OUT"
[ "$OPEN" = 1 ] && command -v open >/dev/null && open "$OUT"
exit 0
