<#
打包发布包：把 agent-cron/ 打成 ../agent-cron-v<version>.zip（条目用正斜杠，跨平台可解压）。
用法：powershell -NoProfile -ExecutionPolicy Bypass -File tools/build-release.ps1
#>
[CmdletBinding()]
param([string]$Version = '')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repo = Split-Path $PSScriptRoot -Parent
$src = Join-Path $repo 'agent-cron'
if (-not $Version) {
  $Version = (Get-Content (Join-Path $repo 'marketplace.json') -Raw -Encoding UTF8 | ConvertFrom-Json).plugins[0].version
}
$out = Join-Path (Split-Path $repo -Parent) "agent-cron-v$Version.zip"
if (Test-Path $out) { Remove-Item -LiteralPath $out -Force }

$files = @(
  'install-cron.ps1', 'login-agents.ps1', 'adapters.json', 'jobs.sample.json', 'README.md', 'LICENSE',
  'runner/Invoke-AgentCron.ps1', 'runner/Get-AgentCronStatus.ps1',
  'skills/agent-cron/SKILL.md'
)
$zip = [System.IO.Compression.ZipFile]::Open($out, 'Create')
foreach ($d in @('runner/', 'skills/', 'skills/agent-cron/')) { [void]$zip.CreateEntry($d) }
foreach ($f in $files) {
  $p = Join-Path $src ($f -replace '/', '\')
  if (-not (Test-Path $p)) { throw "missing: $p" }
  [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $p, $f, [System.IO.Compression.CompressionLevel]::Optimal)
}
$zip.Dispose()

"built: $out ({0} bytes)" -f (Get-Item $out).Length
"sha256: " + (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
