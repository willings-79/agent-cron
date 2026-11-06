# task-catchup

**让 AI 给你建的定时任务，错过时间点也会补跑一次。**

关机、休眠、程序没开会错过；下次登录（或唤醒）后，它会自己把最近漏掉的那次补上。

[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![platform](https://img.shields.io/badge/platform-Windows%2010%2F11-lightgrey.svg)](#边界与限制)
[![powershell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](#直接用脚本)
[![version](https://img.shields.io/badge/version-0.4.1-green.svg)](https://github.com/willings-79/task-catchup/releases)

---

## 你可能正被这件事坑着

- 每天早上 9 点的日报，**那天你 10 点才开机**——它就当没这回事，一天的数据空白。
- 每周五晚的备份，**周五你合盖休眠了**——周六打开电脑，备份没跑，你下周才发现。
- 让 AI 帮你建的提醒 / 汇总 / 巡检，**它只负责建**；机器不在那个点开着，任务静默消失，没有任何报错。

不是你的错。AI agent 建定时任务基本都用 `schtasks /create` 或裸 cron，这两种方式**天生没有"补跑"这个开关**——到点没跑就是没跑，不重试、不提醒、不补。

## 它做的事，一句话

**调度时间 = 最早可执行时间，不是唯一时间点。**

```
09:00  任务该跑   → 机器关着，错过
10:20  你开机     → task-catchup 发现"今天 09:00 那次没跑"，立刻补上一次
次日09:00         → 照常
```

补的是**最近漏掉的那一次**，不会因为漏了三天就连跑三份。

## 30 秒装上

```powershell
# 解开 Release 里的 zip，在解压目录执行一次：
powershell -ExecutionPolicy Bypass -File install.ps1
```

它会自动做完三件事：

1. 把技能拷进**已检测到**的 agent 目录：`~/.zcode/skills`、`~/.agents/skills`、`~/.claude/skills`、`~/.codex/skills`（哪个 agent 在本机装过就装哪个，没有的不碰）
2. 把一段带标记的"防丢规则"**追加**进已存在的 `~/.zcode/AGENTS.md`、`~/.codex/AGENTS.md`、`~/.claude/CLAUDE.md`（没有该文件就不动；写入前自动备份 `*.bak`，按原编码读写，绝不弄乱你已有的内容）
3. 列出你机器上还没开补跑的存量任务（只列出，不动手；`-ApplyExisting` 才写入）

装完**新开一个会话**才生效（技能是会话启动时加载的）。

> 桌面版用户不想碰终端：直接对桌面版 agent 说「帮我运行解压目录里的 install.ps1」，它会替你把上面几步跑完。

**验收**：任务计划程序 → 任意新建任务 → 属性 → 设置 → 勾上了"错过计划开始后尽快启动"。

**卸载**：`powershell -File install.ps1 -Undo`（按标记删规则、删技能目录）

## 装完就这么说话

不用记参数，对 agent 说人话就行：

| 你说 | 它会做 |
|---|---|
| 「帮我建个每天早上 9 点的日报任务」 | 建一个带补跑的计划任务 |
| 「检查我的定时任务有没有开补跑」 | 列出没开的存量任务，等你确认 |
| 「把没开补跑的都补上」 | 先给清单，你同意后再写入 |
| 「超过一天的就不补了」 | 只补 24 小时内的（日任务默认就是） |
| 「不限时间，能补就补」 | `-MaxDelayHours 0`，补最近一次，不管隔了多久 |

## 常见问题

**会不会重复跑？**
不会。每次错过只执行一次，守卫脚本会在 `%USERPROFILE%\catchup-jobs\*.last` 记下"这次已跑过"。同一时间点的第二次触发会被跳过。

**会把多久以前的任务翻出来？**
日任务默认只补 **24 小时内**的；周任务默认 **一周（168 小时）**——再宽就 `-MaxDelayHours 48`，要无限就 `0`。这个默认值就是为了防"开机瞬间十几个陈旧任务一起炸"。

**关机三天，开机补三次？**
不。合并成一次，补最近那次。

**锁屏算不算？**
不算。任务以你的账号登录态运行（Interactive），**登录之后**才会启动；开机停在锁屏界面不会补，登录后立刻补。

**怎么知道它到底跑没跑？**
看两处：任务计划程序里的"上次运行时间/上次结果"，和 `%USERPROFILE%\catchup-jobs\` 下对应任务的 `.last`（内容就是上次补跑的时间点）。守卫失败会以非零退出码结束，任务状态会显示为失败，不会假装成功。

**Linux 呢？**
只给规则，没有脚本：systemd timer 加 `Persistent=true`，或用 anacron；别用裸 cron。

**会让电脑变卡吗？**
不会。零常驻进程、零后台服务——装完只是几个静态文件加一段规则文本。补跑用的是 Windows 任务计划程序自带机制，唯一开销是"错过的任务真的补跑一次"时任务自身的运行。

## 各家 agent 怎么接

`install.ps1` 已经覆盖了大部分；下面是你可能想手动做的。

| Agent | 接法 |
|---|---|
| **WorkBuddy（wb）** | 桌面端"技能"功能导入自定义技能（`task-catchup/skills/task-catchup`）；或让 agent 直接跑 `install.ps1`。它自带的"自动化"无补跑语义，别建在那里 |
| **ZCode** | 插件市场 → Discover → `+` → 仓库 `willings-79/task-catchup`；或本地包：插件市场 → 添加插件市场 → 粘贴解压目录 → `task-catchup-market` → 安装 |
| **DSH**（DeepSeek Harness） | 导入 Skills（桌面端/CLI 均有技能体系）；CLI 形态直接跑脚本最省事 |
| **Codex**（桌面/CLI/IDE） | 桌面版直接让它跑 `install.ps1`；已支持 Skills：把 `task-catchup/skills/task-catchup` 放进技能目录；或把规则粘进 `~/.codex/AGENTS.md` |
| **Claude Code** | `/plugin marketplace add willings-79/task-catchup` → `/plugin install task-catchup@task-catchup` |
| **Cursor / Copilot / Gemini CLI** | 支持开放 Agent Skills 格式，放进各自技能目录即可 |
| **没有 agent** | 直接跑下节的 PowerShell |

不想装技能、只想给任意 agent 打补丁？把这段塞进它的全局指令文件：

> 创建定时任务规则：Windows 计划任务必须启用"错过补跑"——优先用本机 `New-CatchupTask.ps1`；手工时用 `New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries`；`schtasks` 必须走 `/XML` 且含 `<StartWhenAvailable>true</StartWhenAvailable>`。补跑窗口默认日任务 24h、周任务 168h；用户说"太旧的不补"加 `-MaxDelayHours N`，"不限"用 0。Linux 用 systemd timer `Persistent=true` 或 anacron，不用裸 cron。调度时间=最早执行时间，错过在下次登录/唤醒时补跑一次。

## 直接用脚本

PowerShell 5.1+（Win10/11 自带），脚本在 `task-catchup/skills/task-catchup/scripts/`。

```powershell
# 建任务：触发器 -Daily / -Weekly+-WeeklyAt / -Hourly / -AtLogon / -AtStartup 任选
# -Wake 顺带把机器从睡眠叫醒；-MaxDelayHours 0 = 不限补跑窗口
powershell -NoProfile -ExecutionPolicy Bypass -File New-CatchupTask.ps1 `
  -Name "日报" -Run "powershell.exe" -Arguments "-File C:\jobs\report.ps1" -Daily "09:00"

# 批量给存量任务开补跑：默认只列出，-Apply 才写；第三方更新类任务（名字含 Updater/Update/LogonTask）默认跳过，-IncludeVendors 包含
powershell -NoProfile -ExecutionPolicy Bypass -File Enable-TaskCatchup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File Enable-TaskCatchup.ps1 -Apply -Name "Wps*" -IncludeVendors
```

参数速查：

| 参数 | 说明 |
|---|---|
| `-Daily "09:00"` | 每天 |
| `-Weekly Monday,Friday -WeeklyAt "20:00"` | 每周指定几天 |
| `-Hourly 2` | 每 2 小时（从创建时刻起算） |
| `-AtLogon` / `-AtStartup` | 登录 / 开机触发（后者需管理员） |
| `-MaxDelayHours N` | 只补 N 小时内的错过；`0` = 不限。默认：日任务 24、周任务 168 |
| `-Wake` | 允许唤醒机器来跑 |
| `-Force` | 覆盖同名任务 |

`-MaxDelayHours` 只对 `-Daily` / `-Weekly` 有效：`-Hourly` 的锚点和整点对不齐，`-AtLogon` / `-AtStartup` 没有"错过"的概念，传了会直接报错而不是悄悄失效。

## 边界与限制

- Windows 才有脚本；Linux 部分只是规则指引
- 任务是"当前用户 + 登录态"运行，**登录后**才补，锁屏不补；给系统级/别人的任务改设置要管理员
- 补跑看的是"最近一次错过"，不做"漏三天补三天"
- 各 agent 对话里建的自动化（以及在应用内跑的定时）**只在宿主程序运行时触发**，没有补跑语义——需要保证的，让它落到 Windows 计划任务
- WorkBuddy / DSH / Codex 的市场收录按各家流程另走；当前用 `install.ps1` 即装即用
- `~/.codex/skills` 的技能目录约定未在全部版本实测

## License

MIT
