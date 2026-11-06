# task-catchup — 定时任务补跑补丁 v0.4.1

**让 AI 给你建的定时任务，错过时间点也会补跑一次。**
关机、休眠、程序没开会错过；下次登录（或唤醒）后，自动把最近漏掉的那次补上（默认日任务补 24h 内、周任务补一周内，可自定）。

## 30 秒装上

在本解压目录执行一次：

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

自动完成：技能装进**已检测到**的 agent 目录（ZCode / Claude Code / Codex / 通用 .agents，没有的不碰）；防丢规则追加进已存在的全局指令（先备份 `*.bak`，按原编码读写）；列出没开补跑的存量任务（`-ApplyExisting` 才写入）。

**桌面版用户**：直接对 WorkBuddy / ZCode / DSH / Codex 桌面版说「帮我运行解压目录里的 install.ps1」，让它替你跑。

**卸载**：`powershell -File install.ps1 -Undo`

## 装完就这么说话

| 你说 | 它会做 |
|---|---|
| 「帮我建个每天早上 9 点的日报任务」 | 建一个带补跑的计划任务 |
| 「检查我的定时任务有没有开补跑」 | 列出没开的存量任务，等你确认 |
| 「把没开补跑的都补上」 | 先给清单，你同意后再写入 |
| 「超过一天的就不补了」 | 只补 24 小时内的（日任务默认就是） |
| 「不限时间，能补就补」 | 补最近一次，不管隔了多久 |

## 常见问题

- **会重复跑吗？** 不会——守卫在 `%USERPROFILE%\catchup-jobs\*.last` 记状态，同一错过只执行一次
- **会翻出多久以前的？** 日任务默认 24h 内、周任务默认一周内；`-MaxDelayHours N` 自定、`0` 不限
- **锁屏算吗？** 不算，登录后才补
- **变卡吗？** 不会，零常驻进程零服务；补跑用的是 Windows 自带机制
- **厂商更新类任务会被改吗？** 默认跳过（名字以 Wps/Nahimic/NIUpdate/360/Adobe 等厂商前缀开头，或以 `Updater` 结尾），要一起改加 `-IncludeVendors`
- **ZCode 市场直达**：插件市场 → Discover → **+** → GitHub 仓库 `willings-79/task-catchup`

## 各家接入

| Agent | 接法 |
|---|---|
| WorkBuddy（wb） | 桌面端技能功能导入 `task-catchup/skills/task-catchup`；或让它跑 install.ps1（其"自动化"无补跑语义） |
| ZCode | 市场源 GitHub `willings-79/task-catchup`，或本地市场添加本目录 |
| DSH | 导入 Skills；CLI 直接跑脚本 |
| Codex | 桌面版让它跑 install.ps1；或技能目录导入；或规则进 `~/.codex/AGENTS.md` |
| Claude Code | `/plugin marketplace add willings-79/task-catchup` |
| 其他（Cursor/Copilot/Gemini CLI） | 支持开放技能格式，复制技能文件夹即可 |

给任意 agent 打补丁的规则文本，见仓库 README「各家 agent 怎么接」一节。

## 脚本

位于 `task-catchup/skills/task-catchup/scripts/`，PowerShell 5.1+：

```powershell
# 建任务（默认补跑窗口：日任务 24h / 周任务 168h；-MaxDelayHours 0 = 不限）
powershell -NoProfile -ExecutionPolicy Bypass -File New-CatchupTask.ps1 -Name "日报" -Run "powershell.exe" -Arguments "-File C:\jobs\report.ps1" -Daily "09:00"

# 批量开补跑（默认 dry-run，-Apply 写入；厂商更新类任务默认跳过，-IncludeVendors 包含）
powershell -NoProfile -ExecutionPolicy Bypass -File Enable-TaskCatchup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File Enable-TaskCatchup.ps1 -Apply
powershell -NoProfile -ExecutionPolicy Bypass -File Enable-TaskCatchup.ps1 -Apply -Name "Wps*" -IncludeVendors
```

## 边界

Windows 脚本 + Linux 规则指引；登录态任务锁屏不补；不补"漏三天跑三次"（合并语义只补最近一次）；应用内 automation 无补跑语义，重要任务落到 Windows 计划任务。MIT License。
