#!/usr/bin/env pwsh
# Bootstrap .claude/docs-sync.config.json by scanning the repository.
#
# The config is HAND-MAINTAINED by design: there is no schema, and doc-sync does no
# auto-detection at run time. This script exists only to remove the blank-page problem.
# It emits a starter config from what it can observe — you then edit it, and reviewing
# the "unmapped path" warnings in each run's report is the ongoing maintenance loop.
#
# Everything it writes is a guess about YOUR repo. The `targets` map especially: it
# pairs each code area with every doc root it found, which is deliberately over-broad.
# Narrow it before the first real run.
#
# Usage: doc-sync-init.ps1 [-Force] [-Out <path>] [-Print]
param(
  [switch]$Force,
  [switch]$Print,
  [string]$Out = ".claude/docs-sync.config.json"
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

git rev-parse --show-toplevel 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine("ERROR: not inside a git repository.")
  exit 2
}
$repoRoot = (git rev-parse --show-toplevel).Trim()
Set-Location $repoRoot

if ((Test-Path $Out) -and -not $Force -and -not $Print) {
  [Console]::Error.WriteLine("ERROR: $Out already exists. Re-run with -Force to overwrite, or -Print to preview.")
  exit 2
}

# Tracked files only: gitignored build output is not part of the repo's shape, and
# walking it on a large repo is slow enough to matter.
# -z, not plain `git ls-files`: git C-quotes paths containing a quote, backslash or
# non-ASCII byte, and those quotes would flow into the generated globs. Parity with
# doc-sync-init.sh.
$files = @((git ls-files -z) -split "`0" | Where-Object { $_ })
if ($files.Count -eq 0) {
  [Console]::Error.WriteLine("ERROR: no tracked files — commit something first.")
  exit 2
}

# ---------------------------------------------------------------- detection

# 1. Tier A — agent-instruction files, across every tool that uses one.
$agentRe = '(^|/)(CLAUDE|AGENTS|GEMINI)\.md$|(^|/)\.(cursorrules|windsurfrules|clinerules)$|(^|/)copilot-instructions\.md$'
$agentFiles = @($files | Where-Object { $_ -match $agentRe } | Sort-Object)

# 2. Doc roots — directories that actually contain markdown, plus a root README.
$docRoots = @()
foreach ($d in @("docs", "doc", "documentation", "website/docs", "site/docs", "site/content", "content/docs", "wiki", "handbook")) {
  if ($files | Where-Object { $_ -like "$d/*" -and $_ -like "*.md" }) { $docRoots += $d }
}
$hasReadme = [bool]($files | Where-Object { $_ -ieq "README.md" })

# 3. Top-level directories, used by doc-audit to recognise which backticked tokens in a
#    doc are meant to be repo paths.
$topDirs = @($files | Where-Object { $_ -match '/' } | ForEach-Object { $_.Split('/')[0] } | Sort-Object -Unique)

# doc-audit needs a non-empty list to build its path-recognition regex, but `targets`
# must only ever name directories that actually exist — so the fallback is kept separate.
# (An empty array would not crash PowerShell as it does bash, but it would emit
# topLevelDirs: [] and silently break doc-audit's matching.)
$auditTopDirs = $topDirs
if ($auditTopDirs.Count -eq 0) {
  $auditTopDirs = @("src", "app", "apps", "lib", "libs", "packages", "services", "internal", "cmd", "pkg", "docs", "scripts", "tools", ".github", ".claude")
}

# 4. Code areas — top-level dirs that are not doc roots and not obvious noise.
$noise = @(".git", ".github", ".claude", ".vscode", ".idea", "node_modules", "vendor", "dist", "build", "target", ".venv")
$docRootHeads = @($docRoots | ForEach-Object { $_.Split('/')[0] })
$codeDirs = @($topDirs | Where-Object { $noise -notcontains $_ -and $docRootHeads -notcontains $_ })

# 5. Monorepo children — one target per workspace beats one for the whole `apps/**`
#    tree, since each workspace usually has its own doc.
$workspaceDirs = @()
foreach ($parent in @("apps", "packages", "services", "libs", "modules")) {
  if ($topDirs -notcontains $parent) { continue }
  $workspaceDirs += @($files |
    Where-Object { $_ -like "$parent/*/*" } |
    ForEach-Object { "$parent/" + $_.Split('/')[1] } |
    Sort-Object -Unique)
}

