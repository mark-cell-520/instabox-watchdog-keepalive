# instabox-watchdog-keepalive（看门狗与保活）

[English](README.md) | 中文

五个 shell 脚本，让 **instabox 免费层机器 7×24 在线**，2026-11-02 起在生产环境
实测运行。不依赖 agent、不依赖守护框架、不锁定厂商——只有 `bash` + `curl` +
`systemd` +（可选）GitHub Actions。

## 问题

instabox 免费层有两条宿主侧硬限，PATCH 一律 `403 spec_not_allowed`，改不了：

| 限制 | 值 | 后果 |
|---|---|---|
| `maxRunMinutes` | 480 | 连续运行 8 小时 → **强制暂停**，随后 5-20 分钟 cooldown，期间所有唤醒路径被拒 |
| `autoSuspendAfterSeconds` | 1800 | 30 分钟无活动 → **idle 暂停** |

而且 guest 内重启**不重置**运行计时——只有宿主侧暂停/恢复才重置
（`runStartedAt` "resets only after confirmed sleep"）。

## 解法：主动周期

自愿 `suspend → resume`：重置 8 小时计时、**无 cooldown 惩罚**、进程原样恢复
（PID 不变）、停机约 90 秒。本套脚本在撞顶之前主动执行这个周期，并能从任何
非运行状态把机器拉回来。

## 架构：五层防御，彼此独立，全都便宜

```
            390 分钟              420 分钟                    480 分钟（永不触及）
              │                    │                           │
   Mac 看门狗 ────►  主动 suspend→resume 周期  ◄──── 机内窗口守卫
   （每 5 分钟，   （重置 runStartedAt，约 90 秒，   （仅当外部恢复器
    主力层）        进程原样恢复）                   确认存活才挂）
              │
              ├──► GitHub Actions keeper（每 15 分钟） —— 终级兜底 wake/resume/start
              ├──► 租约续租（每 25 分钟）            —— 让机器「有任务在跑」
              └──► 单核烧核（常驻，nice 19）         —— 唯一能从内部施加的 anti-idle 信号
```

| 层 | 位置 | 频率 | 脚本 | 职责 |
|---|---|---|---|---|
| 1 Mac 看门狗 | 自己的 Mac | 5 分钟 | `scripts/ib-watchdog.sh` | 390 分钟主动周期；wake + 写心跳；suspended/stopped 自动恢复（单轮 6 次 resume 重试抗 no_capacity） |
| 2 窗口守卫 | guest systemd timer | 10 分钟 | `scripts/run-window-guard.sh` | Mac 不在线时的周期源——**仅当外部恢复器可证实存活**才自我 suspend |
| 3 Actions keeper | 任意 GitHub repo | 15 分钟 | `workflows/keeper.yml` | 终级兜底：wake→resume→start 递降 + 单 tick 4 轮重试 |
| 4 租约续租 | guest cron | 25 分钟 | `scripts/keepalive-lease.sh` | 续租 activity lease（TTL 3600s），机器不进入 idle |
| 5 烧核 | guest systemd | 常驻 | `scripts/keep-awake.sh` | 单核 100%（nice 19）——guest 内能给的最强 idle 反信号 |

另配 `scripts/machine-state-monitor.sh` 做状态取证（仅状态变化时推送，全量时间线入日志）。

## 快速开始

```bash
# 0. 前提：scoped API key（machines:read + machines:write），600 权限存放：
echo 'INSTABOX_API_KEY=...' > ~/.config/instabox-api.env && chmod 600 ~/.config/instabox-api.env
export INSTABOX_MACHINE_ID=m_xxxxxxxx     # 机器 ID 见 instabox 控制台

# 1. Mac 看门狗（主力层）—— crontab：
*/5 * * * * INSTABOX_MACHINE_ID=m_xxxxxxxx $HOME/bin/ib-watchdog.sh
#    ……或者立刻验证一次（不需要 crontab）：
IB_CYCLE_MIN=0 bash scripts/ib-watchdog.sh
#    → 输出「已完成主动休眠-唤醒周期…」且 runStartedAt 翻新 = 通了

# 2. guest 内层（SSH 进机器）：
scp scripts/run-window-guard.sh scripts/keepalive-lease.sh scripts/keep-awake.sh box:~/.local/bin/
#    租约续租：crontab 加 */25 * * * * 一行
#    烧核 + 守卫：systemd/*.service|.timer 拷到 ~/.config/systemd/user/，
#    设好 INSTABOX_MACHINE_ID，systemctl --user enable --now keep-awake run-window-guard.timer
#    （先 loginctl enable-linger $USER）

# 3. 可选 GitHub Actions keeper：workflows/keeper.yml 丢进任意 repo，
#    加 secret INSTABOX_KEEPER_KEY + variable INSTABOX_MACHINE_ID，手动 dispatch 一次。
```

全部通过环境变量配置（`INSTABOX_MACHINE_ID`、`INSTABOX_KEY_ENV`、
`INSTABOX_API_BASE`、日志/锁路径）——任何文件里都不含机器 ID、密钥、个人路径。

## 生产实测基线

看门狗 2026-11-02 15:33（CST）上线至今：**220+ 次执行、4 次主动周期、
0 次撞 480 硬顶、最近 21 小时 0 次 idle 暂停**。唯一两次告警发生在 11-02
16:14 宿主 `no_capacity` 窗口，约 8 分钟后自动恢复。（11-02 07:20 那次
80 分钟强制暂停发生在看门狗上线**之前**——这个仓库就是那次事件的产物。）

## 目录

```
scripts/ib-watchdog.sh           Mac 侧看门狗（macOS + Linux）
scripts/run-window-guard.sh      机内窗口守卫（Linux）
scripts/keepalive-lease.sh       租约续租（Linux）
scripts/keep-awake.sh            单核烧核守护（Linux）
scripts/machine-state-monitor.sh 状态监控 + 取证（Linux）
systemd/                         守卫与烧核的 user 单元
workflows/keeper.yml             GitHub Actions 终级兜底
SKILL.md                         Hermes Agent 技能（部署/运维/排障）
references/architecture.md       为什么是 390/420/480、恢复器存活闸门
references/troubleshooting.md    故障树：撞顶、卡死、密钥轮换
```

## 已知坑（简表）

- 终端输出会**脱敏** key 类字符串（`$INSTABOX_API_KEY` 显示成 `$INSTA...KEY`）。
  规矩：拷贝文件，不重打字节；传完用 `sha256sum` 对。
- 所有 POST **和 PATCH** 都要 `Idempotency-Key` 头（`wake` 除外）。
- `wake` 拉不回**手动** suspend，只能 `resume`。
- resume 撞 `no_capacity` 是平台常态（实测最长 13 分钟）；只有持续 1 小时以上
  才需要人。
- GitHub **定时** workflow 对部分账号实测完全不触发——keeper 当手动/dispatch
  应急层，主力永远是 Mac 看门狗。

## License

MIT — 见 [LICENSE](LICENSE)。
