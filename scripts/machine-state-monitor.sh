#!/bin/bash
# 机器状态监控：每 5 分钟记录一次 instabox 机器状态，用于取证挂起规律。
# 静默 watchdog：正常零输出；状态发生变化时才输出一行（供 cron 报警）。
# 完整时间线写入 logs/machine-state.log（重启/挂起/恢复的时刻与 runStartedAt）。
set -uo pipefail

KEYENV="${INSTABOX_KEY_ENV:-$HOME/.config/instabox-api.env}"
M="${INSTABOX_MACHINE_ID:?INSTABOX_MACHINE_ID 未设置：export INSTABOX_MACHINE_ID=m_xxx（机器 ID 见 instabox 控制台）}"
LOG="${INSTABOX_MONITOR_LOG:-$HOME/.cache/instabox-watchdog/machine-state.log}"
LAST="${INSTABOX_MONITOR_LAST:-$HOME/.cache/instabox-watchdog/machine-state-last}"
mkdir -p "$(dirname "$LOG")" "$(dirname "$LAST")" 2>/dev/null || true

[ -f "$KEYENV" ] || { echo "✗ key 文件缺失"; exit 1; }
# shellcheck disable=SC1090
source "$KEYENV"

RESP=$(curl -s --max-time 20 "${INSTABOX_API_BASE:-https://api.instabox.sh}/v1/machines/$M" \
  -H "X-API-Key: $INSTABOX_API_KEY")

STATE=$(printf '%s' "$RESP" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("state", "?"), d.get("runStartedAt", "?"), d.get("autoSuspendAfterSeconds", "?"), d.get("maxRunMinutes", "?"))
except Exception:
    print("parse_error")
' 2>/dev/null)

NOW=$(date '+%F %T')
UP=$(awk '{printf "%d", $1}' /proc/uptime)
printf '%s | %s | uptime=%ss\n' "$NOW" "$STATE" "$UP" >>"$LOG"

# 日志自限：超过 2 MB 截断
if [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
    : >"$LOG"
fi

CUR_STATE=$(printf '%s' "$STATE" | awk '{print $1}')
PREV=""
[ -f "$LAST" ] && PREV=$(cat "$LAST")
if [ "$CUR_STATE" != "$PREV" ]; then
    echo "$CUR_STATE" >"$LAST"
    if [ -n "$PREV" ]; then
        echo "⚠ 机器状态变化: $PREV → $CUR_STATE（$NOW, runStartedAt=$(printf '%s' "$STATE" | awk '{print $2}')）"
    fi
fi
exit 0