# 6. Manifests worth routing at getting-started docs when their setup steps change.
$manifests = @()
foreach ($m in @("package.json", "pnpm-workspace.yaml", "go.mod", "Cargo.toml", "pyproject.toml", "Gemfile",
                 "composer.json", "build.gradle", "build.gradle.kts", "pom.xml", "Makefile", ".nvmrc", ".tool-versions")) {
  if ($files -contains $m) { $manifests += $m }
}

# 7. Lockfiles present in this repo, added to `ignore` alongside the generic globs.
$locks = @()
foreach ($l in @("package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "Cargo.lock",
                 "poetry.lock", "Gemfile.lock", "composer.lock", "go.sum", "uv.lock")) {
  if ($files | Where-Object { $_ -eq $l -or $_ -like "*/$l" }) { $locks += "**/$l" }
}

# ---------------------------------------------------------------- emit

$docTargets = @($docRoots | ForEach-Object { "$_/**" })
if ($hasReadme) { $docTargets += "README.md" }
if ($docTargets.Count -eq 0) { $docTargets = @("docs/**") }

# Manifest changes are setup changes, so route them at a getting-started doc when the
# repo has one — narrowed to the actual subdirectory or file, not the whole doc root.
$gsPattern = 'getting-started|getting_started|setup|install|quickstart|contributing'
$gsTargets = @()
foreach ($d in $docRoots) {
  $gsTargets += @($files |
    Where-Object { $_ -match "^$([regex]::Escape($d))/[^/]*($gsPattern)[^/]*/" } |
    ForEach-Object { ($_.Split('/')[0..1]) -join '/' } | Sort-Object -Unique |
    ForEach-Object { "$_/**" })
  $gsTargets += @($files |
    Where-Object { $_ -match "^$([regex]::Escape($d))/[^/]*($gsPattern)[^/]*\.md$" } | Sort-Object -Unique)
}
$gsTargets = @($gsTargets | Sort-Object -Unique)
if ($gsTargets.Count -eq 0) { $gsTargets = $docTargets }

$tierAPatterns = @("**/CLAUDE.md", "**/AGENTS.md")
$tierAPatterns += @($agentFiles | Where-Object { @("CLAUDE.md", "AGENTS.md") -notcontains (Split-Path $_ -Leaf) })

# doc-sync's own files are committed in many repos; without these globs the skill
# reports its own installation as a change on every run.
$ignoreGlobs = @("**/*.lock", "**/*.snap", "**/dist/**", "**/build/**", "**/node_modules/**",
                 "**/*.generated.*", ".claude/skills/**", ".claude/docs-sync.*") + $locks
$skipDirs = @("node_modules", "vendor", "archive", "legacy", ".venv", "target", "build", "dist")

# Build the targets array. Most specific first is only a readability convention — the
# skill picks the longest matching glob regardless of order.
$targets = @()
foreach ($w in $workspaceDirs) { $targets += [ordered]@{ code = "$w/**"; docs = $docTargets } }
foreach ($d in $codeDirs) {
  if ($workspaceDirs | Where-Object { $_.Split('/')[0] -eq $d }) { continue }
  $targets += [ordered]@{ code = "$d/**"; docs = $docTargets }
}
foreach ($m in $manifests) { $targets += [ordered]@{ code = $m; docs = $gsTargets } }
# CI config is excluded from codeDirs as infrastructure rather than a code area, but a
# changed pipeline is exactly what dates a deployment or getting-started doc.
if ($files | Where-Object { $_ -like ".github/workflows/*" }) {
  $targets += [ordered]@{ code = ".github/workflows/**"; docs = $docTargets }
}

