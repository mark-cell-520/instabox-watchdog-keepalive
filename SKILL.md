---
name: instabox-watchdog-keepalive
description: >-
  instabox 免费层 7×24 看门狗与保活技能。五层防御脚本全套：Mac 看门狗主动周期、
  机内窗口守卫、GitHub Actions 兜底、租约续租、烧核抗 idle。含部署、演练、排障。
whenToUse: >-
  当用户要在 instabox（或同类按量云主机）免费层上跑 7×24 任务时使用：搭建保活体系、
  排查撞 480 分钟运行硬顶或 30 分钟 idle 暂停、恢复卡在 suspended、把保活层迁移到
  新机器。典型触发词：看门狗、保活、机器被挂起、runStartedAt、no_capacity、
  8 小时强制暂停、instabox。
metadata:
  version: "1.0.0"
  author: "mark-cell-520"
  license: "MIT"
  platforms: [linux, macos]
  tags: [instabox, watchdog, keepalive, cron, systemd, github-actions]
  verifiedOn: "2026-11-03"
  verifiedEnv: "instabox 免费层；Mac 侧 macOS 27 + bash + curl；机内 Ubuntu guest + systemd user + gh CLI"
  related_skills: [instabox-ops, instabox-keepalive]
---

# instabox 看门狗与保活（Watchdog & Keepalive）

一套在 instabox 免费层上实现 7×24 在线的五层防御脚本，2026-11-02 在生产机器上实测收官。
本技能是**可部署的代码 + 操作手册**：`scripts/` 下五个脚本即拿即用，全部通过环境变量
配置，不含任何机器 ID、密钥、个人路径。更深的运维背景（SSH、控制台、API 端点清单）
见技能 `instabox-ops` 与 `instabox-keepalive`。

边界：只解决「免费层两条宿主硬限导致的非计划停机」，不管机器内部服务的部署与监控。

## 先搞清楚：两条改不了的宿主硬限

动手前必须接受这三个事实，整个设计都是绕它们，不是改它们：

1. **连续运行 8 小时强制暂停**（`maxRunMinutes=480`，免费层锁死，PATCH 被 403 拒），
   撞顶后 5-20 分钟 cooldown，期间所有唤醒路径被拒。
2. **30 分钟无活动自动暂停**（`autoSuspendAfterSeconds=1800`，同样锁死）。
3. **guest 内 reboot 不重置运行计时**（控制台 + API 双重证实）；`runStartedAt`
   "resets only after confirmed sleep"——只有宿主侧暂停/恢复才重置。

**解法**：自愿 `suspend → resume`。重置计时、无 cooldown 惩罚、进程原样恢复
（PID 不变）、停机约 90 秒。代价：resume 可能撞宿主 `no_capacity`（实测持续 13 分钟），
任何恢复逻辑都必须持续重试。另外 **所有 POST/PATCH 必须带 `Idempotency-Key` 头**，
否则 400；`wake` 是唯一例外。

## 五层防御架构

| 层 | 位置 | 频率 | 脚本 | 职责 |
|---|---|---|---|---|
| 1 Mac 看门狗（主力） | 自己的 Mac | 5 分钟 | `scripts/ib-watchdog.sh` | 运行满 390 分钟主动 suspend→resume；平时 wake + 写心跳；suspended/stopped 自动恢复（resume 单轮重试 6 次抗 no_capacity） |
| 2 机内窗口守卫 | guest systemd timer | 10 分钟 | `scripts/run-window-guard.sh` | Mac 不在线时的周期源：窗口 ≥420 分钟**且确认外部恢复器存活**才自我 suspend |
| 3 GitHub Actions keeper | 任意 repo | 15 分钟 | `workflows/keeper.yml` | 终极兜底：wake→resume→start 递降 + 4 轮重试 |
| 4 租约续租 | guest cron | 25 分钟 | `scripts/keepalive-lease.sh` | activity-leases 续租 TTL 3600s，让机器「有任务在跑」 |
| 5 烧核 | guest systemd | 常驻 | `scripts/keep-awake.sh` | 单核 100% nice 19（4 核约 25%），抗 idle 判定的 CPU 杠杆 |

