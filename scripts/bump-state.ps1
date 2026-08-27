#!/usr/bin/env pwsh
# Write .claude/docs-sync.state.json with the synced baseline SHA and today's date.
#
# This is a SCHEDULING HINT, not a certification: it bounds the next run's diff and
# asserts nothing about completeness. The per-doc stamps written by stamp-verified.ps1
# are what actually certify a doc. Bumping still hides the range from the next diff,
# so the skill skips this step entirely in no-write modes and on scoped runs.
#
# Usage: bump-state.ps1 [-Sha <sha>]   (default: HEAD)
param(
  [string]$Sha = "HEAD"
)
$ErrorActionPreference = "Stop"

# PowerShell 7.4+ sets $PSNativeCommandUseErrorActionPreference to $true by default,
# which turns a non-zero exit from a NATIVE command (git) into a terminating error under
# $ErrorActionPreference = "Stop". This script inspects git's exit code deliberately, so
# that default would abort before the check and collapse every distinct failure into a
# plain exit 1. Opting out keeps native exit codes inspectable.
if ($null -ne (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction Ignore) -or
    $PSVersionTable.PSVersion -ge [version]'7.3') {
  $PSNativeCommandUseErrorActionPreference = $false
}

$shortSha = (git rev-parse --short $Sha).Trim()
$today = (Get-Date -Format "yyyy-MM-dd")
$stateDir = ".claude"
$stateFile = Join-Path $stateDir "docs-sync.state.json"

if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }
# The field names must stay unique within this file: check-drift.sh reads them back
# with grep and sed rather than taking a jq dependency.
$json = "{`n  `"lastSyncedSha`": `"$shortSha`",`n  `"lastSyncedAt`": `"$today`"`n}`n"
# Write to a temp file in the same directory and move it over the target. A direct write
# can leave a half-written state file if the process dies mid-write, and the next run
# then reads a corrupt baseline. Parity with bump-state.sh.
$tmpState = Join-Path $stateDir ".docs-sync.state.$([System.IO.Path]::GetRandomFileName())"
try {
  Set-Content -LiteralPath $tmpState -Value $json -NoNewline -Encoding utf8
  Move-Item -LiteralPath $tmpState -Destination $stateFile -Force
} finally {
  if (Test-Path -LiteralPath $tmpState) { Remove-Item -LiteralPath $tmpState -Force }
}

Write-Output "wrote $stateFile`: $shortSha @ $today"
