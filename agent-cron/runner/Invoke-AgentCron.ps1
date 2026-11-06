#requires -Version 5.1
<#
Agent Cron —— 给桌面版 agent（Codex / ZCode / DSH / WorkBuddy）补上"错过也补跑"的定时执行层。

跑一轮（心跳任务调这个）：
  powershell -NoProfile -ExecutionPolicy Bypass -File Invoke-AgentCron.ps1
只跑某个 job / 忽略时间：
  Invoke-AgentCron.ps1 -Job daily-report
  Invoke-AgentCron.ps1 -Job daily-report -Force
只看会发生什么：
  Invoke-AgentCron.ps1 -DryRun
体检各 agent 的无头入口：
  Invoke-AgentCron.ps1 -Doctor

数据目录默认 %USERPROFILE%\agent-cron（jobs.json / state / logs / runs.jsonl），可用 AGENT_CRON_HOME 覆盖。
#>
[CmdletBinding()]
param(
  [string]$Job = '',
  [switch]$Force,
  [switch]$DryRun,
  [switch]$Doctor,
  [switch]$Quiet,
  [string]$Root = ''
)

$ErrorActionPreference = 'Stop'

# ---------- 路径 ----------
$DataDir = if ($Root) { $Root } elseif ($env:AGENT_CRON_HOME) { $env:AGENT_CRON_HOME } else { Join-Path $env:USERPROFILE 'agent-cron' }
$ConfigPath = Join-Path $DataDir 'jobs.json'
$AdaptersPath = if (Test-Path (Join-Path $DataDir 'adapters.json')) { Join-Path $DataDir 'adapters.json' } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'adapters.json' }
$StateDir = Join-Path $DataDir 'state'
$LogDir = Join-Path $DataDir 'logs'
$RunLog = Join-Path $DataDir 'runs.jsonl'
$LockPath = Join-Path $DataDir '.run.lock'

function Say($msg) { if (-not $Quiet) { Write-Output $msg } }