周期分工：看门狗 390 分钟先手 → 守卫 420 分钟兜 → 硬顶 480 分钟永不触及。
另配 `scripts/machine-state-monitor.sh` 做状态取证（状态变化才推送，全量时间线入日志）。

## Prerequisites

- instabox 免费层机器一台；SSH 免密可用；guest 有免密 sudo。
- **scoped API key**（`machines:read` + `machines:write`，只限本机生命周期），
  写成 `INSTABOX_API_KEY=...` 单行，权限 600：
  - Mac 侧默认 `~/.config/instabox-api.env`（`INSTABOX_KEY_ENV` 可改）
  - guest 侧同路径；GitHub 仓库存 repo secret
- guest：`loginctl enable-linger <user>`（systemd user 单元免登录自启）
- Mac 侧：bash + curl（watchdog 同时兼容 macOS 与 Linux 的 stat/date）
- guest 侧：systemd、curl、`gh` CLI（仅层 2 的 keeper 存活检查用，可空）
- 机器 ID：`export INSTABOX_MACHINE_ID=m_xxxxxxxx`（控制台可见；**五个脚本共用**）

## 部署步骤（新机约 30 分钟）

1. **备好 key 与机器 ID**：key 文件 600；`INSTABOX_MACHINE_ID` 写进
   `~/.bashrc`（Mac）和 guest 的 `~/.bashrc` + systemd 单元 `Environment=`。
   验收：`curl -s -H "X-API-Key: $INSTABOX_API_KEY" https://api.instabox.sh/v1/machines/$INSTABOX_MACHINE_ID` 返回 JSON 且含 `"state"`。
2. **层 4 租约续租**：`keepalive-lease.sh` 上 guest，crontab `*/25 * * * *`
   （或 Hermes cron 25 分钟）。验收：手动跑一次退出码 0 且零输出（静默成功）。
3. **层 5 烧核**：`keep-awake.sh` 放 guest `~/.local/bin/`，
   `systemd/keep-awake.service` 装到 `~/.config/systemd/user/`，
   `systemctl --user enable --now keep-awake`。验收：`journalctl --user -u keep-awake`
   有 burn 行，`top` 看到单核 100%。
4. **层 2 窗口守卫**：`run-window-guard.sh` 上 guest，`systemd/run-window-guard.timer`
   + `.service` 装 user 单元，`enable --now`。验收：`systemctl --user list-timers`
   看到 10 分钟周期；日志出现「窗口年龄 N 分钟」行。
5. **层 1 Mac 看门狗（主力，必须最先通）**：`ib-watchdog.sh` 放 Mac，
   `INSTABOX_MACHINE_ID` 预设后挂 cron：
   - 通用：`*/5 * * * * INSTABOX_MACHINE_ID=m_xxx /path/to/ib-watchdog.sh`
   - Hermes：`hermes cron create "every 5m" --name ib-机器看门狗 --script ib-watchdog.sh --no-agent --deliver origin`
   验收：立刻手动跑一次 `IB_CYCLE_MIN=0 bash scripts/ib-watchdog.sh`，
   输出「已完成主动休眠-唤醒周期」且新 `runStartedAt` 翻新（见 §Verification）。
6. **层 3 GitHub keeper（可选但推荐）**：任意 repo（可私有）放 `workflows/keeper.yml`，
   secret `INSTABOX_KEEPER_KEY` = scoped key，variable `INSTABOX_MACHINE_ID`。
   验收：Actions 页手动 dispatch 一次 success。⚠ 定时触发对本账号实测不跑
   （见 Pitfalls），只当手动应急层。
7. **监控**：`machine-state-monitor.sh` 上 guest，5 分钟一跑；状态变化才推送。

## 日常运维 Quick Reference

```bash
# 手动强制一次周期（不改任何文件，演练用）
IB_CYCLE_MIN=0 bash scripts/ib-watchdog.sh
# 看门狗日志（Mac 侧默认 ~/.cache/instabox-watchdog.log）
tail -f ~/.cache/instabox-watchdog.log
# guest 侧两个日志
tail -f ~/.cache/instabox-watchdog/run-window-guard.log
tail -f ~/.cache/instabox-watchdog/machine-state.log
# 挂起取证：mono 增量 < 墙钟增量 = 期间发生过挂起，差值即挂起时长
grep burn ~/.cache/instabox-watchdog/keep-awake.log | tail
# 当前状态
curl -s -H "X-API-Key: $INSTABOX_API_KEY" \
  "https://api.instabox.sh/v1/machines/$INSTABOX_MACHINE_ID" | grep -o '"state":"[^"]*"'
```

