# instabox-watchdog-keepalive

[中文](README.zh.md) | English

Five shell scripts that keep a **free-tier [instabox](https://instabox.sh) machine
running 24/7**, verified in production since 2026-11-02. No agent, no daemon
framework, no vendor lock-in — just `bash` + `curl` + `systemd` + (optionally)
GitHub Actions.

## The problem

The instabox free tier has two host-side hard limits you cannot change
(both return `403 spec_not_allowed` on PATCH):

| Limit | Value | Consequence |
|---|---|---|
| `maxRunMinutes` | 480 | 8h of continuous runtime → **forced suspend** + 5–20 min cooldown where every wake path is refused |
| `autoSuspendAfterSeconds` | 1800 | 30 min without activity → **idle suspend** |

And rebooting inside the guest does **not** reset the run timer — only a
host-side suspend/resume does (`runStartedAt` *"resets only after confirmed sleep"*).

## The solution: a voluntary cycle

`suspend → resume` resets the 8-hour timer with **no cooldown penalty**, restores
every process untouched (same PIDs), and costs about 90 seconds of downtime.
The suite below schedules that cycle *before* the cap, and recovers the machine
from every non-running state.

## Architecture — five layers, cheap and independent

```
            390 min              420 min                    480 min (never reached)
              │                    │                           │
   Mac watchdog ──►  proactive suspend→resume cycle  ◄── in-guest window guard
   (every 5 min,     (resets runStartedAt, ~90 s,       (only if an external
    primary)         processes preserved)                resumer is ALIVE)
              │
              ├──► GitHub Actions keeper (every 15 min)  — last-resort wake/resume/start
              ├──► activity-lease renewal (every 25 min) — keeps the box "busy"
              └──► one-core burner (always on, nice 19)  — anti-idle CPU signal
```

| Layer | Where | Cadence | Script | Job |
|---|---|---|---|---|
| 1 Mac watchdog | your own Mac | 5 min | `scripts/ib-watchdog.sh` | proactive cycle at 390 min; wake + heartbeat; auto-recover from suspended/stopped (6 in-run resume retries against `no_capacity`) |
| 2 Window guard | guest systemd timer | 10 min | `scripts/run-window-guard.sh` | cycle source when the Mac is offline — self-suspends **only if an external resumer is verifiably alive** |
| 3 Actions keeper | any GitHub repo | 15 min | `workflows/keeper.yml` | last resort: wake→resume→start descending + 4 retries per tick |
| 4 Lease renewal | guest cron | 25 min | `scripts/keepalive-lease.sh` | renews activity lease (TTL 3600 s) so the box never looks idle |
| 5 Core burner | guest systemd | always | `scripts/keep-awake.sh` | one core at 100% (nice 19) — the only idle signal you control from inside |

Plus `scripts/machine-state-monitor.sh` for forensics (pushes only on state
change; full timeline to log).

## Quick start

```bash
# 0. Prerequisites: a scoped API key (machines:read + machines:write), stored 600:
echo 'INSTABOX_API_KEY=...' > ~/.config/instabox-api.env && chmod 600 ~/.config/instabox-api.env
export INSTABOX_MACHINE_ID=m_xxxxxxxx     # from the instabox console

# 1. Mac watchdog (the primary layer) — crontab:
*/5 * * * * INSTABOX_MACHINE_ID=m_xxxxxxxx $HOME/bin/ib-watchdog.sh
#    …or prove it right now with a forced cycle (no crontab needed):
IB_CYCLE_MIN=0 bash scripts/ib-watchdog.sh
#    → "已完成主动休眠-唤醒周期…" and a fresh runStartedAt = working

# 2. Guest layers (inside the box, via SSH):
scp scripts/run-window-guard.sh scripts/keepalive-lease.sh scripts/keep-awake.sh box:~/.local/bin/
#    lease renewal: */25 * * * * crontab entry
#    burner + guard: copy systemd/*.service|.timer to ~/.config/systemd/user/,
#    set INSTABOX_MACHINE_ID, systemctl --user enable --now keep-awake run-window-guard.timer
#    (loginctl enable-linger $USER first)

# 3. Optional GitHub Actions keeper: drop workflows/keeper.yml into any repo,
#    add secret INSTABOX_KEEPER_KEY + variable INSTABOX_MACHINE_ID, dispatch once.
```

Everything is configured through environment variables (`INSTABOX_MACHINE_ID`,
`INSTABOX_KEY_ENV`, `INSTABOX_API_BASE`, log/lock paths) — no machine ID, key,
or personal path is baked into any file.

## Production baseline

Watchdog online since 2026-11-02 15:33 (CST): **220+ executions, 4 proactive
cycles, 0 hits on the 480-min cap, 0 idle suspends** in the last 21 hours.
The only alerts were two lines during a host `no_capacity` window on 11-02
16:14; the box auto-recovered ~8 minutes later. (The 80-minute forced suspend
at 11-02 07:20 happened *before* the watchdog existed — that incident is why
this repo exists.)

## Layout

```
scripts/ib-watchdog.sh           Mac-side watchdog (macOS + Linux)
scripts/run-window-guard.sh      in-guest window guard (Linux)
scripts/keepalive-lease.sh       activity-lease renewal (Linux)
scripts/keep-awake.sh            one-core burner daemon (Linux)
scripts/machine-state-monitor.sh state-change monitor + forensics (Linux)
systemd/                         user units for guard + burner
workflows/keeper.yml             GitHub Actions last-resort keeper
SKILL.md                         Hermes Agent skill (deploy/runbook/troubleshoot)
references/architecture.md       why 390/420/480, the resumer-liveness gate
references/troubleshooting.md    fault tree: capped, stuck, key rotation
```

## Known pitfalls (short list)

- Terminal output **redacts key-like strings** (`$INSTABOX_API_KEY` shows as
  `$INSTA...KEY`). Copy files, never retype bytes; verify with `sha256sum`.
- Every POST **and PATCH** needs an `Idempotency-Key` header (except `wake`).
- `wake` cannot undo a *manual* suspend — only `resume` can.
- `no_capacity` on resume is normal platform behavior (observed up to 13 min);
  only a continuous 1h+ failure needs a human.
- GitHub **scheduled** workflows were observed not firing at all for some
  accounts — treat the keeper as a manual/dispatch layer; the Mac watchdog is
  the primary.

## License

MIT — see [LICENSE](LICENSE).
