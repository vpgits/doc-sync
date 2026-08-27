#!/usr/bin/env pwsh
# Append one audit-trail entry to .claude/docs-sync.history.jsonl.
#
# Append-only, one JSON object per line. `--revert-last` reads the final line to find
# out what the previous run touched and where it started.
#
# `Event` distinguishes a sync entry from a revert entry, so `--revert-last` can tell
# whether the previous run has already been reverted instead of undoing it twice.
# Parity with append-history.sh.
#
# Usage: append-history.ps1 -Base <sha> -Head <sha> -FilesChanged <n> -ItemsEscalated <n>
#                           [-Files <file>[,<file>...]] [-Event sync|revert]
param(
  [Parameter(Mandatory)][string]$Base,
  [Parameter(Mandatory)][string]$Head,
  [Parameter(Mandatory)][int]$FilesChanged,
  [Parameter(Mandatory)][int]$ItemsEscalated,
  [string[]]$Files = @(),
  [ValidateSet("sync", "revert")][string]$Event = "sync"
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

# Resolve both refs rather than trusting the caller: a value starting with `-` would
# later be read as an option by the revert flow's `git checkout <head> -- <file>`.
function Resolve-Ref([string]$Ref) {
  $out = (git rev-parse --verify --quiet "$Ref^{commit}" 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $out) {
    [Console]::Error.WriteLine("ERROR: '$Ref' does not resolve to a commit in this repository")
    exit 2
  }
  return "$out".Trim().Substring(0, 12)
}
$Base = Resolve-Ref $Base
$Head = Resolve-Ref $Head

$historyFile = Join-Path ".claude" "docs-sync.history.jsonl"
$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# `files` is a JSON ARRAY built by a real encoder, not a comma-joined string: a comma is
# legal in a git path, so a delimited list cannot be decoded unambiguously, and hand-
# interpolating a path containing a quote or backslash would corrupt the audit trail.
$entry = [ordered]@{
  timestamp      = $timestamp
  event          = $Event
  base           = $Base
  head           = $Head
  filesChanged   = $FilesChanged
  itemsEscalated = $ItemsEscalated
  files          = @($Files | Where-Object { $_ } | Sort-Object -Unique)
}
$line = $entry | ConvertTo-Json -Depth 5 -Compress

if (-not (Test-Path ".claude")) { New-Item -ItemType Directory -Path ".claude" | Out-Null }
# The line is fully built above before the file is touched, so an encoder failure can
# never leave a truncated final entry that breaks every later read of the trail.
Add-Content -LiteralPath $historyFile -Value $line -Encoding utf8

Write-Output "appended to $historyFile`: $Base..$Head, $FilesChanged files, $ItemsEscalated escalated, $($entry.files.Count) path(s) recorded"
