#requires -Version 5.1
<# 附赠工具：批量给已有 Windows 计划任务开启"错过补跑"（StartWhenAvailable）。默认 dry-run，加 -Apply 才写入。
   这是 task-catchup 时代留下的，给"不是 agent 建的老任务"用；agent-cron 的 job 不需要它。 #>
[CmdletBinding()]
param(
  [string]$Name = '*',
  [switch]$Apply,
  [switch]$IncludeVendors
)
$targets = @(Get-ScheduledTask |
  Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.TaskName -like $Name -and -not $_.Settings.StartWhenAvailable })

if (-not $targets) { 'Nothing to change: all matched user tasks already have catch-up enabled (or none matched).'; return }

# 厂商更新类任务：只匹配"厂商前缀"或"以 Updater 结尾"，避免误伤 UpdateRates / DailyUpdateReport 这类自建任务
$vendorRx = '(?i)^(wps|nahimic|niupdate|360|adobe|googleupdate|microsoftedge|nvidia|realtek|intel|dell|lenovo|acrobat|acrotray)|updater$'

$applied = 0; $failed = 0; $skippedVendors = 0
foreach ($t in $targets) {
  $label = '{0}{1}' -f $t.TaskPath, $t.TaskName
  if (-not $IncludeVendors -and $t.TaskName -match $vendorRx) {
    "[skip vendor]  $label（疑似厂商更新任务：厂商前缀或以 Updater 结尾；确要包含加 -IncludeVendors）"
    $skippedVendors++
    continue
  }
  try {
    if ($Apply) {
      $t.Settings.StartWhenAvailable = $true
      $t | Set-ScheduledTask -ErrorAction Stop | Out-Null
      "[APPLIED]      $label"
      $applied++
    } else {
      "[would enable] $label"
    }
  } catch {
    "[FAILED]       $label -> $($_.Exception.Message)"
    $failed++
  }
}

if ($Apply) {
  "Summary: applied=$applied failed=$failed skipped-vendor=$skippedVendors"
} else {
  "Summary: would change $($targets.Count - $skippedVendors) task(s), skipped-vendor $skippedVendors (dry run: re-run with -Apply to write changes; -IncludeVendors 包含厂商更新类)"
}
if ($failed -gt 0) { exit 1 }
