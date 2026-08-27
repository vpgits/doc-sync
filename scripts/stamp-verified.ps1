#!/usr/bin/env pwsh
# Upsert a per-doc provenance stamp: an HTML comment recording the SHA the doc was last
# VERIFIED against (verified is not the same as edited — a doc that was checked and
# found already correct gets stamped too, or it looks permanently stale).
#
# This stamp, not the global baseline, is the certification. A doc the sync missed
# simply keeps its old stamp and stays visibly stale in doc-audit's aging report,
# instead of being silently certified by a baseline bump it never participated in.
#
# Stamps Tier B docs only. Tier A agent-instruction files are never stamped: they are
# instructions, not documentation, and a bookkeeping line there is noise that every
# future agent session reads.
#
# Usage: stamp-verified.ps1 -Sha <sha> -Files <file.md>[,<file.md>...]
param(
  [Parameter(Mandatory)][string]$Sha,
  [Parameter(Mandatory)][string[]]$Files
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

$shortSha = (git rev-parse --short $Sha 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $shortSha) { $shortSha = $Sha }
$shortSha = "$shortSha".Trim()
$stamp = "<!-- doc-sync: verified-at $shortSha -->"
$stampedCount = 0
$missingCount = 0
$tierA = @("CLAUDE.md", "AGENTS.md", "GEMINI.md", ".cursorrules", ".windsurfrules", "copilot-instructions.md")

foreach ($f in $Files) {
  if (-not (Test-Path -LiteralPath $f)) {
    [Console]::Error.WriteLine("SKIP (missing): $f")
    $missingCount++
    continue
  }
  if ($tierA -contains (Split-Path $f -Leaf)) {
    [Console]::Error.WriteLine("SKIP (Tier A is never stamped): $f")
    continue
  }
  $content = Get-Content -LiteralPath $f -Raw
  if ($content -match '<!-- doc-sync: verified-at [^>]*-->') {
    $content = $content -replace '<!-- doc-sync: verified-at [^>]*-->', $stamp
    Set-Content -LiteralPath $f -Value $content -NoNewline
  } else {
    Add-Content -LiteralPath $f -Value "`n$stamp"
  }
  $stampedCount++
  Write-Output "stamped $f @ $shortSha"
}

# Parity with the bash port: exiting 0 having stamped nothing would let the caller
# advance state and write history as though certification had happened.
if ($missingCount -gt 0 -and $stampedCount -eq 0) {
  [Console]::Error.WriteLine("ERROR: nothing was stamped ($missingCount file(s) missing). Not a successful certification.")
  exit 3
}
Write-Output "stamped $stampedCount file(s); $missingCount missing"