$config = [ordered]@{
  "_comment" = "doc-sync seam — hand-written, no schema and no auto-detection at run time. Generated by doc-sync-init.ps1; the targets map below is a starting point, not a mapping. See .claude/skills/doc-sync/SKILL.md."
  baseline = [ordered]@{ strategy = "lastTag"; fallback = "previousTagOrNCommits" }
  ignore = $ignoreGlobs
  tierA = [ordered]@{
    comment = "Agent instructions — ALWAYS escalate, never auto-edit. Matched by glob so a newly added file is caught before anyone updates this list."
    patterns = $tierAPatterns
  }
  targets = $targets
  targetsNote = "GENERATED — narrow this. Each code area was paired with every doc root found, which is over-broad on purpose so nothing is silently unmapped on day one. When a changed path matches more than one 'code' glob, the most specific (longest) match wins."
  locales = @("en")
  datedDocs = @()
  neverAutoEdit = @("**/terms*", "**/terms*/**", "**/privacy*", "**/privacy*/**", "**/LICENSE*")
  neverAutoEditNote = "Published legal and policy documents. ESCALATE-ONLY, treated like Tier A no matter how confident the edit looks. Three effects compound: editing one is a legal act rather than a doc refresh; the 'locales' rule would rewrite the translated variants with no native speaker reviewing them; and 'datedDocs' would then stamp the result as freshly updated, which is precisely the signal a reader trusts."
  commitWeights = [ordered]@{ feat = "B"; fix = "B"; refactor = "none"; chore = "none"; docs = "none"; test = "none"; style = "none" }
  commitWeightsNote = "Tier-B noise filter ONLY. It never suppresses the Tier A scan — a chore: or refactor: commit can still add an agent-instruction file. Drop this key entirely if the repo does not use conventional commits."
  driftThreshold = [ordered]@{
    commits = 15
    days = 14
    "_note" = "check-drift nudges only past these — a watermark that fires on every commit trains itself into being ignored."
  }
  provenance = [ordered]@{
    "_comment" = "NOTE: ``stamp`` is documentation, not configuration. The literal is hardcoded in stamp-verified.{sh,ps1} and in doc-audit.{sh,ps1}'s matching; changing it here changes nothing."
    stamp = "<!-- doc-sync: verified-at {sha} -->"
    rule = "THE STAMP IS THE CERTIFICATION, NOT THE BASELINE. Every Tier B doc verified in a run — edited, or checked and found current — gets stamped with the HEAD sha via scripts/stamp-verified.sh. A doc the run never looked at keeps its old stamp and stays visibly stale in doc-audit's aging report, instead of being silently certified by a baseline bump it never participated in. Never stamp Tier A files. The baseline in docs-sync.state.json is a scheduling hint: it bounds the next diff, it does not assert completeness."
  }
  docAudit = [ordered]@{
    "_comment" = "Read by doc-audit.{sh,ps1}. roots = doc trees to walk. topLevelDirs = this repo's top-level directories, used to recognise which backticked tokens are meant to be repo paths. skipDirs = vendored or unmaintained trees."
    roots = $(if ($docRoots.Count) { $docRoots } else { @("docs") })
    topLevelDirs = $auditTopDirs
    skipDirs = $skipDirs
  }
}

$json = $config | ConvertTo-Json -Depth 10

if ($Print) { Write-Output $json; exit 0 }

$outDir = Split-Path $Out -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
Set-Content -Path $Out -Value $json

# ---------------------------------------------------------------- report

Write-Output "doc-sync init — scanned $($files.Count) tracked files"
Write-Output ""
if ($agentFiles.Count -gt 0) {
  Write-Output "  Tier A (agent instructions):"
  $agentFiles | ForEach-Object { Write-Output "    $_" }
} else {
  Write-Output "  Tier A: none found — the **/CLAUDE.md and **/AGENTS.md globs will catch one when added."
}
Write-Output ""
Write-Output "  doc roots:      $(if ($docRoots.Count) { $docRoots -join ' ' } else { 'none found (defaulted to docs/)' })"
Write-Output "  code areas:     $($codeDirs.Count) top-level, $($workspaceDirs.Count) workspace"
Write-Output "  manifests:      $(if ($manifests.Count) { $manifests -join ' ' } else { 'none' })"
Write-Output ""
Write-Output "wrote $Out"
Write-Output ""
# An empty targets map is not a benign default — see doc-sync-init.sh for the reasoning.
if ($codeDirs.Count -eq 0 -and $workspaceDirs.Count -eq 0 -and $manifests.Count -eq 0) {
  Write-Output "WARNING: nothing could be mapped — the 'targets' list is EMPTY."
  Write-Output "         This usually means the code sits at the repository root rather than"
  Write-Output "         in subdirectories. Add at least one entry by hand: until you do,"
  Write-Output "         doc-sync has no Tier B routing, and it will refuse to report the"
  Write-Output "         docs as in sync or advance the baseline."
  Write-Output ""
}
Write-Output "Next:"
Write-Output "  1. Edit $Out — the 'targets' map is over-broad by design. Narrow it."
Write-Output "  2. Replace the Tier A examples in references/classification.md with real"
Write-Output "     conventions from this repo. They calibrate what counts as a rule change."
Write-Output "  3. pwsh .claude/skills/doc-sync/scripts/doc-audit.ps1   # every doc should list as unstamped"
Write-Output "  4. /doc-sync --report-only                              # impact table, writes nothing"
