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
| **Codex** | `codex exec` | ✅ 实测通过，复用桌面版登录，无需 API key |
| **WorkBuddy** | `codebuddy -p --port <空闲端口>` | ⚠️ 要一次性 `codebuddy /login`（和桌面版登录分开）；未登录时它 exit 0 但不出结果，本工具按输出里的 `Authentication required` 判失败 |
| **ZCode** | `zcode -p` | ⚠️ 两处：CLI 找 `resources\glm\provider\`（实际在 `resources\config\provider\`，本机已补）；还缺一次 `zcode login` + 在 TUI 里选模型（CLI 没有 `--model` 参数） |
| **DSH** | `dsh headless` | ⚠️ 需要 `DEEPSEEK_API_KEY`，写进 job 的 `env` |

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
