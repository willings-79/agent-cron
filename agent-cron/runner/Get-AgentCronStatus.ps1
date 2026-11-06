#requires -Version 5.1
<#
Agent Cron 状态查看：
  Get-AgentCronStatus.ps1               # 每个 job 一行：计划 / 上次成功 / 上次结果 / 下次该跑
  Get-AgentCronStatus.ps1 -History 10  # 最近 10 次运行记录
  Get-AgentCronStatus.ps1 -Log daily   # 看某个 job 最近一次的完整日志尾部
#>
[CmdletBinding()]
param(
  [string]$Root = '',
  [int]$History = 0,
  [string]$Log = '',
  [int]$Tail = 40
)

$ErrorActionPreference = 'Stop'
$DataDir = if ($Root) { $Root } elseif ($env:AGENT_CRON_HOME) { $env:AGENT_CRON_HOME } else { Join-Path $env:USERPROFILE 'agent-cron' }
$ConfigPath = Join-Path $DataDir 'jobs.json'
$StateDir = Join-Path $DataDir 'state'
$RunLog = Join-Path $DataDir 'runs.jsonl'
$LogDir = Join-Path $DataDir 'logs'

if (-not (Test-Path $ConfigPath)) { "没有 jobs.json：$ConfigPath"; return }

$DayMap = @{ mon = 'Monday'; tue = 'Tuesday'; wed = 'Wednesday'; thu = 'Thursday'; fri = 'Friday'; sat = 'Saturday'; sun = 'Sunday' }

function Get-NextDue([string]$schedule, [datetime]$now, $lastSuccess) {
  $s = $schedule.Trim().ToLower()
  if ($s -match '^daily\s+(\d{1,2}):(\d{2})$') {
    $occ = $now.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
    if ($occ -le $now) { $occ = $occ.AddDays(1) }
    return $occ
  }
  if ($s -match '^weekly\s+([a-z,]+)\s+(\d{1,2}):(\d{2})$') {
    $names = @()
    foreach ($d in $Matches[1].Split(',')) { $k = $d.Trim(); if ($DayMap.ContainsKey($k)) { $names += $DayMap[$k] } elseif ($k) { $names += $k } }
    for ($i = 1; $i -le 8; $i++) {
      $day = $now.Date.AddDays($i)
      $occ = $day.AddHours([int]$Matches[2]).AddMinutes([int]$Matches[3])
      if ($names -contains $day.DayOfWeek.ToString()) { return $occ }
    }
    return $null
  }
  if ($s -match '^every\s+(\d+)\s*([hm])$') {
    $n = [int]$Matches[1]; $unit = $Matches[2]
    $span = if ($unit -eq 'h') { [TimeSpan]::FromHours($n) } else { [TimeSpan]::FromMinutes($n) }
    if ($lastSuccess) { return ([datetime]$lastSuccess + $span) }
    return $now
  }
  return $null
}

$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$now = Get-Date

if ($Log) {
  $latest = Get-ChildItem $LogDir -Filter "$Log-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $latest) { "没有 $Log 的日志"; return }
  "== $($latest.Name)  ($($latest.LastWriteTime)) =="
  Get-Content $latest.FullName -Tail $Tail
  return
}

if ($History -gt 0) {
  if (-not (Test-Path $RunLog)) { "还没有运行记录"; return }
  $rows = Get-Content $RunLog -Encoding UTF8 | Select-Object -Last $History | ForEach-Object {
    try { $_ | ConvertFrom-Json } catch { }
  }
  $i = 0
  foreach ($r in $rows) {
    $i++
    "{0,3}. {1}  {2,-18} {3,-10} {4,-11} exit={5,-4} {6,6:N1}s  {7}" -f $i, ([datetime]$r.ts).ToString('MM-dd HH:mm'), $r.id, $r.agent, $r.reason, $r.exit, ($r.ms / 1000), (Split-Path $r.log -Leaf)
  }
  return
}

"== agent-cron @ $DataDir =="
"{0,-18} {1,-10} {2,-16} {3,-18} {4,-7} {5,-6} {6}" -f 'JOB', 'AGENT', 'SCHEDULE', 'LAST SUCCESS', 'EXIT', 'FAILS', 'NEXT DUE'
foreach ($j in @($cfg.jobs)) {
  if (-not $j.id) { continue }
  $sp = Join-Path $StateDir "$($j.id).json"
  $st = if (Test-Path $sp) { Get-Content $sp -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
  $lastOk = if ($st -and $st.lastSuccess) { ([datetime]$st.lastSuccess).ToString('MM-dd HH:mm') } else { '—' }
  $exit = if ($st -and $null -ne $st.lastExit) { $st.lastExit } else { '—' }
  $fails = if ($st -and $st.consecutiveFailures) { $st.consecutiveFailures } else { '—' }
  $next = Get-NextDue $j.schedule $now $(if ($st) { $st.lastSuccess } else { $null })
  $nextText = if ($next) { ([datetime]$next).ToString('MM-dd HH:mm') } else { '?' }
  $disabled = if ($j.enabled -eq $false) { ' (disabled)' } else { '' }
  "{0,-18} {1,-10} {2,-16} {3,-18} {4,-7} {5,-6} {6}{7}" -f $j.id, $j.agent, $j.schedule, $lastOk, $exit, $fails, $nextText, $disabled
}