function Ensure-Dirs {
  foreach ($d in @($DataDir, $StateDir, $LogDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  }
}

# ---------- 适配层 ----------
function Resolve-Command([string]$name) {
  if (-not $name) { return $null }
  if (Test-Path -LiteralPath $name) { return (Resolve-Path -LiteralPath $name).Path }
  $c = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  return $null
}

function Get-AgentSpec([string]$agent) {
  if (-not (Test-Path $AdaptersPath)) { throw "找不到适配表：$AdaptersPath" }
  $all = (Get-Content $AdaptersPath -Raw -Encoding UTF8 | ConvertFrom-Json).agents
  $spec = $all.$agent
  if (-not $spec) { throw "适配表里没有 agent '$agent'（可用：$((($all.PSObject.Properties.Name) -join ', '))）" }
  $exe = Resolve-Command $spec.exe
  if (-not $exe -and $spec.fallbackExe) {
    foreach ($f in $spec.fallbackExe) { $exe = Resolve-Command $f; if ($exe) { break } }
  }
  return [pscustomobject]@{ Name = $agent; Spec = $spec; Exe = $exe }
}

function Get-FreePort {
  $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $l.Start()
  $p = $l.LocalEndpoint.Port
  $l.Stop()
  return $p
}

function Build-ArgsString($spec, [string]$prompt, [string]$cwd) {
  $port = if (($spec.args -join ' ') -match '\{port\}') { Get-FreePort } else { 0 }
  $parts = @()
  foreach ($a in $spec.args) {
    $v = [string]$a
    $v = $v.Replace('{prompt}', $prompt).Replace('{cwd}', $cwd).Replace('{port}', [string]$port)
    if ($v -match '[\s"]') { $v = '"' + ($v -replace '"', '\"') + '"' }
    $parts += $v
  }
  return ($parts -join ' ')
}

function Get-FailPatternMatch($spec, [string]$text) {
  if (-not $spec.failPattern) { return $null }
  foreach ($pat in $spec.failPattern) {
    if ($pat -and $text -match [regex]::Escape($pat)) { return $pat }
  }
  return $null
}

# ---------- 调度解析 ----------
$DayMap = @{ mon = 'Monday'; tue = 'Tuesday'; wed = 'Wednesday'; thu = 'Thursday'; fri = 'Friday'; sat = 'Saturday'; sun = 'Sunday' }

function Get-MostRecentDue([string]$schedule, [datetime]$now) {
  $s = $schedule.Trim().ToLower()
  if ($s -match '^daily\s+(\d{1,2}):(\d{2})$') {
    $occ = $now.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
    if ($now -lt $occ) { $occ = $occ.AddDays(-1) }
    return $occ
  }
  if ($s -match '^weekly\s+([a-z,]+)\s+(\d{1,2}):(\d{2})$') {
    $days = $Matches[1].Split(',') | ForEach-Object { $_.Trim() }
    $names = @()
    foreach ($d in $days) { if ($DayMap.ContainsKey($d)) { $names += $DayMap[$d] } elseif ($d) { $names += $d } }
    for ($i = 0; $i -le 7; $i++) {
      $day = $now.Date.AddDays(-$i)
      $occ = $day.AddHours([int]$Matches[2]).AddMinutes([int]$Matches[3])
      if (($names -contains $day.DayOfWeek.ToString()) -and ($occ -le $now)) { return $occ }
    }
    return $null
  }
  return $null
}

function Get-Interval([string]$schedule) {
  $s = $schedule.Trim().ToLower()
  if ($s -match '^every\s+(\d+)\s*h$') { return [TimeSpan]::FromHours([int]$Matches[1]) }
  if ($s -match '^every\s+(\d+)\s*m$') { return [TimeSpan]::FromMinutes([int]$Matches[1]) }
  return $null
}

# ---------- 状态 ----------
function Read-State([string]$id) {
  $p = Join-Path $StateDir "$id.json"
  $blank = [pscustomobject]@{ lastSuccess = $null; lastAttempt = $null; lastExit = $null; lastSkipDue = $null }
  if (-not (Test-Path $p)) { return $blank }
  try {
    $s = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in 'lastSuccess','lastAttempt','lastExit','lastSkipDue') {
      if (-not ($s.PSObject.Properties.Name -contains $k)) {
        $s | Add-Member -NotePropertyName $k -NotePropertyValue $null -Force
      }
    }
    return $s
  } catch { return $blank }
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-State([string]$id, $state) {
  $p = Join-Path $StateDir "$id.json"
  [IO.File]::WriteAllText($p, ($state | ConvertTo-Json -Depth 5), $Utf8NoBom)
}

function Add-RunLog($entry) {
  [IO.File]::AppendAllText($RunLog, (($entry | ConvertTo-Json -Compress -Depth 5) + "`r`n"), $Utf8NoBom)
}

# ---------- 执行 ----------
function Invoke-AgentJob($job, $spec, [string]$prompt, [string]$reason) {
  $agent = $spec.Name
  $cwd = if ($job.cwd) { $job.cwd } else { $DataDir }
  if (-not (Test-Path $cwd)) { throw "job '$($job.id)' 的 cwd 不存在：$cwd" }
  $timeoutMin = if ($job.timeoutMin) { [int]$job.timeoutMin } elseif ($spec.Spec.timeoutMin) { [int]$spec.Spec.timeoutMin } else { 20 }

  $argString = Build-ArgsString $spec.Spec $prompt $cwd
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $exe = $spec.Exe
  if ($exe -match '\.(cmd|bat)$') {
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/c ""' + $exe + '" ' + $argString + '"'
  } else {
    $psi.FileName = $exe
    $psi.Arguments = $argString
  }
  $psi.WorkingDirectory = $cwd
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  if ($job.env) {
    foreach ($k in $job.env.PSObject.Properties.Name) {
      $v = [string]$job.env.$k
      if ($v) { $psi.EnvironmentVariables[$k] = $v }
    }
  }
  if ($spec.Spec.env) {
    foreach ($k in $spec.Spec.env.PSObject.Properties.Name) {
      $v = [string]$spec.Spec.env.$k
      if ($v -and -not $psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables[$k] = $v }
    }
  }

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $logPath = Join-Path $LogDir "$($job.id)-$stamp.log"
  $started = Get-Date
  $timedOut = $false
  $exitCode = $null
  $stdout = ''
  $stderr = ''

  try {
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutMin * 60 * 1000)) {
      $timedOut = $true
      try { $p.Kill() } catch { }
      $p.WaitForExit(10000) | Out-Null
    }
    try { $stdout = $outTask.Result } catch { $stdout = '' }
    try { $stderr = $errTask.Result } catch { $stderr = '' }
    $exitCode = if ($timedOut) { 124 } else { $p.ExitCode }
  } catch {
    $stderr = $_.Exception.Message
    $exitCode = 127
  }

  $ended = Get-Date

  # 有些 CLI 未登录/缺配置时仍然 exit 0，只在输出里留一句话——按输出判定失败，避免"假成功"
  $failNote = $null
  if (-not $timedOut -and $exitCode -eq 0) {
    $hit = Get-FailPatternMatch $spec.Spec ($stdout + "`n" + $stderr)
    if ($hit) { $failNote = $hit; $exitCode = 78 }
  }

  $body = @()
  $body += "# agent-cron job=$($job.id) agent=$agent reason=$reason"
  $body += "# exe=$($psi.FileName) args=$($psi.Arguments)"
  $body += "# cwd=$cwd started=$($started.ToString('s')) ended=$($ended.ToString('s')) timeout=${timeoutMin}min timedOut=$timedOut exit=$exitCode"
  if ($failNote) { $body += "# 判定为失败（命中 failPattern：$failNote）" }
  $body += ""
  $body += "----- stdout -----"
  $body += $stdout
  $body += "----- stderr -----"
  $body += $stderr
  ($body -join "`r`n") | Set-Content -Path $logPath -Encoding UTF8

  return [pscustomobject]@{
    exit = $exitCode; timedOut = $timedOut; log = $logPath; failNote = $failNote
    ms = [int]($ended - $started).TotalMilliseconds
  }
}

