#!/bin/bash
# activity-leas 续租：免费计划 idle 挂起（30 分钟）无法通过 PATCH 关闭（官方 403），
# 但文档明确「进行中的任务租约让机器保持忙碌」——本脚本为 hfs 自动化任务持有租约，
# 每 25 分钟续租（TTL 3600s），机器不进入 idle，cron 链路不被挂起打断。
# 静默 watchdog：成功零输出；失败才输出（供 cron 报警）。
set -uo pipefail

KEYENV="${INSTABOX_KEY_ENV:-$HOME/.config/instabox-api.env}"
M="${INSTABOX_MACHINE_ID:?INSTABOX_MACHINE_ID 未设置：export INSTABOX_MACHINE_ID=m_xxx（机器 ID 见 instabox 控制台）}"

[ -f "$KEYENV" ] || { echo "✗ 租约续租失败：key 文件缺失 $KEYENV"; exit 1; }
# shellcheck disable=SC1090
source "$KEYENV"

RESP=$(curl -s -X PUT "${INSTABOX_API_BASE:-https://api.instabox.sh}/v1/machines/$M/activity-leases/${INSTABOX_LEASE_NAME:-automation}" \
  -H "X-API-Key: $INSTABOX_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"ttlSeconds": 3600}' --max-time 20)

if printf '%s' "$RESP" | grep -q '"expiresAt"'; then
  exit 0
fi
echo "✗ 租约续租失败（$(date -u +%H:%MZ)）：$(printf '%s' "$RESP" | head -c 120)"
echo "  机器可能在 30 分钟 idle 后被挂起，晨间 cron 将延迟到下次唤醒"
exit 1
