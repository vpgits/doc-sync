#!/usr/bin/env pwsh
# Deterministic doc staleness detection — no LLM involved. See doc-audit.sh for the
# full description; this is the PowerShell port.
#
# Two checks over every markdown file in the given roots:
#   1. Reference rot: backticked tokens that look like repo paths are existence-checked
#      against the working tree at HEAD.
#   2. Provenance aging: per-doc verified-at stamps resolved to "commits behind HEAD",
#      with unstamped docs listed separately.
#
# Configuration is read from .claude/docs-sync.config.json under `docAudit`
# (roots, topLevelDirs, skipDirs). PowerShell parses JSON natively, so unlike the bash
# port this needs no external tool. Command-line roots always win.
#
# Exit 0 always, unless -Strict, which exits 1 when broken references exist.
#
# Usage: doc-audit.ps1 [-Strict] [-Roots <dir>[,<dir>...]]
param(
  [switch]$Strict,
  [string[]]$Roots = @()
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

$configFile = ".claude/docs-sync.config.json"

# Built-in fallbacks, used when the config is missing or has no docAudit block.
$configRoots = @("docs")
$topLevelDirs = @("src", "app", "apps", "lib", "libs", "packages", "services", "internal", "cmd", "pkg", "docs", "scripts", "tools", ".github", ".claude")
$skipDirs = @("node_modules", "vendor", "archive", "legacy", ".venv", "target", "build", "dist")

if (Test-Path $configFile) {
  $config = Get-Content $configFile -Raw | ConvertFrom-Json
  if ($config.docAudit) {
    if ($config.docAudit.roots) { $configRoots = @($config.docAudit.roots) }
    if ($config.docAudit.topLevelDirs) { $topLevelDirs = @($config.docAudit.topLevelDirs) }
    if ($config.docAudit.skipDirs) { $skipDirs = @($config.docAudit.skipDirs) }
  }
}

# Command-line roots override the config; the config overrides the built-in default.
if ($Roots.Count -eq 0) { $Roots = $configRoots }

# Build the "looks like a repo path" regex from the repo's own top-level directories.
# A token only counts as a path claim if it starts with one of them — otherwise every
# backticked identifier in every doc would be probed.
# Root-level files a doc commonly cites. Without these the matcher requires a directory
# prefix, so `package.json`, `Makefile` or `README.md` are never checked at all — while
# the report still claims a clean bill of health. Parity with doc-audit.sh.
$rootFiles = @("package.json", "package-lock.json", "pnpm-workspace.yaml", "tsconfig.json",
               "go.mod", "go.sum", "Cargo.toml", "pyproject.toml", "setup.py", "requirements.txt",
               "Gemfile", "composer.json", "Makefile", "Dockerfile", "docker-compose.yml",
               "docker-compose.yaml", "README.md", "LICENSE", "CONTRIBUTING.md", "CHANGELOG.md",
               ".nvmrc", ".tool-versions", ".editorconfig", ".gitignore")
$dirAlt  = ($topLevelDirs | ForEach-Object { [regex]::Escape($_) }) -join '|'
$rootAlt = ($rootFiles   | ForEach-Object { [regex]::Escape($_) }) -join '|'
$topRe = '^((' + $dirAlt + ')/[^ ]+|(' + $rootAlt + '))$'
# Matched against the REPO-RELATIVE path, never $_.FullName: a checkout living under
# any directory called build/, dist/, target/, vendor/ or .venv/ (e.g. C:\build\myrepo)
# would otherwise match every file and silently audit nothing.
$skipRe = '(^|[\\/])(' + (($skipDirs | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')[\\/]'

$repoRoot = (git rev-parse --show-toplevel).Trim()
$headSha = (git rev-parse --short HEAD).Trim()
$brokenTotal = 0
$traversalOk = $true

Write-Output "## doc-audit @ $headSha"
Write-Output ""
Write-Output "### 1. Reference rot (cited paths that do not exist)"

$docs = @()
foreach ($root in $Roots) {
  if (-not (Test-Path $root)) {
    Write-Output "  WARNING: configured root does not exist: $root — this report is INCOMPLETE"
    $traversalOk = $false
    continue
  }
  $rootFull = (Resolve-Path $root).Path
  $docs += Get-ChildItem -Path $root -Filter *.md -Recurse -File |
    Where-Object {
      $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\', '/')
      $rel -notmatch $skipRe
    }
}
$docs = $docs | Sort-Object FullName

foreach ($doc in $docs) {
  $content = Get-Content $doc.FullName -Raw
  $rel = [System.IO.Path]::GetRelativePath((Get-Location), $doc.FullName)
  # Backticked tokens that look like repo paths, with globs and placeholders excluded —
  # those are patterns being described, not paths being cited.
  $tokens = [regex]::Matches($content, '`([^`]*)`') | ForEach-Object { $_.Groups[1].Value } |
    Where-Object { $_ -match $topRe -and $_ -notmatch '[*{<… ]' -and $_ -notmatch '\.\.\.' } |
    Sort-Object -Unique
  $broken = @()
  foreach ($t in $tokens) {
    $probe = ($t -replace ':[0-9][0-9,-]*$', '').TrimEnd('/')
    if (-not (Test-Path (Join-Path $repoRoot $probe))) {
      # A missing path that is GITIGNORED is a documented local artifact — .env files,
      # generated project dirs, machine-local configs. Setup instructions, not rot.
      git -C $repoRoot check-ignore -q $probe 2>$null
      if ($LASTEXITCODE -ne 0) { $broken += $t }
    }
  }
  if ($broken.Count -gt 0) {
    $brokenTotal += $broken.Count
    Write-Output "  ${rel}:"
    $broken | ForEach-Object { Write-Output "    x $_" }
  }
}
if ($brokenTotal -eq 0) { Write-Output "  none found" }
Write-Output "  (dirs skipped: $($skipDirs -join ' '))"

Write-Output ""
Write-Output "### 2. Provenance aging (commits behind HEAD per verified-at stamp)"
$stamped = 0
$unstamped = @()
foreach ($doc in $docs) {
  $content = Get-Content $doc.FullName -Raw
  $rel = [System.IO.Path]::GetRelativePath((Get-Location), $doc.FullName)
  $m = [regex]::Match($content, '<!-- doc-sync: verified-at ([^ >]+)')
  if ($m.Success) {
    $stamped++
    $sha = $m.Groups[1].Value
    git cat-file -e "$sha^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
      Write-Output ("  {0,6}  {1} (@ {2} - commit not found; history rewritten?)" -f "?", $rel, $sha)
    } else {
      # `rev-list --count A..HEAD` returns a number even when A is on another branch or
      # ahead of HEAD - sometimes 0, which would read as "fully current".
      git merge-base --is-ancestor $sha HEAD 2>$null
      if ($LASTEXITCODE -ne 0) {
        Write-Output ("  {0,6}  {1} (@ {2} - NOT an ancestor of HEAD; stale branch or rebase)" -f "!", $rel, $sha)
      } else {
        $behind = git rev-list --count "$sha..HEAD" 2>$null
        Write-Output ("  {0,6} commits behind  {1} (@ {2})" -f "$behind".Trim(), $rel, $sha)
      }
    }
  } elseif (@("CLAUDE.md", "AGENTS.md", "GEMINI.md", ".cursorrules", ".windsurfrules",
              "copilot-instructions.md") -notcontains (Split-Path $doc.FullName -Leaf)) {
    # Tier A is deliberately never stamped, so listing it under "nothing certifies
    # these" would be a permanent false positive.
    $unstamped += "  $rel"
  }
}
if ($stamped -eq 0) { Write-Output "  (no stamped docs yet)" }

Write-Output ""
Write-Output "### 3. Unstamped (nothing certifies these at all)"
if ($unstamped.Count -gt 0) { $unstamped | ForEach-Object { Write-Output $_ } } else { Write-Output "  none" }

Write-Output ""
Write-Output "summary: $brokenTotal broken reference(s), $stamped stamped doc(s)"

# Under -Strict an INCOMPLETE audit must fail too: a green build off a config that
# could not be read, or a root that is not there, is worse than no check at all.
if ($Strict -and ($brokenTotal -gt 0 -or -not $traversalOk)) { exit 1 }
