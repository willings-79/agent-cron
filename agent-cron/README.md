# agent-cron

**给桌面版 agent 的定时任务补上"错过也补跑"。**

Codex / WorkBuddy / ZCode / DSH 的界面内定时只在程序开着时触发，机器关了就静默丢掉。
agent-cron 把任务落到一个 job 文件里，由一个每 15 分钟醒一次的心跳对账执行：**该跑没跑，下次醒来补上**。

```
jobs.json ──► 心跳（计划任务，15min + 登录时）──► runner ──► agent 无头 CLI ──► 日志/状态
```

## 30 秒装上

```powershell
powershell -ExecutionPolicy Bypass -File install-cron.ps1
```

它会：装好运行时到 `%USERPROFILE%\agent-cron`、注册心跳任务 `AgentCron-Heartbeat`、体检各 agent 的无头入口。

## 用一个 job 说话

编辑 `%USERPROFILE%\agent-cron\jobs.json`：

```json
{
  "jobs": [
    { "id": "daily-report", "agent": "codex", "schedule": "daily 09:00",
      "prompt": "扫一遍昨天的提交，写进 reports\\daily.md", "cwd": "D:\\repo",
      "timeoutMin": 20, "maxDelayHours": 24 }
  ]
}
```

立刻验一次（不看时间）：

```powershell
powershell -NoProfile -File "$env:USERPROFILE\agent-cron\runner\Invoke-AgentCron.ps1" -Job daily-report -Force
powershell -NoProfile -File "$env:USERPROFILE\agent-cron\runner\Get-AgentCronStatus.ps1"
```

## 各 agent 的落地方式

| agent | 无头入口 | 状态 |
|---|---|---|
| codex | `codex exec` | ✅ 已验证，复用桌面版登录 |
| workbuddy | `codebuddy -p --port {port}` | ⚠️ 实验性：需一次性 TUI `/login`，与桌面版登录分开 |
| zcode | `zcode -p` | ⚠️ 实验性：需浏览器授权 + TUI `/model` 选模型 |
| dsh | `dsh headless` | ⚠️ 实验性：需 `DEEPSEEK_API_KEY` |

只有 codex 端到端验证过，其余三个是 experimental。一次性登录跑 `login-agents.ps1`（菜单选 1 / 2），脚本会自动设好环境变量和空闲端口。
跑 `Invoke-AgentCron.ps1 -Doctor` 看你机器上哪些能直接用；适配表在 `adapters.json`，加 agent 不用改代码。

## 语义

- 合并补跑：漏三次补一次
- 过期跳过：超过 `maxDelayHours` 不补，防"开机瞬间翻出半年前的活"
- 不并发：上一个没跑完，这一轮跳过（锁里写 PID，持有进程没了才抢占）
- 失败退避：间隔型 job 失败后 15 分钟起、连续失败翻倍，不每轮重试
- 可审计：每次运行写 `logs\<id>-<时间>.log` + `runs.jsonl`
- 假成功防护：`failPattern`（CLI 未登录仍 exit 0）+ `verify`（agent 说完成但产物没生成）
- 隐私：`logRetentionDays` 自动清理、`maxLogKB` 截断、`logContent:false` 只留尾部 30 行

`-Force` 只忽略时间；要跑 `enabled:false` 的 job 加 `-IncludeDisabled`。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File install-cron.ps1 -Undo          # 只删心跳任务
powershell -ExecutionPolicy Bypass -File install-cron.ps1 -Undo -Purge   # 连 jobs/历史一起删
```

MIT
