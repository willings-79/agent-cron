---
name: agent-cron
description: 给 Codex / WorkBuddy / ZCode / DSH 这类桌面版 agent 建"会补跑"的定时任务时必用：任务写进 %USERPROFILE%\agent-cron\jobs.json，由心跳计划任务在对账时执行，错过时间点也会补跑一次。也用于用户问"定时任务没跑/错过了""让 agent 每天自动做某事"。
---

# agent-cron

把"让 agent 每天/每周自动做某件事"落成一个 **job**，而不是一条系统计划任务。
心跳任务每 15 分钟醒来一次，对账哪些 job 到期没跑，补跑最近一次。

## 什么时候用

- 用户说"每天 9 点让 Codex 帮我……""每周五把……""每隔两小时检查……"
- 用户抱怨定时任务"到点没跑""电脑关了就没跑"

不要用应用内自动化（WorkBuddy 自动化、Codex 应用内 Scheduled）：它们只在宿主运行时触发，**没有补跑**。

## 怎么建一个 job

编辑 `%USERPROFILE%\agent-cron\jobs.json`（不存在就先跑一次 `install-cron.ps1`）：

```json
{
  "version": 1,
  "jobs": [
    {
      "id": "daily-report",
      "agent": "codex",
      "schedule": "daily 09:00",
      "prompt": "扫一遍昨天仓库里的提交，把要点写进 reports\\daily.md，5 条以内。",
      "cwd": "D:\\repo",
      "timeoutMin": 20,
      "maxDelayHours": 24
    }
  ]
}
```

字段：

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | 是 | 唯一名，也是状态/日志文件名 |
| `agent` | 是 | `codex` / `workbuddy` / `zcode` / `dsh` / `echo`（自检用） |
| `schedule` | 是 | `daily 09:00`、`weekly mon,fri 20:00`、`every 30m`、`every 2h` |
| `prompt` | 是 | 交给 agent 的完整指令，像对人说话一样写清楚产出与位置 |
| `cwd` | 建议 | agent 的工作目录；不填则用数据目录 |
| `timeoutMin` | 否 | 超时杀掉，默认 20 |
| `maxDelayHours` | 否 | 错过超过 N 小时就不补，默认 24；`0` = 不限 |
| `enabled` | 否 | `false` 暂停 |
| `env` | 否 | 该 job 需要的环境变量（如 DSH 的 `DEEPSEEK_API_KEY`） |

## 语义（写之前必须知道）

- **补跑是合并语义**：错过三次只补最近一次，不连跑三份。
- **错过窗口**：`maxDelayHours` 之外直接跳过，不会翻出很久以前的活儿。
- **登录态**：心跳是 Interactive 任务，锁屏时不跑，登录后才补。
- **同一 job 不并发**：上一轮没跑完，这一轮直接跳过。

## 建完必须验一次

```powershell
powershell -NoProfile -File "$env:USERPROFILE\agent-cron\runner\Invoke-AgentCron.ps1" -Job <id> -Force
powershell -NoProfile -File "$env:USERPROFILE\agent-cron\runner\Get-AgentCronStatus.ps1"
```

`-Force` 会把这次的 exit code、耗时、完整输出写进 `agent-cron\logs\<id>-<时间>.log`；把结果贴给用户看，不要只说"建好了"。

## 排错

- `找不到可执行文件`：跑 `Invoke-AgentCron.ps1 -Doctor`，看该 agent 的 CLI 路径
- DSH 报 `MISSING_CREDENTIAL`：在该 job 的 `env` 里给 `DEEPSEEK_API_KEY`
- WorkBuddy / ZCode 适配是实验性的：先 `-Force` 跑一次确认能出结果，再交给心跳
