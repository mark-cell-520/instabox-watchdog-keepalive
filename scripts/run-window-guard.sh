#!/bin/bash
# 8 小时运行窗口守卫：免费计划 maxRunMinutes=480 官方锁死（PATCH 被拒），
# 机器连续运行满 480 分钟会被强制挂起（2026-11-02 07:20 实测过一次，停机约 80 分钟），
# 且撞顶后还有 5-20 分钟 cooldown，期间所有唤醒路径被拒。
#
# 2026-11-02 两次修正：
# 1) 原设计用「guest 内 sudo reboot」抢先重启是错的——控制台截图与 API 双重证实：
#    guest 内重启不重置 runStartedAt，只有「确认睡眠」（宿主侧暂停）才重置
#    （文档：runStartedAt "resets only after confirmed sleep"）。reboot 版备份在
#    .bak-reboot-20261102。
# 2) 自我 suspend 后机器冻结、机内无物能自救，必须确认有活着的外部恢复器才挂：
#    - Mac 看门狗心跳：机器 metadata.mac_watchdog_ts（每 5 分钟一写，15 分钟内视为存活）
#    - GitHub keeper：repo 最近一次 run（45 分钟内视为存活；gh 用的是宿主 token，
#      token 轮换后这条路自动失效，由 Mac 心跳兜底）
#    两者都过期时放弃自我 suspend——冻死无人拉比撞 480 硬顶更坏
#    （撞顶有 cooldown，宿主可能自动恢复；恢复器回来后再挂也不迟）。
#
# 保护规则：
#   - 状态非 running 时什么都不做（已被挂起，等外部恢复器）
#   - 只在窗口年龄 ≥420 分钟时动手（距 480 留 60 分钟余量）
#   - suspend 成功即重置窗口，无短周期重复风险
set -uo pipefail

KEYENV="${INSTABOX_KEY_ENV:-$HOME/.config/instabox-api.env}"
M="${INSTABOX_MACHINE_ID:?INSTABOX_MACHINE_ID 未设置：export INSTABOX_MACHINE_ID=m_xxx（机器 ID 见 instabox 控制台）}"
API="${INSTABOX_API_BASE:-https://api.instabox.sh}/v1/machines/$M"
KEEPER_REPO="${INSTABOX_KEEPER_REPO:-}"   # 形如 owner/repo；留空=跳过 keeper 存活检查
LOG="${INSTABOX_GUARD_LOG:-$HOME/.cache/instabox-watchdog/run-window-guard.log}"
SUSPEND_AT_MIN=420           # 硬编码：不再接受环境变量覆盖（演练误传 0 会隔几分钟挂一次机器，杀 cron）
MIN_SUSPEND_INTERVAL=21600   # 两次 suspend 至少间隔 6 小时，防 resume 不重置窗口时的循环
MARK="${INSTABOX_GUARD_MARK:-$HOME/.cache/instabox-watchdog/last-suspend}"
mkdir -p "$(dirname "$LOG")" "$(dirname "$MARK")" 2>/dev/null || true
MAC_HB_MAX_AGE=900        # Mac 看门狗心跳有效期（秒）——它每 5 分钟一跳
KEEPER_MAX_AGE=2700       # GitHub keeper 运行记录有效期（秒）——名义 15 分钟一跳

[ -f "$KEYENV" ] || { echo "✗ key 文件缺失 $KEYENV"; exit 1; }
# shellcheck disable=SC1090
source "$KEYENV"

NOW=$(date '+%F %T')
NOW_EPOCH=$(date +%s)
RESP=$(curl -s --max-time 20 "$API" -H "X-API-Key: $INSTABOX_API_KEY")

STATE=$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state","?"))' 2>/dev/null)
RUNAT=$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("runStartedAt",""))' 2>/dev/null)
MAC_HB=$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("metadata",{}).get("mac_watchdog_ts",""))' 2>/dev/null)

if [ "$STATE" != "running" ] || [ -z "$RUNAT" ]; then
    printf '%s | state=%s，非运行中，跳过（等外部恢复器）\n' "$NOW" "$STATE" >>"$LOG"
    exit 0
fi

AGE_MIN=$(( ( NOW_EPOCH - $(date -d "$RUNAT" +%s) ) / 60 ))
printf '%s | running | 窗口年龄 %d 分钟（起点 %s）\n' "$NOW" "$AGE_MIN" "$RUNAT" >>"$LOG"

# 日志自限 1 MB
if [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    : >"$LOG"
fi

[ "$AGE_MIN" -lt "$SUSPEND_AT_MIN" ] && exit 0

# ── 外部恢复器存活检查（两者有其一方可自我 suspend）──
RESUMER=""
if [ -n "$MAC_HB" ]; then
    HB_EPOCH=$(date -d "$MAC_HB" +%s 2>/dev/null || echo 0)
    if [ $(( NOW_EPOCH - HB_EPOCH )) -lt "$MAC_HB_MAX_AGE" ]; then
        RESUMER="Mac看门狗（心跳 $MAC_HB）"
    fi
fi
if [ -z "$RESUMER" ]; then
    LAST_RUN=$(timeout 20 gh run list --repo "$KEEPER_REPO" --limit 1 --json createdAt --jq '.[0].createdAt' 2>/dev/null || true)
    if [ -n "$LAST_RUN" ]; then
        LR_EPOCH=$(date -d "$LAST_RUN" +%s 2>/dev/null || echo 0)
        if [ $(( NOW_EPOCH - LR_EPOCH )) -lt "$KEEPER_MAX_AGE" ]; then
            RESUMER="GitHub keeper（运行于 $LAST_RUN）"
        fi
    fi
fi
if [ -z "$RESUMER" ]; then
    printf '%s | 窗口年龄 %d 分钟已越线，但无存活外部恢复器（Mac 心跳过期、GitHub 无近期运行）——放弃自我 suspend，留给 480 硬顶路径\n' "$NOW" "$AGE_MIN" >>"$LOG"
    exit 0
fi

# 频率闸：距上次 suspend 不足 6 小时则再等等（平台本就会周期重设 runStartedAt）
if [ -f "$MARK" ]; then
    LAST_SUS=$(stat -c %Y "$MARK" 2>/dev/null || echo 0)
    if [ $(( NOW_EPOCH - LAST_SUS )) -lt "$MIN_SUSPEND_INTERVAL" ]; then
        printf '%s | 窗口年龄 %d 分钟已越线且恢复器存活，但距上次 suspend 仅 %d 分钟（< %d 分钟）——等平台重设窗口\n' \
            "$NOW" "$AGE_MIN" $(( (NOW_EPOCH - LAST_SUS) / 60 )) $(( MIN_SUSPEND_INTERVAL / 60 )) >>"$LOG"
        exit 0
    fi
fi
: >"$MARK" 2>/dev/null || true

printf '%s | 窗口年龄 %d 分钟 ≥ %d 分钟，平台未重设；外部恢复器存活：%s —— API 自我 suspend 破 480 硬顶\n' \
    "$NOW" "$AGE_MIN" "$SUSPEND_AT_MIN" "$RESUMER" >>"$LOG"
# 先落日志再动手：suspend 后本机即冻结，后面的代码可能跑不完
curl -s --max-time 25 -X POST "$API/suspend" \
    -H "X-API-Key: $INSTABOX_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: guard-sus-$(date +%s)" \
    -d '{}' -o /dev/null
printf '%s | suspend 调用已发出；若状态变为 suspended 即已冻结，恢复器会拉起\n' "$NOW" >>"$LOG"
exit 0
