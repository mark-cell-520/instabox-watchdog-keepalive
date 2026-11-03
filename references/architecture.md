# 架构论证：为什么是 390 / 420 / 480

## 时间预算

```
0 ─────────── 390min ─────────── 420min ─────────── 480min
│               │                  │                  │
│               │                  │                  └─ 宿主强制暂停（不可达）
│               │                  └─ 机内守卫自我 suspend（仅恢复器存活时）
│               └─ Mac 看门狗主动 suspend→resume（主力）
└─ runStartedAt 起点（宿主侧暂停/恢复才翻新）
```

- **390 分钟（看门狗）**：距硬顶 90 分钟余量。覆盖一次完整周期需要的时间：
  suspend 生效（≤60s）+ resume 重试（最坏 6 轮 ≈10 分钟，实测 no_capacity
  可持续 13 分钟）+ 状态轮询间隔。90 分钟余量 = 3 倍最坏恢复时间。
- **420 分钟（守卫）**：Mac 看门狗停机时的第二周期源，距硬顶 60 分钟余量。
  正常情况永远不会触发——看门狗 390 分钟先手把窗口重置了。它存在的意义是
  「Mac 断电/断网/升级」时机器仍能自我周期。
- **480 分钟**：宿主硬顶，五层防御的目标是让它在任何情况下都不可达。

## 为什么必须是 suspend→resume，而不是 reboot

2026-11-02 用两次代价验证过：

1. guest 内 `sudo reboot`：`runStartedAt` 不动（用户从控制台截图确认，
   API 文档佐证 "resets only after confirmed sleep"）。reboot 版脚本备份在
   生产机 `.bak-reboot-20261102`，是错的，别再用了。
2. API `suspend → resume`：`runStartedAt` 翻新、进程 PID 原样恢复、
   停机约 90 秒、无 cooldown 惩罚。唯一代价是可能撞 `no_capacity`。

## 恢复器存活闸门（守卫的核心逻辑）

自我 suspend 是**不可逆的单向门**：机器冻结后，guest 内没有任何东西能自救。
所以守卫在越线时先问：「我挂了之后，谁拉我？」

- **Mac 看门狗心跳**：看门狗每跳把 `mac_watchdog_ts` PATCH 进机器 metadata
  （PATCH 也要 Idempotency-Key）。15 分钟内心跳新鲜 = Mac 活着。
  （注意：PATCH metadata 本身不带机器状态语义，纯心跳。）
- **GitHub keeper 运行记录**：`gh run list --repo <keeper-repo> --limit 1`
  45 分钟内有 run = keeper 活着。

两者都过期 → **放弃自我 suspend**，留给 480 硬顶路径。理由是代价比较：
冻死无人拉（无限期停机）比撞顶更坏——撞顶有 cooldown，宿主侧还可能自愈；
等恢复器回来后再周期也不迟（守卫还有 6 小时频率闸防抖）。

另外守卫硬编码 `SUSPEND_AT_MIN=420` 不接受环境变量覆盖：2026-11-02 演练时
误传 0，导致机器每 10 分钟被挂一次、cron 链路被杀。演练一律用看门狗的
`IB_CYCLE_MIN=0`（有单实例锁和状态机保护）。

## no_capacity 重试参数

- 实测：resume 失败错误码 `no_capacity`，`retryAfter=60s`，可持续 13 分钟。
- 看门狗：单次运行内 6 轮（每轮 resume + 等 54s + 隔 45s ≈ 10 分钟），
  重试期间只写日志不推送；全失败才告警，下轮 5 分钟后继续。
- keeper：单 tick 4 轮递降（wake→resume→start），每轮内含 wait_running
  12×5s。跨 tick 继续试——容量恢复前失败是常态，不构成人工介入信号。

## idle 防御为什么是三层

`autoSuspendAfterSeconds=1800` 的判定依据是 "no agent working, no terminal
use and little CPU"。前两项从 guest 内部影响不了，唯一杠杆是 CPU：

- **层 5 烧核**：单核 100%（4 核约 25%），nice 19 保证真活来时立刻让路。
  第一版「每 90 秒烧 30 秒」（占空比 33%，均值约 8%）实测不够——
  11-02 07:20 正在烧 CPU 时照样被挂起。常驻是唯一可靠形态。
- **层 4 租约续租**：文档明确「进行中的任务租约让机器保持忙碌」，
  TTL 3600s、25 分钟一续，双保险。
- **看门狗 wake**：Mac 侧每 5 分钟一次 wake 记录活动，第三层保险
  （wake 不需要 Idempotency-Key）。

三层各自独立失效都还有两层；同时失效才会 idle 暂停——而即便暂停了，
看门狗 5 分钟内就会发现并恢复。

## 挂起取证：mono vs 墙钟

挂起冻住全部进程，`CLOCK_MONOTONIC` 不前进而墙钟前进。烧核日志每行带
`mono=`（/proc/uptime），相邻两行「mono 增量 < 墙钟增量」即说明期间发生过
挂起，差值就是挂起时长。这是零成本的长期监测手段，比任何探针都准。
