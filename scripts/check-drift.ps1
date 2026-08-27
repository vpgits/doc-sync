#!/usr/bin/env pwsh
# SessionStart drift check.
#
# Nudges only past a threshold — a watermark that fires after every commit trains
# itself into being ignored. Thresholds come from the config's `driftThreshold`
# (commits / days), defaulting to 15 commits or 14 days.
#
# Exits silently when below the threshold, or when the skill has not been initialised
# yet. Unlike the bash port this one parses JSON properly, so config key names are
# not load-bearing here.
$ErrorActionPreference = "SilentlyContinue"

$stateFile = ".claude/docs-sync.state.json"
$configFile = ".claude/docs-sync.config.json"
if (-not (Test-Path $stateFile)) { exit 0 }

$state = Get-Content $stateFile -Raw | ConvertFrom-Json
$lastSha = $state.lastSyncedSha
if (-not $lastSha) { exit 0 }

$tCommits = 15; $tDays = 14
if (Test-Path $configFile) {
  $config = Get-Content $configFile -Raw | ConvertFrom-Json
  if ($config.driftThreshold) {
    if ($config.driftThreshold.commits) { $tCommits = [int]$config.driftThreshold.commits }
    if ($config.driftThreshold.days) { $tDays = [int]$config.driftThreshold.days }
  }
}

$behind = git rev-list --count "$lastSha..HEAD" 2>$null
if ($LASTEXITCODE -ne 0 -or -not $behind) { exit 0 }
$behind = [int]("$behind".Trim())

$days = 0
if ($state.lastSyncedAt) {
  try { $days = [int]((Get-Date) - [datetime]::ParseExact($state.lastSyncedAt, "yyyy-MM-dd", $null)).TotalDays } catch {}
}

if ($behind -ge $tCommits -or $days -ge $tDays) {
  Write-Output "⚠  docs may be stale — $behind commits (${days}d) since last sync at $lastSha. Run /doc-sync to update."
}
