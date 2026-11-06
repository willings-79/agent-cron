#requires -Version 5.1
<#
agent-cron —— 桌面版 agent（Codex / WorkBuddy / ZCode / DSH）的定时执行层。
心跳唤醒后对账：该跑没跑，补跑最近一次；跑完写状态与日志。

  Invoke-AgentCron.ps1                     跑一轮（心跳调用）
  Invoke-AgentCron.ps1 -Job daily -Force   忽略时间，立刻跑一次
  Invoke-AgentCron.ps1 -Job x -Force -IncludeDisabled   连 disabled 的 job 也跑
  Invoke-AgentCron.ps1 -DryRun             只打印会做什么
  Invoke-AgentCron.ps1 -Doctor             体检各 agent 的无头入口与能力
  Invoke-AgentCron.ps1 -NoLogContent       只记日志尾部（隐私优先）

数据目录默认 %USERPROFILE%\agent-cron（jobs.json / adapters.json / state / logs / runs.jsonl），可用 AGENT_CRON_HOME 或 -Root 覆盖。
#>
[CmdletBinding()]
param(
  [string]$Job = '',
  [switch]$Force,
  [switch]$IncludeDisabled,
  [switch]$DryRun,
  [switch]$Doctor,
  [switch]$Quiet,
  [switch]$NoLogContent,
  [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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

function Get-Agents {
  if (-not (Test-Path $AdaptersPath)) { throw "找不到适配表：$AdaptersPath" }
  return (Get-Content $AdaptersPath -Raw -Encoding UTF8 | ConvertFrom-Json).agents
}

function Get-AgentSpec([string]$agent) {
  $all = Get-Agents
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
  $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
  return $p
}

function Build-ArgsString($spec, [string]$prompt, [string]$cwd, [string]$sandbox) {
  $argsList = @()
  foreach ($a in $spec.args) { $argsList += [string]$a }

  # 沙箱：job 指定优先，否则用适配表的默认档（如 codex 默认 read-only）
  $eff = if ($sandbox) { $sandbox } elseif ($spec.defaultSandbox) { [string]$spec.defaultSandbox } else { '' }
  if ($eff -and $spec.sandboxArgs) {
    $extra = $spec.sandboxArgs.$eff
    if ($extra) { $argsList = @($extra) + $argsList }
  }

  $port = if (($argsList -join ' ') -match '\{port\}') { Get-FreePort } else { 0 }
  $parts = @()
  foreach ($a in $argsList) {
    $v = $a.Replace('{prompt}', $prompt).Replace('{cwd}', $cwd).Replace('{port}', [string]$port)
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

# ---------- 进程执行 ----------
function Invoke-Process([string]$exe, [string]$argString, [string]$cwd, [int]$timeoutSec, $envMap) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
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
  if ($envMap) {
    foreach ($k in $envMap.Keys) {
      $v = [string]$envMap[$k]
      if ($v) { $psi.EnvironmentVariables[$k] = $v }
    }
  }

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $timedOut = $false
  $exit = $null
  $out = ''
  $err = ''
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
      $timedOut = $true
      try { $p.Kill() } catch { }
      $p.WaitForExit(10000) | Out-Null
    }
    try { $out = $outTask.Result } catch { $out = '' }
    try { $err = $errTask.Result } catch { $err = '' }
    $exit = if ($timedOut) { 124 } else { $p.ExitCode }
  } catch {
    $err = $_.Exception.Message
    $exit = 127
  }
  $sw.Stop()
  return [pscustomobject]@{ exit = $exit; timedOut = $timedOut; stdout = $out; stderr = $err; ms = [int]$sw.Elapsed.TotalMilliseconds }
}

# ---------- 日志 ----------
function Write-JobLog([string]$path, [string[]]$header, $result, [int]$maxKB, [bool]$keepContent) {
  $outText = [string]$result.stdout
  $errText = [string]$result.stderr
  $note = ''

  if (-not $keepContent) {
    $outText = (($outText -split "`r?`n" | Select-Object -Last 30) -join "`r`n")
    $errText = (($errText -split "`r?`n" | Select-Object -Last 30) -join "`r`n")
    $note = '# 只保留末尾 30 行（-NoLogContent 或 job.logContent=false）'
  } elseif ($maxKB -gt 0) {
    $limit = $maxKB * 1024
    if (($outText.Length + $errText.Length) -gt $limit) {
      $keep = [int]($limit * 0.7)
      if ($outText.Length -gt $keep) { $outText = $outText.Substring(0, $keep) + "`r`n... [truncated]" }
      $errText = (($errText -split "`r?`n" | Select-Object -Last 80) -join "`r`n")
      $note = "# 日志超过 ${maxKB}KB，已截断"
    }
  }

  $body = @()
  $body += $header
  if ($note) { $body += $note }
  $body += ''
  $body += '----- stdout -----'
  $body += $outText
  $body += '----- stderr -----'
  $body += $errText
  [IO.File]::WriteAllText($path, ($body -join "`r`n"), $Utf8NoBom)
}

function Clear-OldLogs([int]$days) {
  if ($days -le 0) { return }
  $cut = (Get-Date).AddDays(-$days)
  Get-ChildItem $LogDir -Filter '*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cut } |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

# ---------- 调度 ----------
$DayMap = @{ mon = 'Monday'; tue = 'Tuesday'; wed = 'Wednesday'; thu = 'Thursday'; fri = 'Friday'; sat = 'Saturday'; sun = 'Sunday' }

function Get-MostRecentDue([string]$schedule, [datetime]$now) {
  $s = $schedule.Trim().ToLower()
  if ($s -match '^daily\s+(\d{1,2}):(\d{2})$') {
    $occ = $now.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
    if ($now -lt $occ) { $occ = $occ.AddDays(-1) }
    return $occ
  }
  if ($s -match '^weekly\s+([a-z,]+)\s+(\d{1,2}):(\d{2})$') {
    $names = @()
    foreach ($d in $Matches[1].Split(',')) {
      $k = $d.Trim()
      if ($DayMap.ContainsKey($k)) { $names += $DayMap[$k] } elseif ($k) { $names += $k }
    }
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
  $blank = [pscustomobject]@{ lastSuccess = $null; lastAttempt = $null; lastExit = $null; lastSkipDue = $null; consecutiveFailures = 0 }
  if (-not (Test-Path $p)) { return $blank }
  try {
    $s = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in 'lastSuccess','lastAttempt','lastExit','lastSkipDue','consecutiveFailures') {
      if (-not ($s.PSObject.Properties.Name -contains $k)) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $null -Force }
    }
    if ($null -eq $s.consecutiveFailures) { $s.consecutiveFailures = 0 }
    return $s
  } catch { return $blank }
}

function Write-State([string]$id, $state) {
  [IO.File]::WriteAllText((Join-Path $StateDir "$id.json"), ($state | ConvertTo-Json -Depth 5), $Utf8NoBom)
}

function Add-RunLog($entry) {
  [IO.File]::AppendAllText($RunLog, (($entry | ConvertTo-Json -Compress -Depth 5) + "`r`n"), $Utf8NoBom)
}

# ---------- Doctor ----------
if ($Doctor) {
  Ensure-Dirs
  Say "适配表：$AdaptersPath"
  Say ("数据目录：" + $DataDir)
  Say ''
  $all = Get-Agents
  foreach ($name in $all.PSObject.Properties.Name) {
    $spec = $all.$name
    $resolved = Resolve-Command $spec.exe
    if (-not $resolved -and $spec.fallbackExe) {
      foreach ($f in $spec.fallbackExe) { $resolved = Resolve-Command $f; if ($resolved) { break } }
    }
    $mark = if ($resolved) { 'OK  ' } else { 'MISS' }
    $cap = @()
    foreach ($c in @('headless','jsonOut','sandbox','session','timeout','worktree')) {
      if ($spec.caps -and $spec.caps.$c) { $cap += $c }
    }
    Say ("[{0}] {1,-10} {2,-12} {3}" -f $mark, $name, $(if ($spec.verified) { 'verified' } else { 'experimental' }), $resolved)
    if ($cap.Count) { Say ("       能力: " + ($cap -join ', ')) }
    if ($spec.hint) { Say ("       " + $spec.hint) }
    if ($spec.fix) { Say ("       修复: " + $spec.fix) }
  }
  Say ''
  Say '说明：MISS = 找不到可执行文件；experimental = 入口存在但未端到端验证；能力来自适配表声明，不代表实测。'
  return
}

# ---------- 主流程 ----------
Ensure-Dirs

if (-not (Test-Path $ConfigPath)) {
  Say "没有找到 jobs.json：$ConfigPath"
  Say '把 jobs.sample.json 复制成 jobs.json 后改内容。'
  exit 0
}

# 单实例锁：写 PID，持有进程不在了才抢占（不靠猜时间）
$lock = $null
try {
  $lock = [System.IO.File]::Open($LockPath, 'CreateNew', 'Write', 'None')
  $info = @{ pid = $PID; started = (Get-Date).ToString('o') } | ConvertTo-Json -Compress
  $bytes = $Utf8NoBom.GetBytes($info)
  $lock.Write($bytes, 0, $bytes.Length); $lock.Flush()
} catch {
  $holder = $null
  try { $holder = (Get-Content $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json).pid } catch { }
  $alive = $false
  if ($holder) { $alive = [bool](Get-Process -Id ([int]$holder) -ErrorAction SilentlyContinue) }
  if (-not $alive) {
    Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
    try {
      $lock = [System.IO.File]::Open($LockPath, 'CreateNew', 'Write', 'None')
      $info = @{ pid = $PID; started = (Get-Date).ToString('o'); note = 'stolen' } | ConvertTo-Json -Compress
      $bytes = $Utf8NoBom.GetBytes($info)
      $lock.Write($bytes, 0, $bytes.Length); $lock.Flush()
      Say "接管了上一轮的锁（持有进程 $holder 已退出）"
    } catch { }
  }
  if (-not $lock) { Say "上一轮还在跑（pid $holder），本轮跳过"; exit 0 }
}

try {
  # 上次被强行中断的遗留标记：说明有 job 跑到一半进程就没了
  # （实测：登录初期启动的隐藏控制台会收到 CTRL_CLOSE_EVENT，任务返回 0xC000013A）
  Get-ChildItem $StateDir -Filter '*.inflight' -ErrorAction SilentlyContinue | ForEach-Object {
    $iid = $_.BaseName
    $meta = $null
    try { $meta = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    $alive = $false
    if ($meta -and $meta.pid) { $alive = [bool](Get-Process -Id ([int]$meta.pid) -ErrorAction SilentlyContinue) }
    if (-not $alive) {
      Say ("[interrupted] {0}：上次运行未正常结束（进程已不在），按未完成重试" -f $iid)
      Add-RunLog ([pscustomobject]@{
        ts = (Get-Date).ToString('o'); id = $iid; agent = $null
        due = $(if ($meta) { $meta.due } else { $null })
        reason = 'interrupted'; ms = $null; exit = $null; timedOut = $false; failures = $null; log = $null
      })
      Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }
  }

  $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $settings = $cfg.settings
  $retentionDays = if ($settings -and $settings.logRetentionDays) { [int]$settings.logRetentionDays } else { 14 }
  $defaultMaxLogKB = if ($settings -and $settings.maxLogKB) { [int]$settings.maxLogKB } else { 512 }
  $defaultBackoff = if ($settings -and $settings.retryBackoffMinutes) { [int]$settings.retryBackoffMinutes } else { 15 }
  Clear-OldLogs $retentionDays

  $jobs = @($cfg.jobs)
  if ($Job) { $jobs = @($jobs | Where-Object { $_.id -eq $Job }) }
  if (-not $jobs) { Say '没有匹配的 job'; exit 0 }

  $now = Get-Date
  foreach ($j in $jobs) {
    if (-not $j.id -or -not $j.agent -or -not $j.schedule -or -not $j.prompt) {
      Say "[skip] 配置不完整（需要 id/agent/schedule/prompt）：$($j | ConvertTo-Json -Compress)"
      continue
    }
    if ($j.enabled -eq $false) {
      if (-not ($Force -and $IncludeDisabled)) {
        if ($Force) { Say "[skip] $($j.id)：disabled（要强跑加 -IncludeDisabled）" }
        continue
      }
    }

    $st = Read-State $j.id
    $lastSuccess = if ($st.lastSuccess) { [datetime]$st.lastSuccess } else { $null }
    $lastAttempt = if ($st.lastAttempt) { [datetime]$st.lastAttempt } else { $null }
    $interval = Get-Interval $j.schedule
    $reason = $null
    $due = $null

    if ($Force) {
      $reason = 'forced'
    } elseif ($interval) {
      $due = if ($lastSuccess) { $lastSuccess + $interval } else { $now }
      # 失败退避：别让心跳每 15 分钟重试一次烧额度
      if ($lastAttempt -and $null -ne $st.lastExit -and [int]$st.lastExit -ne 0) {
        $backoff = if ($null -ne $j.retryBackoffMinutes) { [int]$j.retryBackoffMinutes } else { $defaultBackoff }
        $failures = [int]$st.consecutiveFailures
        if ($failures -gt 3) { $backoff = $backoff * 4 } elseif ($failures -gt 1) { $backoff = $backoff * 2 }
        $retryAt = $lastAttempt.AddMinutes($backoff)
        if ($retryAt -gt $due) { $due = $retryAt }
      }
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
          if ($st.lastSkipDue -eq $due.ToString('o')) { continue }
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
      Say ("[fail] {0}：找不到 {1} 的可执行文件（跑 -Doctor 看缺什么）" -f $j.id, $j.agent)
      continue
    }

    # 沙箱：job 声明了就必须支持，否则不跑——不静默降级
    $sandbox = [string]$j.sandbox
    if ($sandbox -and -not ($spec.Spec.sandboxArgs -and $spec.Spec.sandboxArgs.$sandbox)) {
      if (-not $j.allowUnsupportedSandbox) {
        Say ("[skip] {0}：要求 sandbox='{1}'，但 {2} 适配未声明该能力（可设 allowUnsupportedSandbox:true 强跑）" -f $j.id, $sandbox, $j.agent)
        Add-RunLog ([pscustomobject]@{ ts = $now.ToString('o'); id = $j.id; agent = $j.agent; due = $(if ($due) { ([datetime]$due).ToString('o') } else { $now.ToString('o') }); reason = 'unsupported-sandbox'; exit = $null })
        continue
      }
    }

    $cwd = if ($j.cwd) { $j.cwd } else { $DataDir }
    if (-not (Test-Path $cwd)) { Say "[fail] $($j.id)：cwd 不存在：$cwd"; continue }
    $timeoutMin = if ($j.timeoutMin) { [int]$j.timeoutMin } elseif ($spec.Spec.timeoutMin) { [int]$spec.Spec.timeoutMin } else { 20 }

    $argString = Build-ArgsString $spec.Spec $j.prompt $cwd $sandbox
    $envMap = @{}
    if ($spec.Spec.env) { foreach ($k in $spec.Spec.env.PSObject.Properties.Name) { if ($spec.Spec.env.$k) { $envMap[$k] = [string]$spec.Spec.env.$k } } }
    if ($j.env) { foreach ($k in $j.env.PSObject.Properties.Name) { if ($j.env.$k) { $envMap[$k] = [string]$j.env.$k } } }

    $dueText = if ($due) { ([datetime]$due).ToString('o') } else { $now.ToString('o') }
    Say ("[run] {0} → {1}（{2}）" -f $j.id, $j.agent, $reason)

    # 在飞标记：进程若被强行中断（如登录初期收到 CTRL_CLOSE_EVENT），这个文件会留下，
    # 下次心跳据此判定"上次跑到一半"，而不是当作没跑过。
    $inflight = Join-Path $StateDir "$($j.id).inflight"
    try {
      (@{ pid = $PID; started = $now.ToString('o'); due = $dueText; reason = $reason } | ConvertTo-Json -Compress) |
        Set-Content -Path $inflight -Encoding UTF8
    } catch { }

    $r = Invoke-Process $spec.Exe $argString $cwd ($timeoutMin * 60) $envMap
    Remove-Item $inflight -Force -ErrorAction SilentlyContinue

    $failNote = $null
    if (-not $r.timedOut -and $r.exit -eq 0) {
      $hit = Get-FailPatternMatch $spec.Spec ($r.stdout + "`n" + $r.stderr)
      if ($hit) { $failNote = $hit; $r.exit = 78 }
    }

    # 结果校验：agent 说成功不算，verify 说成功才算
    $verifyNote = $null
    if ($r.exit -eq 0 -and $j.verify) {
      $vTimeout = if ($j.verifyTimeoutSec) { [int]$j.verifyTimeoutSec } else { 120 }
      $vr = Invoke-Process 'cmd.exe' ('/c ' + $j.verify) $cwd $vTimeout $envMap
      if ($vr.exit -ne 0) {
        $verifyNote = "verify exit=$($vr.exit)"
        $r.exit = 79
        $r.stdout = $r.stdout + "`r`n----- verify stdout -----`r`n" + $vr.stdout
        $r.stderr = $r.stderr + "`r`n----- verify stderr -----`r`n" + $vr.stderr
      }
    }

    $keepContent = -not ($NoLogContent -or $j.logContent -eq $false)
    $maxKB = if ($null -ne $j.maxLogKB) { [int]$j.maxLogKB } else { $defaultMaxLogKB }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $LogDir "$($j.id)-$stamp.log"
    $header = @(
      "# agent-cron job=$($j.id) agent=$($j.agent) reason=$reason",
      "# exe=$($spec.Exe) args=$argString",
      "# cwd=$cwd timeout=${timeoutMin}min sandbox=$(if ($sandbox) { $sandbox } else { '(adapter default)' })",
      "# started=$($now.ToString('s')) exit=$($r.exit) ms=$($r.ms) timedOut=$($r.timedOut)"
    )
    if ($failNote) { $header += "# 判定为失败（命中 failPattern：$failNote）" }
    if ($verifyNote) { $header += "# 判定为失败（$verifyNote）" }
    Write-JobLog $logPath $header $r $maxKB $keepContent

    $st.lastAttempt = $now.ToString('o')
    $st.lastExit = $r.exit
    if ($r.exit -eq 0) {
      $st.lastSuccess = $now.ToString('o')
      $st.consecutiveFailures = 0
    } else {
      $st.consecutiveFailures = [int]$st.consecutiveFailures + 1
    }
    $st.lastSkipDue = $null
    Write-State $j.id $st

    Add-RunLog ([pscustomobject]@{
        ts = $now.ToString('o'); id = $j.id; agent = $j.agent; due = $dueText; reason = $reason
        ms = $r.ms; exit = $r.exit; timedOut = $r.timedOut; failures = $st.consecutiveFailures; log = $logPath
      })

    $verdict = if ($r.exit -eq 0) { 'ok' } elseif ($r.timedOut) { 'timeout' } elseif ($failNote) { 'auth/config' } elseif ($verifyNote) { 'verify-failed' } else { 'fail' }
    Say ("[{0}] {1}：exit={2} 用时 {3:N1}s 日志 {4}" -f $verdict, $j.id, $r.exit, ($r.ms / 1000), $logPath)
    if ($failNote) { Say ("       命中 failPattern『" + $failNote + "』：该 agent 需要先登录/补配置") }
    if ($verifyNote) { Say ("       " + $verifyNote + "：agent 说跑完了，但校验没通过") }
  }
}
finally {
  if ($lock) {
    $lock.Close()
    Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
  }
}
