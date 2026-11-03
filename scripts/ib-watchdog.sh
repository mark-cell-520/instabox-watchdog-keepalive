#!/bin/bash
# instabox 机器看门狗——由 Hermes cron（no_agent）每 5 分钟执行一次。
#
# 背景（2026-11-02 实测）：免费层 instabox 两条宿主侧硬限制——
#   1) maxRunMinutes=480：连续运行满 8 小时强制暂停，仅 admin 可改，免费层锁死；
#      guest 内重启不重置该计时（用户从控制台确认）。
#   2) autoSuspendAfterSeconds=1800：30 分钟无活动自动暂停，免费层锁死 1800。
#   撞顶强制暂停后有 5-20 分钟 cooldown，期间所有唤醒路径被拒。
#
# 解法（同日实测验证）：自愿 suspend→resume 可重置 runStartedAt
# （API 文档：runStartedAt "resets only after confirmed sleep"），无 cooldown 惩罚，
# 全部进程原样恢复，停机约 90 秒。本脚本运行满 6.5 小时主动执行该周期，
# 距 8 小时硬顶留 90 分钟余量；年轻运行时每跳 wake 记录活动防 idle 暂停
# （与 guest 内租约续租、烧核守护构成三层保险）；机器被暂停/停止时自动恢复。
#
# no_capacity 教训（2026-11-02 16:08 实测）：resume 可能因宿主无容量失败
# （错误码 no_capacity，retryAfter 60s，实测持续 13 分钟）。恢复必须在单次运行内
# 反复重试（recover_running，共 6 轮约 10 分钟），重试期间静默；
# 仅当连续全部失败才推送告警。GitHub Actions keeper（每 15 分钟）是第二恢复器。
#
# 行为：一切正常 → 静默（空输出不推送）；主动周期/自动恢复/持续异常 → 推送来源会话。
# 日志：$INSTABOX_WATCHDOG_LOG（默认 ~/.cache/instabox-watchdog.log，超 2MB 自截断）
# 演练：IB_CYCLE_MIN=0 bash scripts/ib-watchdog.sh   # 立即强制一次周期
#
# ── 配置（环境变量覆盖，适配任意机器；均可用 export 预设）────────────────
#   INSTABOX_MACHINE_ID     必填。机器 ID（控制台/API 可见，形如 m_xxxxxxxx）
#   INSTABOX_KEY_ENV        API key 文件路径（默认 ~/.config/instabox-api.env；
#                           文件内含一行 INSTABOX_API_KEY=...，权限保持 600）
#   INSTABOX_API_BASE       API 根地址（默认 https://api.instabox.sh）
#   INSTABOX_WATCHDOG_LOG   日志路径（默认 ~/.cache/instabox-watchdog.log）
#   INSTABOX_WATCHDOG_LOCK  单实例锁目录（默认 ~/.cache/ib-watchdog.lock.d）
#   IB_CYCLE_MIN            主动周期阈值（分钟，默认 390=6.5h；硬顶 480）
set -u

KEYENV="${INSTABOX_KEY_ENV:-$HOME/.config/instabox-api.env}"
M="${INSTABOX_MACHINE_ID:?INSTABOX_MACHINE_ID 未设置：export INSTABOX_MACHINE_ID=m_xxx（机器 ID 见 instabox 控制台）}"
API="${INSTABOX_API_BASE:-https://api.instabox.sh}/v1/machines/$M"
LOG="${INSTABOX_WATCHDOG_LOG:-$HOME/.cache/instabox-watchdog.log}"
LOCK="${INSTABOX_WATCHDOG_LOCK:-$HOME/.cache/ib-watchdog.lock.d}"
CYCLE_MIN="${IB_CYCLE_MIN:-390}"   # 6.5 小时主动周期（硬顶 480，余量 90 分钟）

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || stat -f %z "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then : > "$LOG"; fi
  echo "$(ts) $*" >> "$LOG"
}
alert() { log "ALERT $*"; echo "$*"; }

[ -f "$KEYENV" ] || { echo "instabox 看门狗故障：key 文件缺失 $KEYENV（$(ts)）"; exit 0; }
set -a; . "$KEYENV"; set +a
AUTH="X-API-Key: $INSTABOX_API_KEY"

# 单实例锁（mkdir 原子锁，macOS 无 flock）。恢复重试可达 10 分钟，5 分钟一跳，
# 不并发。持有者 PID 已死、或锁超过 15 分钟，才破锁。
if ! mkdir "$LOCK" 2>/dev/null; then
  OLD="$(cat "$LOCK/pid" 2>/dev/null)"
  STALE="$(find "$LOCK" -mmin +15 2>/dev/null)"
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null && [ -z "$STALE" ]; then
    exit 0
  fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

