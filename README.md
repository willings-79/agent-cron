# agent-cron

**给桌面版 AI agent 的定时任务，补上「错过也补跑」。**

Codex / WorkBuddy / ZCode / DSH 里的定时只在程序开着时触发：机器关了、睡了，那一轮就静默丢掉。
agent-cron 把任务写进一个 `jobs.json`，由一个每 15 分钟醒一次的心跳**对账**执行——该跑没跑，下次醒来补上最近一次。

```
jobs.json ──► 心跳（计划任务 / 15min + 登录）──► runner ──► agent 无头 CLI ──► logs + runs.jsonl
```

## 它不是又一个 cron

普通 cron 与各家应用内定时只回答「到点有没有触发」，agent-cron 回答的是「**这件活最该做的那次，做了没有**」：

- 补跑是**合并语义**：错过三次只补一次，不会开机连跑三份
- 有**过期窗口**：超过 `maxDelayHours` 直接跳过，不会翻出半年前的活
- 每次运行都有 **exit code / 耗时 / 完整输出**，落在 `logs\<job>-<时间>.log`
- 同一 job 不并发：上一轮没跑完，这一轮跳过

### 它按"不可信"来设计

| 问题 | 做法 |
|---|---|
| CLI 没登录却 `exit 0` | `failPattern` 命中输出里的关键字 → 判 78，不记成功 |
| agent 说跑完了，产物没生成 | `verify` 命令：agent 退出 0 之后还要过校验，否则判 79 |
| 任务越跑越久、锁住别的轮次 | 锁里写 PID，只有持有进程真的没了才抢占（不靠猜时间） |
| 失败后每 15 分钟重试烧额度 | 间隔型 job 失败退避：15 分钟起，连续失败翻倍 |
| 一个 job 要求只读，另一个要写 | `sandbox` 必须由适配表声明支持；不支持就跳过，不静默降级 |
| 日志里有私有代码 | `logRetentionDays` 自动清理、`maxLogKB` 截断、`logContent:false` 只留尾部 30 行 |
| 开机后首次心跳被系统掐断 | 任务级 `RestartOnFailure`（3 次 / 1 分钟）+ 登录后延迟 30 秒 + `state\<id>.inflight` 标记，下次心跳识别为 `interrupted` |

### 真机上验过：关机跨过执行时间，开机后补上了

2026-11-06 16:42 到期的两个 job，机器正在重启；16:45:38 登录后心跳自动补跑。

| 证据 | 值 |
|---|---|
| `proof-echo.txt` 修改时间 | 16:37:40 → **16:45:46**（开机后重写，不是原来那份） |
| `runs.jsonl` | `due=16:42:00 / reason=catchup / exit=0` |
| 心跳任务 `LastRunTime` | 16:45:38 —— `StartWhenAvailable` 补上了错过的触发 |
| 16:53 那次正常心跳 | `Result=0`，没有重复执行（`.last`/state 已推进） |

## 30 秒装上

```powershell
powershell -ExecutionPolicy Bypass -File install-cron.ps1
```

三件事：装运行时到 `%USERPROFILE%\agent-cron`、注册心跳任务 `AgentCron-Heartbeat`、把技能装进本机已有的 agent（`~/.zcode`、`~/.claude`、`~/.codex`、`~/.agents`，没有的不碰）。

装完先体检，看这台机器上哪些 agent 能直接无头跑：

```powershell
powershell -NoProfile -File "$env:USERPROFILE\agent-cron\runner\Invoke-AgentCron.ps1" -Doctor
```

## 写一个 job

编辑 `%USERPROFILE%\agent-cron\jobs.json`：

```json
{
  "jobs": [
    {
      "id": "daily-report",
      "agent": "codex",
      "schedule": "daily 09:00",
      "prompt": "扫一遍昨天仓库里的提交，把要点写进 reports\\daily.md，5 条以内。",
      "cwd": "D:\\repo",
      "timeoutMin": 20,
      "maxDelayHours": 24,
      "sandbox": "workspace-write",
      "verify": "if not exist reports\\daily.md exit 1"
    }
  ]
}
```

