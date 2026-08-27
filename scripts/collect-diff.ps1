#!/usr/bin/env pwsh
# Emit the raw git data doc-sync needs between a baseline ref and HEAD.
# Deterministic plumbing only — ignore-glob filtering and classification are done by
# the skill (the model), not here. This output is the authoritative file list; the
# skill must never substitute an ad-hoc `git diff` with its own grep filters, because
# filtering before classification silently drops files.
#
# Usage: collect-diff.ps1 -Base <base-ref> [-Head <head-ref>]
param(
  [Parameter(Mandatory = $true)][string]$Base,
  [string]$Head = "HEAD",
  [int]$MaxPatchBytes = 400000
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

# Fail clearly if the baseline isn't an ancestor of HEAD (rebase/squash). The skill
# must stop and ask for a new baseline here — guessing the equivalent squash-merge
# commit produces a silent bad diff.
git merge-base --is-ancestor $Base $Head 2>$null
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine("ERROR: '$Base' is not an ancestor of '$Head' (history rewritten?).")
  [Console]::Error.WriteLine("Re-bootstrap the baseline before syncing.")
  exit 2
}

# Native error propagation is disabled above so merge-base's exit code stays
# inspectable — which means every later git call must be checked by hand too, or a
# failure would print nothing and the script would still exit 0, handing the model a
# silently empty diff. The bash port gets this from `set -e`.
function Invoke-Git([string[]]$GitArgs, [string]$What) {
  & git @GitArgs
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("ERROR: git $What failed (exit $LASTEXITCODE); refusing to emit a partial diff.")
    exit 4
  }
}

Write-Output "## doc-sync diff: $Base..$Head"
Write-Output ""
Write-Output "### commits, each with the files it touched (newest first, merges excluded)"
Invoke-Git @("log", "--no-merges", "--name-status", "--pretty=format:%n--- %h %s", "$Base..$Head") "log"
Write-Output ""
Write-Output ""
Write-Output "### changed files (name-status, whole range)"
Invoke-Git @("diff", "--name-status", "$Base..$Head") "diff --name-status"
Write-Output ""
Write-Output "### diffstat"
Invoke-Git @("diff", "--stat", "$Base..$Head") "diff --stat"
Write-Output ""

if ($MaxPatchBytes -eq 0) {
  Write-Output "### patch"
  Write-Output "(omitted: -MaxPatchBytes 0)"
  exit 0
}

# The model is asked to verify claims against actual changes, so the patch has to be
# here; capping it keeps one huge range from blowing up its context.
$patch = (& git diff "$Base..$Head" | Out-String)
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine("ERROR: git diff failed (exit $LASTEXITCODE); refusing to emit a partial diff.")
  exit 4
}
$bytes = [System.Text.Encoding]::UTF8.GetByteCount($patch)
Write-Output "### patch ($bytes bytes)"
if ($bytes -le $MaxPatchBytes) {
  Write-Output $patch
} else {
  Write-Output "TRUNCATED: the patch is $bytes bytes, over the $MaxPatchBytes-byte cap."
  Write-Output "The file list above is complete; the hunks are not shown. Read the patch for"
  Write-Output "individual files as you classify them:"
  Write-Output "  git diff $Base..$Head -- <path>"
  Write-Output "Do not treat a claim as verified against a patch you did not read."
}