行为约定：一切正常 → 脚本零输出（cron 不推送）；主动周期/自动恢复/持续异常 →
输出一行给人。**持续异常才需要人**；单次 no_capacity 失败是平台常态。

## Pitfalls

- **终端输出会脱敏 key 类字符串**：`$INSTABOX_API_KEY` 在终端/工具输出里显示成
  `$INSTA...KEY`。照抄显示文本写脚本 = 注入坏变量名（生产环境真的挂过一次）。
  规矩：**拷贝文件，不重打字节**；跨机传输后 `sha256sum` 对一遍。
- **PATCH 也要 Idempotency-Key**（看门狗写心跳那次 PATCH 也要），漏了 400。
- **wake 拉不回手动 suspend**（"A manual stop/suspend is not undone"），
  恢复手动 suspend 只能 `resume`。
- **resume 的 no_capacity 会持续数分钟到十几分钟**，不是故障；只有连续 1 小时以上
  才人工看控制台。
- **GitHub scheduled workflow 对新账号可能完全不触发**（本账号实测：active、
  无 archived、平台无故障，重注册/2 分钟 cron/真 git push/换文件名四法均无效，
  4 小时零运行）。当手动应急层，主力永远是 Mac 看门狗。
- **守卫的恢复器存活闸门不能删**：没有活着的外部恢复器时自我 suspend = 冻死无人拉，
  比撞 480 硬顶更坏（撞顶有 cooldown，宿主可能自愈）。两条命脉：机器 metadata 里
  Mac 看门狗心跳 15 分钟内，或 keeper 45 分钟内有 run。
- **scoped key 常一身三用**（guest CLI + Mac + GitHub secret），吊销 = 三处同时失效；
  换 key 记得三处同步。
- guest 内脚本依赖 GNU `date -d` / `stat -c`（Linux only）；Mac 侧 watchdog 已做
  macOS/Linux 双兼容，别把 guest 脚本直接搬上 Mac。
- **挂起会冻住全部进程**，所以层 4/5 只能防「从未被挂起」；已挂起只能外部拉。
  检测历史挂起用烧核日志 mono vs 墙钟差值。

## Verification

新部署必须逐条跑过：

- [ ] `bash -n scripts/*.sh` 全过；`keeper.yml` 能被 YAML 解析器读通
- [ ] API  GET 返回 JSON；POST 带 Idempotency-Key 返回 202/200/409
- [ ] 强制演练：`IB_CYCLE_MIN=0` 跑一次看门狗，确认 suspend→resume→
      `runStartedAt` 翻新→guest 内进程 PID 不变（`uptime` 跨周期持续累加）
- [ ] 守卫两条分支都演练：有心跳→越线后被 Mac 看门狗先手周期掉（守卫打不满）；
      把 `INSTABOX_MACHINE_ID` 心跳源停掉→守卫放弃自我 suspend（日志有据）
- [ ] keeper 手动 dispatch 一次 success
- [ ] 连续观察 24 小时：撞 480 硬顶次数 = 0、idle 暂停次数 = 0

生产实测基线（2026-11-02 15:33 看门狗上线至今）：220+ 次执行、4 次主动周期
（含 1 次演练）、0 次撞顶；唯一告警是 11-02 16:14 宿主 no_capacity 窗口
（约 8 分钟后自动恢复），此后 21 小时零非计划停机。

## References

- `references/architecture.md` — 五层设计论证：为什么是 390/420/480、恢复器存活
  闸门的逻辑、no_capacity 重试参数依据
- `references/troubleshooting.md` — 故障树：撞顶了怎么办、恢复不动怎么办、
  守卫不周期怎么办、密钥轮换
- 姊妹技能：`instabox-ops`（SSH/控制台/API 运维）、`instabox-keepalive`
  （保活体系搭建手册）
