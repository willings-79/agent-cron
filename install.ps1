#requires -Version 5.1
<#
task-catchup 一键安装：把技能装进"已检测到"的 agent 技能目录，并给已存在的全局指令追加防丢规则。
  powershell -ExecutionPolicy Bypass -File install.ps1            # 安装
  powershell -ExecutionPolicy Bypass -File install.ps1 -Undo      # 卸载（删技能、按标记删规则）
  powershell -ExecutionPolicy Bypass -File install.ps1 -WhatIf    # 预演
  -NoRules 不写规则；-ApplyExisting 顺带批量修补存量任务。
安全：只对已存在目录/文件动手，不新建 agent 配置；已有指令文件写入前先备份 *.bak，
并按原编码（UTF-8 BOM / 无 BOM UTF-8 / UTF-16 LE / UTF-16 BE / ANSI）读回写回，绝不破坏原有内容。
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [switch]$NoRules,
  [switch]$ApplyExisting,
  [switch]$Undo
)
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'task-catchup\skills\task-catchup'
if (-not (Test-Path (Join-Path $src 'SKILL.md'))) {
  throw "未找到技能目录 $src —— 请在解压后的包根目录（install.ps1 所在目录）运行。"
}

$markerStart = '<!-- task-catchup:start -->'
$ruleText = @'
<!-- task-catchup:start -->
创建定时任务规则：Windows 计划任务必须启用"错过补跑"——优先用本机技能 task-catchup 的 New-CatchupTask.ps1；手工时 PowerShell 用 New-ScheduledTaskSettingsSet -StartWhenAvailable（配合 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries）；schtasks 必须走 /XML 且含 <StartWhenAvailable>true</StartWhenAvailable>。补跑窗口默认：日任务 24h、周任务 168h；用户说"太旧的不补"用 -MaxDelayHours N，"不限时间"用 0。Linux 用 systemd timer Persistent=true 或 anacron，不用裸 cron。调度时间=最早执行时间，错过在下次登录/唤醒立即补跑一次。
<!-- task-catchup:end -->
'@

function Read-TextSmart([string]$Path) {
  # 按字节判编码：UTF-8 BOM / UTF-16 LE(BE) BOM / 严格 UTF-8 可解 / 否则按系统 ANSI(GBK)。
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    return @{ Text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3); Enc = (New-Object System.Text.UTF8Encoding($true)) }
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    return @{ Text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2); Enc = [System.Text.Encoding]::Unicode }
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    return @{ Text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2); Enc = [System.Text.Encoding]::BigEndianUnicode }
  }
  $strict = New-Object System.Text.UTF8Encoding($false, $true)
  try {
    return @{ Text = $strict.GetString($bytes); Enc = (New-Object System.Text.UTF8Encoding($false)) }
  } catch {
    return @{ Text = [System.Text.Encoding]::Default.GetString($bytes); Enc = [System.Text.Encoding]::Default }
  }
}

$skillTargets = @(
  @{ Home = Join-Path $env:USERPROFILE '.zcode';  SkillDir = Join-Path $env:USERPROFILE '.zcode\skills';  Label = 'ZCode' },
  @{ Home = Join-Path $env:USERPROFILE '.agents'; SkillDir = Join-Path $env:USERPROFILE '.agents\skills'; Label = '通用技能目录（.agents，多 agent 共享）' },
  @{ Home = Join-Path $env:USERPROFILE '.claude'; SkillDir = Join-Path $env:USERPROFILE '.claude\skills'; Label = 'Claude Code' },
  @{ Home = Join-Path $env:USERPROFILE '.codex';  SkillDir = Join-Path $env:USERPROFILE '.codex\skills';  Label = 'Codex' }
)
$ruleTargets = @(
  @{ File = Join-Path $env:USERPROFILE '.zcode\AGENTS.md';  Label = 'ZCode 用户指令' },
  @{ File = Join-Path $env:USERPROFILE '.codex\AGENTS.md';  Label = 'Codex 全局指令' },
  @{ File = Join-Path $env:USERPROFILE '.claude\CLAUDE.md'; Label = 'Claude Code 全局指令' }
)

if ($Undo) {
  foreach ($t in $skillTargets) {
    $dst = Join-Path $t.SkillDir 'task-catchup'
    if (Test-Path $dst) {
      if ($PSCmdlet.ShouldProcess($dst, '删除技能目录')) {
        Remove-Item $dst -Recurse -Force
        "removed: $dst"
      }
    }
  }
  foreach ($t in $ruleTargets) {
    if (Test-Path $t.File) {
      $r = Read-TextSmart $t.File
      if ($r.Text.Contains($markerStart)) {
        if ($PSCmdlet.ShouldProcess($t.File, '移除规则块')) {
          if (-not (Test-Path "$($t.File).bak")) { Copy-Item $t.File "$($t.File).bak" }
          $clean = [regex]::Replace($r.Text, [regex]::Escape($markerStart) + '(?s).*?<!-- task-catchup:end -->\r?\n?', '')
          [IO.File]::WriteAllText($t.File, $clean, $r.Enc)
          "rules removed: $($t.Label)"
        }
      }
    }
  }
  'UNDO DONE'
  return
}

"== 安装技能（只装已检测到的 agent，缺目录不硬创建）=="
foreach ($t in $skillTargets) {
  if (-not (Test-Path $t.Home)) {
    "skip（未检测到 $($t.Home)）: $($t.Label)"
    continue
  }
  $dst = Join-Path $t.SkillDir 'task-catchup'
  if ($PSCmdlet.ShouldProcess($dst, '复制技能目录')) {
    New-Item -ItemType Directory -Force -Path $t.SkillDir | Out-Null
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    Copy-Item $src $dst -Recurse -Force
    "installed: $($t.Label) -> $dst"
  }
}

if (-not $NoRules) {
  "== 写入规则（只追加到已存在的全局指令；写入前备份 *.bak，按原编码读写）=="
  foreach ($t in $ruleTargets) {
    if (-not (Test-Path $t.File)) {
      "skip（未找到指令文件，不新建）: $($t.Label)"
      continue
    }
    $r = Read-TextSmart $t.File
    if ($r.Text.Contains($markerStart)) {
      "skip（已有规则）: $($t.Label)"
      continue
    }
    if ($PSCmdlet.ShouldProcess($t.File, '备份并追加规则块')) {
      if (-not (Test-Path "$($t.File).bak")) { Copy-Item $t.File "$($t.File).bak" }
      [IO.File]::WriteAllText($t.File, $r.Text.TrimEnd() + "`r`n`r`n" + $ruleText + "`r`n", $r.Enc)
      "rules written: $($t.Label)"
    }
  }
}

$enable = Join-Path $PSScriptRoot 'task-catchup\skills\task-catchup\scripts\Enable-TaskCatchup.ps1'
"`n== 存量任务检查 =="
& $enable
if ($ApplyExisting -and $PSCmdlet.ShouldProcess('存量计划任务', '批量开启补跑')) {
  & $enable -Apply
}

"`n== 完成 =="
'新开会话后，对任意已装 agent 说「帮我建个每天 9 点的定时任务」即可。'
'ZCode 用户也可：插件市场 → Discover → + → 添加 GitHub 仓库 willings-79/task-catchup。'
'卸载：powershell -File install.ps1 -Undo'
