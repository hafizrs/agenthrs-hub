# Start the agentdesk GitHub runner in this user session (not as a Windows service).
# Keep this window open so GitHub mobile / GitHub.com can launch agenthrs jobs.

$ErrorActionPreference = "Stop"

Write-Host "Cursor CLI login:"
agent status

$runner = "C:\actions-runner\run.cmd"
if (-not (Test-Path $runner)) {
  Write-Host ""
  Write-Host "Runner not installed yet."
  Write-Host "1. Open https://github.com/hafizrs/agenthrs-hub/settings/actions/runners/new?arch=x64&os=win"
  Write-Host "2. Install to C:\actions-runner"
  Write-Host "3. Add labels: self-hosted, Windows, agentdesk"
  Write-Host "4. Run this script again."
  exit 1
}

Set-Location "C:\actions-runner"
Write-Host "Starting agentdesk runner. Leave this window open."
& .\run.cmd