`schedule` 支持 `daily 09:00`、`weekly mon,fri 20:00`、`every 30m`、`every 2h`。

立刻验一次（不看时间），再交给心跳：

```powershell
$runner = "$env:USERPROFILE\agent-cron\runner"
powershell -File "$runner\Invoke-AgentCron.ps1" -Job daily-report -Force
powershell -File "$runner\Get-AgentCronStatus.ps1"
```

## 各 agent 的现状（别当全都即插即用）

| agent | 无头入口 | 现状 |
|---|---|---|
| **Codex** | `codex exec` | ✅ 唯一端到端实测通过：复用桌面版登录，无需 API key，装完就能用 |
| **WorkBuddy** | `codebuddy -p --port {port}` | ⚠️ 需一次性 TUI 登录，**未端到端验证** |
| **ZCode** | `zcode -p` | ⚠️ 需一次性浏览器授权 + TUI 选模型，**未端到端验证** |
| **DSH** | `dsh headless` | ⚠️ 需要 `DEEPSEEK_API_KEY`，写进 job 的 `env`，**未端到端验证** |

**说清楚**：`verified` 目前只有 `codex` 和自检用的 `echo`。其余三个都是 `experimental`——适配表能把命令拼对、把明显失败（未登录、缺模型、缺 key、`Cannot find module`、`EADDRINUSE`）判成失败，但都还没有跑通过一次真实任务。别把它们当即插即用。

WorkBuddy 这边有三个坑（v0.6.2 已修前两个）：

- 该发行版 `cli\dist\` 只有 `codebuddy-lite-wb.mjs`，默认入口去找完整版 bundle，直接 `Cannot find module '../dist/codebuddy'`。适配表已注入 `CODEBUDDY_FORCE_LITE_WB_BUNDLE=1` 强制走 lite-wb。
- 桌面版常驻占着 `127.0.0.1:55298`，不带 `--port` 会 `EADDRINUSE` 后静默退出。runner 用 `{port}` 每次自动取空闲端口。
- `/login` 是 TUI 里的斜杠命令，**不是**命令行参数；写成 `codebuddy /login` 会什么都不做。

### 一次性登录（只有 WB / ZCode 需要）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\agent-cron\login-agents.ps1"
```

菜单选 1（WorkBuddy）或 2（ZCode）。脚本自动设环境变量、找空闲端口、拉起对应 CLI，你只需在界面里输 `/login` 或 `/model`，并在浏览器点一次同意。它不替你授权、不常驻、不改系统配置。只用 Codex 的话整段跳过。

跑 `-Doctor` 会逐条告诉你缺什么。适配表在 `adapters.json`，加新 agent 不用改代码。

## 安装（市场 / 手动）

- **ZCode**：插件市场 → Discover → `+` → 仓库 `willings-79/agent-cron`
- **Claude Code**：`/plugin marketplace add willings-79/agent-cron`
- **Codex / WorkBuddy / DSH**：把 `agent-cron/skills/agent-cron` 复制进各自技能目录，或直接跑 `install-cron.ps1`
- **不用 agent**：`install-cron.ps1` 装好一切，你只编辑 `jobs.json`

## 边界

- 心跳是 Windows 计划任务（登录态运行）：**锁屏不跑，登录后补**；Linux 可用 cron/systemd 定时调 runner，但未打包
- 只在**当前用户**下运行，不涉及提权
- 不联网、不收集数据；日志全在你本机

## 旧版说明

这个仓库原名 **task-catchup**（v0.4.1 及以前）：那是一个「让 Windows 计划任务错过补跑」的补丁，靠生成守卫脚本 + `.last` 去重。
它已被 agent-cron 的对账模型取代，旧版本仍可从 Releases 下载；`extras/enable-catchup.ps1` 保留了当年「给已有计划任务一键开启 `StartWhenAvailable`」的小工具。

## License

MIT