get() { curl -s -m 20 "$API" -H "$AUTH"; }
field() { grep -o "\"$1\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }
post() { # $1=路径 $2=Idempotency-Key；输出 http 码
  curl -s -m 30 -X POST "$API/$1" -H "$AUTH" -H "Content-Type: application/json" \
    -H "Idempotency-Key: $2" -d '{}' -o /dev/null -w '%{http_code}'
}
iso2epoch() { date -u -j -f "%Y-%m-%dT%H:%M:%S" "${1%%.*}" +%s 2>/dev/null || date -u -d "${1%%.*}" +%s 2>/dev/null; }
LAST_S=""
wait_state() { # $1=目标状态 $2=最多轮次（每轮 3 秒）
  local i=0 s=""
  while [ "$i" -lt "$2" ]; do
    i=$((i+1)); sleep 3
    s="$(get | field state)"
    [ "$s" = "$1" ] && return 0
  done
  LAST_S="$s"
  return 1
}
# 恢复运行：resume 可能因宿主 no_capacity 失败（实测持续 13 分钟）。
# 单次运行内重试 6 轮（每轮 resume + 等 54 秒 + 隔 45 秒，合计约 10 分钟），
# 重试期间只写日志不推送；全部失败才返回 1，由调用方告警。
recover_running() {
  local i=0 code
  while [ "$i" -lt 6 ]; do
    i=$((i+1))
    code="$(post resume "wd-res-$(date +%s)-$i")"
    log "resume 第 ${i} 次 http=$code"
    if wait_state running 18; then return 0; fi
    [ "$i" -lt 6 ] && sleep 45
  done
  return 1
}

J="$(get)"
if [ -z "$J" ]; then
  alert "instabox 看门狗：API 无响应，本轮跳过（$(ts)）"
  exit 0
fi
STATE="$(printf '%s' "$J" | field state)"
RUN="$(printf '%s' "$J" | field runStartedAt)"
COOL="$(printf '%s' "$J" | field cooldownUntil)"
NOW="$(date -u +%s)"
AGE=0
if [ -n "$RUN" ]; then
  S="$(iso2epoch "$RUN")" && [ -n "$S" ] && AGE=$(( (NOW - S) / 60 ))
fi
log "state=$STATE age=${AGE}min run=${RUN:-null} cool=${COOL:-null}"

case "$STATE" in
  running)
    if [ "$AGE" -ge "$CYCLE_MIN" ]; then
      log "运行已满 ${AGE} 分钟 ≥ ${CYCLE_MIN}，执行主动 suspend→resume 周期"
      code="$(post suspend "wd-sus-$(date +%s)")"
      case "$code" in 202|200|409) ;; *) alert "instabox 看门狗：suspend 失败 http=$code（$(ts)），下轮重试"; exit 0;; esac
      if wait_state suspended 20; then
        log "已 suspended，执行 resume"
        if recover_running; then
          NEW="$(get | field runStartedAt)"
          log "周期完成，新 runStartedAt=$NEW"
          echo "instabox 机器已完成主动休眠-唤醒周期（约90秒）：8小时运行计时已重置，进程全部原样恢复。新周期开始于 ${NEW}。"
        else
          alert "instabox 看门狗：周期 resume 连续 6 次失败（可能宿主无容量 no_capacity），机器停在 suspended，下轮继续重试；详情 ~/.hermes/logs/ib-watchdog.log"
        fi
      else
        alert "instabox 看门狗：suspend 后未进入 suspended（当前 ${LAST_S:-未知}），本轮放弃下轮重试"
      fi
      exit 0
    fi
    # 年轻运行：wake 记录活动，防 30 分钟 idle 暂停（guest 内另有租约续租+烧核守护）；
    # 同时把心跳写进机器 metadata——机内守卫据此判断「外部恢复器存活」才自我 suspend
    curl -s -m 50 -X POST "$API/wake" -H "$AUTH" -o /dev/null || true
    curl -s -m 20 -X PATCH "$API" -H "$AUTH" -H "Content-Type: application/json" \
      -H "Idempotency-Key: wd-hb-$(date +%s)" \
      -d "{\"metadata\":{\"mac_watchdog_ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" -o /dev/null || true
    exit 0
    ;;
  suspended)
    if [ -n "$COOL" ]; then
      cs="$(iso2epoch "$COOL")"
      if [ -n "$cs" ] && [ "$cs" -gt "$NOW" ]; then
        log "suspended 且 cooldown 中（至 $COOL），等待"
        exit 0
      fi
    fi
    log "suspended 无有效 cooldown，执行 resume 恢复"
    if recover_running; then
      log "已恢复 running"
      echo "instabox 机器被发现暂停，已自动唤醒恢复（$(ts)）。"
    else
      alert "instabox 看门狗：resume 连续 6 次失败（可能宿主无容量 no_capacity），机器仍 suspended，下轮继续重试；详情 ~/.hermes/logs/ib-watchdog.log"
    fi
    exit 0
    ;;
  stopped)
    log "stopped，执行 start"
    code="$(post start "wd-start-$(date +%s)")"
    case "$code" in 202|200|409) ;; *) alert "instabox 看门狗：start 失败 http=$code（$(ts)）"; exit 0;; esac
    echo "instabox 机器处于 stopped，已发送 start 指令（$(ts)）。"
    exit 0
    ;;
  creating|starting|stopping|suspending|resuming)
    log "过渡状态 $STATE，等待"
    exit 0
    ;;
  *)
    alert "instabox 看门狗：机器状态异常 '$STATE'（$(ts)），请检查 instabox 控制台"
    exit 0
    ;;
esac
