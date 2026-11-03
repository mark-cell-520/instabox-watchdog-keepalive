#!/bin/bash
# 保活守护进程：让一个核心常驻满载，避免 instabox 宿主把机器判定为空闲而自动挂起。
#
# 背景（2026-11-01/02 实测）：
#   - 空闲自动暂停阈值 30 分钟，文档说 "Idle means no agent working,
#     no terminal use and little CPU"。前两项从 guest 内部影响不了，
#     唯一能施加影响的杠杆就是 CPU。
#   - 第一版是「每 90 秒烧 30 秒」，单核占空比 33%，4 核合计约 8% 平均 CPU。
#     实测把挂起频率从「每 31~35 分钟一次」降到「20 小时 2 次」，
#     但 11-02 07:20 正在烧 CPU 时照样被挂起——8% 平均被宿主拉长窗口后压过了阈值。
#   - 所以第二版改成常驻：一个核心 100% 不停，4 核合计约 25%，这是 guest 内
#     能给的最强信号。nice 19 保证真有活来时内核立刻让路，两个飞书桥永远优先。
#
# 注意：挂起会冻住所有进程，所以本任务只能阻止「从未被挂起」的情况；机器一旦
# 已经挂起，只能靠外部 wake（instabox wake / SSH / 端口请求）唤醒，guest 内无解。
#
# 日志 $INSTABOX_KEEP_AWAKE_DIR/keep-awake.log（默认 ~/.cache/instabox-watchdog/）每行带 mono=（单调钟）。
# 挂起时单调钟不前进而墙钟前进，所以相邻两行「mono 增量 < 墙钟增量」即说明
# 这两行之间发生过挂起，差值就是挂起时长。这是最省事的长期监测手段。
set -u

LOG_DIR="${INSTABOX_KEEP_AWAKE_DIR:-$HOME/.cache/instabox-watchdog}"
LOG_FILE=$LOG_DIR/keep-awake.log
LOCK_FILE=$LOG_DIR/keep-awake.lock

# ---- 可调参数 ----
NICE_LEVEL=19          # 越低越谦让，保证两个飞书桥永远优先
CHUNK_SECONDS=60       # 每烧多久记一行日志；两行之间只隔几十毫秒，等效单核常驻
LOG_MAX_BYTES=5242880  # 日志自我限制，5 MB 截断，避免把磁盘慢慢吃光
# ------------------

mkdir -p "$LOG_DIR"

# 单实例保护：timer 残留、手滑多开、systemd 重复触发，都只会有一个在烧。
# 拿不到锁就安静退出，绝不开第二个 burner 去抢第二个核。
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    printf '%s 已有实例在跑，本实例退出 pid=%d\n' "$(date '+%F %T')" "$$" >>"$LOG_FILE"
    exit 0
fi

printf '%s keep-awake daemon start pid=%d nice=%d chunk=%ss\n' \
    "$(date '+%F %T')" "$$" "$NICE_LEVEL" "$CHUNK_SECONDS" >>"$LOG_FILE"

# SIGTERM 时留一行痕迹，方便区分「正常停机」和「被冻住」
trap 'printf "%s keep-awake daemon stop pid=%d\n" "$(date "+%F %T")" "$$" >>"$LOG_FILE"; exit 0' TERM INT

while true; do
    # 动手前的负载，用来验证这一轮到底有没有把 CPU 顶起来
    before=$(cut -d' ' -f1-3 /proc/loadavg)

    # 烧 CPU：timeout 到点发 SIGTERM，awk 里是纯算术空转，不碰磁盘不碰网络。
    # 挂起期间 CLOCK_MONOTONIC 不前进，所以 timeout 不会提前触发，
    # 恢复后这 60 秒会照原样跑完——日志里的 mono 增量因此能反映出挂起。
    nice -n "$NICE_LEVEL" timeout "$CHUNK_SECONDS" \
        awk 'BEGIN{while(1){for(i=0;i<200000;i++){x=sqrt(i*1.0000001)+sin(i)*cos(i)}}}' \
        >/dev/null 2>&1
    rc=$?

    after=$(cut -d' ' -f1-3 /proc/loadavg)
    mono=$(cut -d' ' -f1 /proc/uptime)

    printf '%s burn=%ss rc=%d nice=%s load[%s -> %s] mono=%s\n' \
        "$(date '+%F %T')" "$CHUNK_SECONDS" "$rc" "$NICE_LEVEL" \
        "$before" "$after" "$mono" >>"$LOG_FILE"

    # 日志自我限制
    if [ "$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
        : >"$LOG_FILE"
    fi
done
