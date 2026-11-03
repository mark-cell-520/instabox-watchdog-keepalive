# 故障树（Troubleshooting）

## 撞了 480 硬顶（强制暂停）

1. **等 cooldown**（5-20 分钟，期间所有唤醒路径被拒，API 直接失败）。
2. cooldown 过后：看门狗下一条（5 分钟内）自动 `resume`（6 轮重试抗
   no_capacity）；或手动：
   ```bash
   curl -s -X POST "https://api.instabox.sh/v1/machines/$INSTABOX_MACHINE_ID/resume" \
     -H "X-API-Key: $INSTABOX_API_KEY" -H "Idempotency-Key: manual-$(date +%s)" -d '{}'
   ```
3. **复盘为什么没周期掉**：看 `~/.cache/instabox-watchdog.log` 找最后一次
   `state=running age=` 的 age 值；age 到过 390 却没周期 = 看门狗停了
   （查 cron）；age 从没到 390 = 机器被外部重启/恢复过（guest reboot 不重置
   计时，但宿主侧操作会）。

## 机器卡在 suspended，resume 一直失败

- 错误含 `no_capacity`：平台常态，重试即可（实测最长 13 分钟）。
  只有持续 1 小时以上才人工看控制台。
- 错误 400 `bad_request`：POST 漏了 `Idempotency-Key` 头。
- 错误 403：key 权限不对（需要 `machines:write`），或免费层锁死项被 PATCH。
- wake 无效：手动 suspend 只能 resume 拉回（"A manual stop/suspend is not
  undone"）。

## 看门狗不周期 / 没动静

1. `tail ~/.cache/instabox-watchdog.log`——没有新行 = cron 没跑
   （查 `crontab -l` / Hermes cron 列表）。
2. 日志有 `state=running age=0min` 且 run 时间每次变 = 有别的恢复器在频繁
   恢复机器（查是否有多台 Mac / 多个 keeper 在跑）。
3. 日志有 `API 无响应` = 网络或 key 问题。
4. 单实例锁：恢复重试可达 10 分钟，5 分钟一跳不并发是设计行为；锁目录
   默认 `~/.cache/ib-watchdog.lock.d`，PID 已死或超 15 分钟自动破锁。

## 机内守卫不自我周期

1. `systemctl --user list-timers | grep run-window-guard` 没有 = timer 没 enable。
2. 日志 `窗口年龄 N 分钟` 停在 < 420 = 看门狗在正常先手，**这是对的**。
3. 日志 `无存活外部恢复器…放弃自我 suspend` = 闸门在工作：Mac 心跳过期
   （看门狗停了 >15 分钟）且 keeper 45 分钟没跑。恢复看门狗即可。
4. 日志 `距上次 suspend 仅 N 分钟（< 360）` = 6 小时频率闸，等平台重设窗口。

## guest 内服务全冻（SSH 能连但没响应）

机器被挂起 = 全部进程冻住。guest 内无解，只能外部拉：
Mac 看门狗（5 分钟内自动）→ keeper dispatch → 控制台 Wake。

## 换 API key（三处同步）

scoped key 常一身三用，吊销 = 三处同时失效：

1. Mac `~/.config/instabox-api.env`（看门狗）
2. guest 同路径（守卫/租约/监控）
3. GitHub repo secret `INSTABOX_KEEPER_KEY`（keeper）

换完按序验证：Mac 手动跑一次看门狗（age 行出现即通）→ guest 跑一次
keepalive-lease.sh（退出码 0 且零输出）→ keeper 手动 dispatch。

## 终端输出脱敏坑（写脚本时）

终端/工具输出会把 `$INSTABOX_API_KEY` 显示成 `$INSTA...KEY`。照抄显示文本
写脚本 = 注入坏变量名，生产环境真的挂过一次。规矩：

- 拷贝文件（scp/cp），不重打字节；
- 跨机传输后 `sha256sum` 两边对一遍；
- 必须手打变量名时，变量名是 `INSTABOX_API_KEY`（完整、无省略号）。

## 已知平台怪癖

- GitHub **scheduled** workflow 对本账号实测 4 小时零运行（active、无
  archived、平台无故障；重注册/2 分钟 cron/真 git push/换文件名四法均无效）。
  手动 dispatch 正常。结论：keeper 只能当应急层，主力是 Mac 看门狗。
- PATCH 机器 metadata 也要 Idempotency-Key，漏了 400。
- `runStartedAt` 只在「确认睡眠」后重置；guest reboot、stop→start 都不重置
  （stop→start 会换新 runStartedAt 但有停机代价，仅 stopped 状态用）。