# ---------- Doctor ----------
if ($Doctor) {
  Ensure-Dirs
  Say "适配表：$AdaptersPath"
  Say ("数据目录：" + $DataDir)
  Say ""
  $all = (Get-Content $AdaptersPath -Raw -Encoding UTF8 | ConvertFrom-Json).agents
  foreach ($name in $all.PSObject.Properties.Name) {
    $spec = $all.$name
    $resolved = Resolve-Command $spec.exe
    if (-not $resolved -and $spec.fallbackExe) {
      foreach ($f in $spec.fallbackExe) { $resolved = Resolve-Command $f; if ($resolved) { break } }
    }
    $mark = if ($resolved) { 'OK  ' } else { 'MISS' }
    $verified = if ($spec.verified) { 'verified' } else { 'experimental' }
    Say ("[{0}] {1,-10} {2,-14} {3}" -f $mark, $name, $verified, $resolved)
    if ($spec.hint) { Say ("       " + $spec.hint) }
    if ($spec.fix) { Say ("       修复: " + $spec.fix) }
  }
  Say ""
  Say "说明：MISS 表示找不到可执行文件；experimental 表示入口存在但尚未端到端验证。"
  return
}

# ---------- 主流程 ----------
Ensure-Dirs

if (-not (Test-Path $ConfigPath)) {
  Say "没有找到 jobs.json：$ConfigPath"
  Say "把 jobs.sample.json 复制成 jobs.json 后改内容，例如："
  Say "  Copy-Item (Join-Path `$PSScriptRoot '..\jobs.sample.json') `"$ConfigPath`""
  exit 0
}

# 单实例锁：心跳可能重叠
$lock = $null
try { $lock = [System.IO.File]::Open($LockPath, 'CreateNew', 'Write', 'None') }
catch {
  $stale = $false
  if (Test-Path $LockPath) {
    $age = (Get-Date) - (Get-Item $LockPath).LastWriteTime
    if ($age.TotalMinutes -gt 30) { $stale = $true }
  }
  if ($stale) {
    Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
    try { $lock = [System.IO.File]::Open($LockPath, 'CreateNew', 'Write', 'None') } catch { }
  }
  if (-not $lock) { Say "上一轮还在跑（锁 $LockPath），本轮跳过"; exit 0 }
}

try {
  $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $jobs = @($cfg.jobs)
  if ($Job) { $jobs = @($jobs | Where-Object { $_.id -eq $Job }) }
  if (-not $jobs) { Say "没有匹配的 job"; exit 0 }

  $now = Get-Date
  foreach ($j in $jobs) {
    if (-not $j.id -or -not $j.agent -or -not $j.schedule -or -not $j.prompt) {
      Say "[skip] 配置不完整（需要 id/agent/schedule/prompt）：$($j | ConvertTo-Json -Compress)"
      continue
    }
    if ($j.enabled -eq $false -and -not $Force) { continue }
    $st = Read-State $j.id
    $lastSuccess = if ($st.lastSuccess) { [datetime]$st.lastSuccess } else { $null }
    $interval = Get-Interval $j.schedule
    $reason = $null
    $due = $null

    if ($Force) {
      $reason = 'forced'
    } elseif ($interval) {
      $due = if ($lastSuccess) { $lastSuccess + $interval } else { $now }
      if ($now -ge $due) { $reason = if ($lastSuccess) { 'due' } else { 'first-run' } }
    } else {
      $due = Get-MostRecentDue $j.schedule $now
      if (-not $due) {
        Say "[skip] $($j.id)：看不懂的 schedule '$($j.schedule)'（支持 daily 09:00 / weekly mon,fri 20:00 / every 2h）"
        continue
      }
      if (-not $lastSuccess -or $due -gt $lastSuccess) {
        $maxDelay = if ($null -ne $j.maxDelayHours) { [int]$j.maxDelayHours } else { 24 }
        $delayH = ($now - $due).TotalHours
        if ($maxDelay -gt 0 -and $delayH -gt $maxDelay) {
          if ($st.lastSkipDue -eq $due.ToString('o')) { continue }   # 同一个过期点只记一次，别每 15 分钟刷一条
          Say ("[skip-stale] {0}：最近一次 {1:MM-dd HH:mm}，已过期 {2:N1}h > 窗口 {3}h" -f $j.id, $due, $delayH, $maxDelay)
          Add-RunLog ([pscustomobject]@{ ts = $now.ToString('o'); id = $j.id; agent = $j.agent; due = $due.ToString('o'); reason = 'skip-stale'; delayH = [math]::Round($delayH, 1); exit = $null })
          $st.lastSkipDue = $due.ToString('o')
          Write-State $j.id $st
          continue
        }
        $reason = if ($lastSuccess) { 'catchup' } else { 'first-run' }
      }
    }

    if (-not $reason) { Say "[ok] $($j.id)：还没到点"; continue }

    if ($DryRun) {
      Say ("[dry-run] {0} → agent={1} reason={2} due={3:MM-dd HH:mm} cwd={4}" -f $j.id, $j.agent, $reason, $due, $j.cwd)
      continue
    }

    try { $spec = Get-AgentSpec $j.agent } catch { Say "[fail] $($j.id)：$($_.Exception.Message)"; continue }
    if (-not $spec.Exe) {
      Say ("[fail] {0}：找不到 {1} 的可执行文件（跑 -Doctor 看哪里没装上）" -f $j.id, $j.agent)
      continue
    }

    $dueText = if ($due) { ([datetime]$due).ToString('o') } else { $now.ToString('o') }
    Say ("[run] {0} → {1}（{2}）" -f $j.id, $j.agent, $reason)
    $r = Invoke-AgentJob $j $spec $j.prompt $reason

    $st.lastAttempt = $now.ToString('o')
    $st.lastExit = $r.exit
    if ($r.exit -eq 0) { $st.lastSuccess = $now.ToString('o') }
    Write-State $j.id $st

    Add-RunLog ([pscustomobject]@{
        ts = $now.ToString('o'); id = $j.id; agent = $j.agent; due = $dueText; reason = $reason
        ms = $r.ms; exit = $r.exit; timedOut = $r.timedOut; log = $r.log
      })

    $verdict = if ($r.exit -eq 0) { 'ok' } elseif ($r.timedOut) { 'timeout' } elseif ($r.failNote) { 'auth/config' } else { 'fail' }
    Say ("[{0}] {1}：exit={2} 用时 {3:N1}s 日志 {4}" -f $verdict, $j.id, $r.exit, ($r.ms / 1000), $r.log)
    if ($r.failNote) { Say ("       命中 failPattern『" + $r.failNote + "』：该 agent 需要先登录/补配置，见日志首部") }
  }
}
finally {
  if ($lock) { $lock.Close(); Remove-Item $LockPath -Force -ErrorAction SilentlyContinue }
}
