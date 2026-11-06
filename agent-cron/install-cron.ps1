#requires -Version 5.1
<#
agent-cron 一键安装：装一个"每 15 分钟醒来一次"的心跳计划任务，由它驱动 job 对账（错过也补跑）。

  powershell -ExecutionPolicy Bypass -File install-cron.ps1          # 安装
  powershell -ExecutionPolicy Bypass -File install-cron.ps1 -WhatIf  # 预演
  powershell -ExecutionPolicy Bypass -File install-cron.ps1 -Undo    # 卸载（只删任务，保留 jobs.json）

安装后：
  - 运行时在 %USERPROFILE%\agent-cron（runner / adapters.json / jobs.json / state / logs）
  - 计划任务名：AgentCron-Heartbeat（登录时 + 每 15 分钟，带 StartWhenAvailable）
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [switch]$Undo,
  [switch]$Purge,
  [switch]$NoSkill,
  [int]$IntervalMinutes = 15,
  [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
$TaskName = 'AgentCron-Heartbeat'
$Src = $PSScriptRoot
$Data = if ($Root) { $Root } else { Join-Path $env:USERPROFILE 'agent-cron' }
$Runner = Join-Path $Data 'runner\Invoke-AgentCron.ps1'
$SkillSrc = if (Test-Path (Join-Path $Src 'skills\agent-cron\SKILL.md')) { Join-Path $Src 'skills\agent-cron' } else { $Src }

if ($Undo) {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($TaskName, '删除心跳任务')) {
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
      "removed task: $TaskName"
    }
  } else { "task not found: $TaskName" }
  if ($Purge) {
    if (Test-Path $Data) {
      if ($PSCmdlet.ShouldProcess($Data, '删除运行时目录（含 jobs.json / 历史）')) {
        Remove-Item $Data -Recurse -Force
        "removed: $Data"
      }
    }
  } else {
    "运行数据保留在 $Data（要一起删加 -Purge）"
  }
  return
}

"== 1. 准备运行时目录 =="
if ($PSCmdlet.ShouldProcess($Data, '创建运行时目录并复制 runner')) {
  foreach ($d in @($Data, (Join-Path $Data 'runner'), (Join-Path $Data 'state'), (Join-Path $Data 'logs'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  }
  Copy-Item (Join-Path $Src 'runner\*.ps1') (Join-Path $Data 'runner') -Force
  Copy-Item (Join-Path $Src 'adapters.json') $Data -Force
  if (Test-Path (Join-Path $SkillSrc 'SKILL.md')) { Copy-Item (Join-Path $SkillSrc 'SKILL.md') $Data -Force }
  $jobs = Join-Path $Data 'jobs.json'
  if (-not (Test-Path $jobs)) {
    Copy-Item (Join-Path $Src 'jobs.sample.json') $jobs -Force
    "created: $jobs （示例含 1 个 echo 自检 job，改完再启用真 agent）"
  } else {
    "kept existing: $jobs"
  }
  "runner: $Runner"
}

if (-not $NoSkill -and (Test-Path (Join-Path $SkillSrc 'SKILL.md'))) {
  "`n== 1b. 装技能到已检测到的 agent =="
  $homes = @(
    @{ Home = '.zcode';  Dir = '.zcode\skills' },
    @{ Home = '.agents'; Dir = '.agents\skills' },
    @{ Home = '.claude'; Dir = '.claude\skills' },
    @{ Home = '.codex';  Dir = '.codex\skills' }
  )
  foreach ($h in $homes) {
    if (-not (Test-Path (Join-Path $env:USERPROFILE $h.Home))) { continue }
    $dst = Join-Path (Join-Path $env:USERPROFILE $h.Dir) 'agent-cron'
    if ($PSCmdlet.ShouldProcess($dst, '安装技能目录')) {
      New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
      if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
      if (Test-Path (Join-Path $SkillSrc 'runner')) {
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item (Join-Path $SkillSrc 'SKILL.md') $dst -Force
      } else {
        Copy-Item $SkillSrc $dst -Recurse -Force
      }
      "skill: $dst"
    }
  }
}

"`n== 2. 注册心跳任务（每 $IntervalMinutes 分钟 + 登录时）=="
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Runner`" -Root `"$Data`" -Quiet"
$t1 = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
$t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
  -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3)
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited

if ($PSCmdlet.ShouldProcess($TaskName, '注册心跳任务')) {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($t1, $t2) `
    -Settings $settings -Principal $principal -Description 'agent-cron 心跳：对账到期 job，错过也补跑' -Force | Out-Null
  $t = Get-ScheduledTask -TaskName $TaskName
  "created: $TaskName  StartWhenAvailable=$($t.Settings.StartWhenAvailable)  interval=${IntervalMinutes}min"
}

"`n== 3. 体检各 agent 的无头入口 =="
if ($PSCmdlet.ShouldProcess($Runner, '运行 -Doctor')) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Runner -Doctor -Root $Data
}

"`n== 完成 =="
'接下来：'
'  1) 编辑 ' + (Join-Path $Data 'jobs.json') + '，把示例 job 换成你要的（agent 可填 codex / workbuddy / zcode / dsh）'
'  2) 先手动验一个：powershell -File "' + $Runner + '" -Job <id> -Force'
'  3) 看结果：powershell -File "' + (Join-Path $Data 'runner\Get-AgentCronStatus.ps1') + '"'
'卸载：powershell -File install-cron.ps1 -Undo（加 -Purge 连数据一起删）'
