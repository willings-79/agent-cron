<#
一次性登录助手：只有 WorkBuddy / ZCode 需要各跑一次，Codex 复用桌面版登录，不用管。
原因是这两家 CLI 是 TUI-first，授权与选模型没有对应的命令行参数，只能在交互界面里做。

用法：
  powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\agent-cron\login-agents.ps1"
  powershell -NoProfile -ExecutionPolicy Bypass -File "...\login-agents.ps1" -Choice 1
#>
[CmdletBinding()]
param(
  [ValidateSet('1', '2', 'workbuddy', 'zcode')]
  [string]$Choice = ''
)

$ErrorActionPreference = 'Stop'

$WbCli = 'D:\workbuddy\resources\app.asar.unpacked\cli\bin\codebuddy'
$ZcCli = 'D:\zcode\resources\glm\zcode.cjs'

function Get-FreePort {
  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $port = $listener.LocalEndpoint.Port
  $listener.Stop()
  return $port
}

function Test-Cli([string]$path, [string]$name) {
  if (-not (Test-Path -LiteralPath $path)) {
    Write-Host "找不到 $name 的 CLI：$path" -ForegroundColor Red
    Write-Host '装在其他位置的话，改本脚本顶部的路径，或在 adapters.json 里改绝对路径。'
    return $false
  }
  return $true
}

Write-Host ''
Write-Host 'agent-cron 一次性登录' -ForegroundColor Cyan
Write-Host '  Codex 已能用，不需要这一步。'
Write-Host '  WorkBuddy / ZCode 的授权只能在各家 CLI 的交互界面里做。'
Write-Host ''
Write-Host '  1) WorkBuddy -> 进界面输 /login（浏览器授权）'
Write-Host '  2) ZCode     -> 浏览器授权 + 进界面输 /model 选模型'
Write-Host '  q) 退出'
Write-Host ''

if (-not $Choice) { $Choice = (Read-Host '选一个（1/2/q）').Trim() }
$Choice = $Choice.ToLowerInvariant()

if ($Choice -eq '1' -or $Choice -eq 'workbuddy') {
  if (-not (Test-Cli $WbCli 'WorkBuddy')) { return }
  $env:CODEBUDDY_FORCE_LITE_WB_BUNDLE = '1'
  $port = Get-FreePort
  Write-Host ''
  Write-Host '已设 CODEBUDDY_FORCE_LITE_WB_BUNDLE=1（该发行版只有 lite-wb bundle，不设会报 Cannot find module）'
  Write-Host "已取空闲端口 $port（桌面版 WorkBuddy 常占 55298，不能撞）"
  Write-Host '马上进入交互界面：请在界面里输入 /login，浏览器点同意，然后正常退出。'
  Write-Host '注意 /login 是界面里的斜杠命令，不是 PowerShell 命令。'
  Write-Host ''
  & node $WbCli --port $port
  Write-Host ''
  Write-Host "CLI 退出码：$LASTEXITCODE"
  Write-Host "验一下：powershell -NoProfile -File `"$PSScriptRoot\runner\Invoke-AgentCron.ps1`" -Doctor"
  return
}

if ($Choice -eq '2' -or $Choice -eq 'zcode') {
  if (-not (Test-Cli $ZcCli 'ZCode')) { return }
  Write-Host ''
  Write-Host '第一步 浏览器授权：会打印一个 URL，浏览器里点同意；没自动弹窗就把 URL 复制过去。'
  & node $ZcCli login zai
  Write-Host ''
  Write-Host '第二步 进界面输 /model 挑一个模型（如 GLM-4.6），选完退出。'
  Write-Host 'CLI 没有 --model 参数；不选模型时无头模式会报 Select a model before sending a message。'
  & node $ZcCli
  Write-Host ''
  Write-Host "验一下：powershell -NoProfile -File `"$PSScriptRoot\runner\Invoke-AgentCron.ps1`" -Doctor"
  return
}

Write-Host '已退出，没有改动任何配置。'
