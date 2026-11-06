---
name: task-catchup
description: 创建任何定时任务（Windows 计划任务 / cron / systemd timer / 应用内定时）时必用：启用"错过补跑"，错过时间点后在下次登录或唤醒时立即补跑。也用于用户反馈"定时任务没跑/错过了"。Use whenever creating scheduled tasks, cron jobs or timers, or when the user reports a missed task that never ran.
---

# 定时任务补跑补丁（Task Catch-up）

核心规则：**调度时间 = 最早可执行时间，不是唯一时间点**。错过（关机/休眠/程序未运行）后，在下次登录或唤醒时立即补跑一次（Interactive 权限的任务在锁屏阶段不会启动，所以准确说是"登录后"）。

## Windows 计划任务（优先用本技能自带脚本）

脚本在本技能目录的 `scripts/` 下（与 SKILL.md 同级）：

- 新建带补跑的任务：
  `powershell -NoProfile -ExecutionPolicy Bypass -File <技能目录>\scripts\New-CatchupTask.ps1 -Name "日报" -Run "powershell.exe" -Arguments "-File C:\jobs\report.ps1" -Daily "09:00"`
  触发器可选：`-Daily "09:00"`、`-Weekly Monday,Friday -WeeklyAt "20:00"`、`-Hourly 2`、`-AtLogon`、`-AtStartup`；`-Wake` 附带睡眠唤醒；`-Force` 覆盖同名任务；**`-MaxDelayHours N` 可选补跑窗口**——错过超过 N 小时就不再补（生成守卫脚本于 `%USERPROFILE%\catchup-jobs\`，由任务实际调用），防止陈旧任务开机突袭；不传 = 默认窗口（日任务 24h、周任务 168h），`-MaxDelayHours 0` 才是总是补跑。用户提出"不想补太久之前的任务"时用它。**默认补跑窗口：日任务 24 小时、周任务 168 小时（一周）**，建任务时不必主动问；用户说"太旧的不补/只补 X 天内"用 `-MaxDelayHours N`（48=两天），用户说"不限时间、能补就补"用 `-MaxDelayHours 0`。`-MaxDelayHours` 仅支持 `-Daily`/`-Weekly`（与 `-Hourly`/`-AtLogon`/`-AtStartup` 组合会 throw）；守卫经 `ProcessStartInfo` 原样传参（参数含 `&`、`$` 等不受 PowerShell 二次解析影响），并自动记录 `<任务名>.last` 状态，同一次错过只执行一次。**`-Run` 必须是可执行文件（.exe/.bat/.cmd）**，不要直接传 .ps1——跑 PowerShell 脚本写成 `-Run powershell.exe -Arguments "-File C:\path\x.ps1"`。注意：`-AtStartup`（boot 触发器）必须管理员运行，非提权会 throw；`-AtLogon` 绑定当前用户、非提权可用。
- 批量给已有任务开启补跑：
  `powershell -NoProfile -ExecutionPolicy Bypass -File <技能目录>\scripts\Enable-TaskCatchup.ps1`（默认 dry-run 只列出；加 `-Apply` 才写入；只处理非 `\Microsoft\` 任务，`-Name` 支持通配）。默认跳过**厂商更新类**任务（名字以厂商前缀开头如 Wps/Nahimic/NIUpdate/360/Adobe，或以 `Updater` 结尾）——这些任务的补跑没有意义；用户明确要一起改时加 `-IncludeVendors`。

手工执行要点（不用脚本时）：
- PowerShell：`New-ScheduledTaskSettingsSet -StartWhenAvailable`，通过 `Register-ScheduledTask -Settings` 应用；改已有任务：`$t = Get-ScheduledTask -TaskName X; $t.Settings.StartWhenAvailable = $true; $t | Set-ScheduledTask`。
- **`schtasks /create` 没有这个参数**，必须走 `/XML` 且 Settings 里含 `<StartWhenAvailable>true</StartWhenAvailable>`。不要用裸 schtasks 建任务。
- 行为：错过多天也只补跑一次（合并语义），休眠唤醒同样触发。守卫模式（-MaxDelayHours）已内置 `<任务名>.last` 状态文件防重复；无窗口模式下若同一任务会被多个触发器（如 Daily+AtLogon）拉起，需要在脚本里自行加状态文件防重复。

## Linux

- systemd timer：`[Timer]` 加 `Persistent=true`（配合 OnCalendar），错过开机自动补跑。
- 不要用裸 cron；用 anacron 或迁移到 systemd timer。

## 应用内 / 对话内定时（如 CronCreate 建的自动化）

只在宿主程序运行时才会触发，**没有补跑语义**（各桌面 Agent 的自动化功能同理，如 WorkBuddy 的"自动化"）。需要补跑保证的任务一律落到 OS 调度器，不要建在应用内。

## 给没有技能系统的 agent 打补丁

把下面规则写进其全局指令文件（Codex: `~/.codex/AGENTS.md`；Claude Code: `~/.claude/CLAUDE.md`；其他 agent 同理）：

> 创建定时任务规则：Windows 计划任务必须启用"错过补跑"——PowerShell 用 `New-ScheduledTaskSettingsSet -StartWhenAvailable`；`schtasks` 必须走 `/XML` 且包含 `<StartWhenAvailable>true</StartWhenAvailable>`。Linux 用 systemd timer `Persistent=true` 或 anacron，不用裸 cron。调度时间=最早执行时间，错过（关机/休眠）后在下次开机/唤醒时立即补跑一次。
