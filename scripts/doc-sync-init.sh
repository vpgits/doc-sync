#!/usr/bin/env bash
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
# Usage: doc-sync-init.sh [--force] [--out <path>] [--print]
set -euo pipefail

FORCE=false
PRINT_ONLY=false
OUT=".claude/docs-sync.config.json"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --print) PRINT_ONLY=true; shift ;;
    --out) OUT="${2:?--out needs a path}"; shift 2 ;;
    -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

git rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "ERROR: not inside a git repository." >&2
  exit 2
}
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

if [ -f "${OUT}" ] && [ "${FORCE}" != true ] && [ "${PRINT_ONLY}" != true ]; then
  echo "ERROR: ${OUT} already exists. Re-run with --force to overwrite, or --print to preview." >&2
  exit 2
fi

# Tracked files only: gitignored build output is not part of the repo's shape, and
# walking it on a large repo is slow enough to matter.
# NUL-delimited, read one record at a time. Plain `git ls-files` C-QUOTES any path
# containing a quote, backslash or non-ASCII byte, emitting `"weird\"dir/a.ts"` rather
# than the real path, and those quotes then flow into the generated globs.
#
# A path containing a control character cannot survive the processing below. A literal
# newline would be split into two fake paths by the line-based loops; a tab or carriage
# return survives that far but is then stripped by json_escape, quietly turning
# `tab<TAB>dir/a.ts` into a target for a `tabdir/**` that does not exist. Either way the
# generated config ends up naming something real, which is worse than naming nothing.
# Drop them and say so.
FILES=""
NEWLINE_PATHS=0
while IFS= read -r -d '' _p; do
  if printf '%s' "${_p}" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    NEWLINE_PATHS=$((NEWLINE_PATHS + 1)); continue
  fi
  FILES="${FILES}${_p}
"
done < <(git ls-files -z)
FILES="${FILES%
}"
[ -n "${FILES}" ] || { echo "ERROR: no tracked files — commit something first." >&2; exit 2; }
if [ "${NEWLINE_PATHS}" -gt 0 ]; then
  echo "WARNING: ${NEWLINE_PATHS} tracked path(s) contain a control character (newline," >&2
  echo "         tab, or carriage return) and were excluded from this scan. Add any doc" >&2
  echo "         target for them by hand." >&2
fi

# ---------------------------------------------------------------- detection

# 1. Tier A — agent-instruction files, across every tool that uses one.
AGENT_FILES="$(printf '%s\n' "${FILES}" | grep -E \
  '(^|/)(CLAUDE|AGENTS|GEMINI)\.md$|(^|/)\.(cursorrules|windsurfrules|clinerules)$|(^|/)copilot-instructions\.md$' \
  | sort || true)"

# 2. Doc roots — directories that actually contain markdown, plus a root README.
DOC_ROOTS=()
for d in docs doc documentation website/docs site/docs site/content content/docs wiki handbook; do
  if printf '%s\n' "${FILES}" | grep -q "^${d}/.*\.md$"; then DOC_ROOTS+=("${d}"); fi
done
HAS_README=false
printf '%s\n' "${FILES}" | grep -qi '^README\.md$' && HAS_README=true

# 3. Top-level directories, used by doc-audit to recognise which backticked tokens in a
#    doc are meant to be repo paths.
TOP_DIRS=()
while IFS= read -r d; do
  [ -n "${d}" ] && TOP_DIRS+=("${d}")
done < <(printf '%s\n' "${FILES}" | awk -F/ 'NF > 1 { print $1 }' | sort -u)
# doc-audit needs a non-empty list to build its path-recognition regex, but `targets`
# must only ever name directories that actually exist — so the fallback is kept separate.
AUDIT_TOP_DIRS=(${TOP_DIRS[@]+"${TOP_DIRS[@]}"})
if [ "${#AUDIT_TOP_DIRS[@]}" -eq 0 ]; then
  AUDIT_TOP_DIRS=(src app apps lib libs packages services internal cmd pkg docs scripts tools .github .claude)
fi

# 4. Code areas — top-level dirs that are not doc roots and not obvious noise.
is_doc_root() { local c; for c in ${DOC_ROOTS[@]+"${DOC_ROOTS[@]}"}; do [ "$1" = "${c%%/*}" ] && return 0; done; return 1; }
CODE_DIRS=()
for d in ${TOP_DIRS[@]+"${TOP_DIRS[@]}"}; do
  case "${d}" in
    .git | .github | .claude | .vscode | .idea | node_modules | vendor | dist | build | target | .venv) continue ;;
  esac
  is_doc_root "${d}" && continue
  CODE_DIRS+=("${d}")
done

# 5. Monorepo children — one target per workspace beats one for the whole `apps/**`
#    tree, since each workspace usually has its own doc.
WORKSPACE_DIRS=()
for parent in apps packages services libs modules; do
  printf '%s\n' ${TOP_DIRS[@]+"${TOP_DIRS[@]}"} | grep -qx "${parent}" || continue
  while IFS= read -r child; do
    [ -n "${child}" ] && WORKSPACE_DIRS+=("${parent}/${child}")
  done < <(printf '%s\n' "${FILES}" | awk -F/ -v p="${parent}" 'NF > 2 && $1 == p { print $2 }' | sort -u)
done

# 6. Manifests worth routing at getting-started docs when their setup steps change.
MANIFESTS=()
for m in package.json pnpm-workspace.yaml go.mod Cargo.toml pyproject.toml Gemfile \
         composer.json build.gradle build.gradle.kts pom.xml Makefile .nvmrc .tool-versions; do
  printf '%s\n' "${FILES}" | grep -qx "${m}" && MANIFESTS+=("${m}")
done

# 7. Lockfiles present in this repo, added to `ignore` alongside the generic globs.
LOCKS=()
for l in package-lock.json pnpm-lock.yaml yarn.lock bun.lockb Cargo.lock poetry.lock \
         Gemfile.lock composer.lock go.sum uv.lock; do
  printf '%s\n' "${FILES}" | grep -q "\(^\|/\)${l}$" && LOCKS+=("**/${l}")
done

# ---------------------------------------------------------------- emit

# Escape a string for embedding in JSON. Git permits quotes, backslashes and spaces in
# paths; interpolating one raw emits a config that does not parse, and the model then
# fails on it at read time, far from the cause. Control bytes are stripped rather than
# escaped — a path containing one has no business becoming a config glob.
json_escape() {
  printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Render a JSON string array, indented, one element per line.
json_lines() {  # json_lines <indent> <item>...
  local indent="$1"; shift
  local i first=1
  [ "$#" -eq 0 ] && { printf '[]'; return; }
  printf '[\n'
  for i in "$@"; do
    # Emit with %s, never %b: %b re-interprets escape sequences, so the \\ that
    # json_escape just produced would collapse back to a single \ and the config would
    # not parse. Separators are printed explicitly instead of buffered.
    [ "${first}" -eq 1 ] && first=0 || printf ',\n'
    printf '%s  "%s"' "${indent}" "$(json_escape "${i}")"
  done
  printf '\n%s]' "${indent}"
}

# Every doc root, plus the README, as the fallback doc destination for a code area.
DOC_TARGETS=()
for d in ${DOC_ROOTS[@]+"${DOC_ROOTS[@]}"}; do DOC_TARGETS+=("${d}/**"); done
[ "${HAS_README}" = true ] && DOC_TARGETS+=("README.md")
[ "${#DOC_TARGETS[@]}" -gt 0 ] || DOC_TARGETS=("docs/**")

# Manifest changes are setup changes, so route them at a getting-started doc when the
# repo has one — narrowed to the actual subdirectory or file, not the whole doc root.
GS_PATTERN='getting-started|getting_started|getting started|setup|install|quickstart|contributing'
GS_TARGETS=()
for d in ${DOC_ROOTS[@]+"${DOC_ROOTS[@]}"}; do
  while IFS= read -r sub; do
    [ -n "${sub}" ] && GS_TARGETS+=("${sub}/**")
  done < <(printf '%s\n' "${FILES}" | grep -iE "^${d}/[^/]*(${GS_PATTERN})[^/]*/" \
           | awk -F/ '{ print $1"/"$2 }' | sort -u)
  while IFS= read -r file; do
    [ -n "${file}" ] && GS_TARGETS+=("${file}")
  done < <(printf '%s\n' "${FILES}" | grep -iE "^${d}/[^/]*(${GS_PATTERN})[^/]*\.md$" | sort -u)
done
[ "${#GS_TARGETS[@]}" -gt 0 ] || GS_TARGETS=("${DOC_TARGETS[@]}")

TIER_A_PATTERNS=("**/CLAUDE.md" "**/AGENTS.md")
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  case "$(basename "${f}")" in
    CLAUDE.md | AGENTS.md) continue ;;
    *) TIER_A_PATTERNS+=("${f}") ;;
  esac
done <<AGENTEOF
${AGENT_FILES}
AGENTEOF

# doc-sync's own files are committed in many repos; without these globs the skill
# reports its own installation as a change on every run.
IGNORE_GLOBS=("**/*.lock" "**/*.snap" "**/dist/**" "**/build/**" "**/node_modules/**" \
              "**/*.generated.*" ".claude/skills/**" ".claude/docs-sync.*")
for l in ${LOCKS[@]+"${LOCKS[@]}"}; do IGNORE_GLOBS+=("${l}"); done

SKIP_DIRS=(node_modules vendor archive legacy .venv target build dist)

CONFIG="$(cat <<JSON
{
  "_comment": "doc-sync seam — hand-written, no schema and no auto-detection at run time. Generated by doc-sync-init.sh; the targets map below is a starting point, not a mapping. See .claude/skills/doc-sync/SKILL.md.",

  "baseline": { "strategy": "lastTag", "fallback": "previousTagOrNCommits" },

  "ignore": $(json_lines "  " "${IGNORE_GLOBS[@]}"),

  "tierA": {
    "comment": "Agent instructions — ALWAYS escalate, never auto-edit. Matched by glob so a newly added file is caught before anyone updates this list.",
    "patterns": $(json_lines "    " "${TIER_A_PATTERNS[@]}")
  },

  "targets": [
$(
  first=true
  emit() {
    [ "${first}" = true ] && first=false || printf ',\n'
    printf '    { "code": "%s", "docs": %s }' "$(json_escape "$1")" "$2"
  }
  # Most specific first is only a readability convention — the skill picks the
  # longest matching glob regardless of order.
  for w in ${WORKSPACE_DIRS[@]+"${WORKSPACE_DIRS[@]}"}; do emit "${w}/**" "$(json_lines "" "${DOC_TARGETS[@]}" | tr -d '\n' | sed 's/  */ /g')"; done
  for d in ${CODE_DIRS[@]+"${CODE_DIRS[@]}"}; do
    skip=false
    for w in ${WORKSPACE_DIRS[@]+"${WORKSPACE_DIRS[@]}"}; do [ "${w%%/*}" = "${d}" ] && skip=true; done
    [ "${skip}" = true ] && continue
    emit "${d}/**" "$(json_lines "" "${DOC_TARGETS[@]}" | tr -d '\n' | sed 's/  */ /g')"
  done
  for m in ${MANIFESTS[@]+"${MANIFESTS[@]}"}; do emit "${m}" "$(json_lines "" "${GS_TARGETS[@]}" | tr -d '\n' | sed 's/  */ /g')"; done
  # CI config is excluded from CODE_DIRS as infrastructure rather than a code area, but
  # a changed pipeline is exactly what dates a deployment or getting-started doc.
  if printf '%s\n' "${FILES}" | grep -q '^\.github/workflows/'; then
    emit ".github/workflows/**" "$(json_lines "" "${DOC_TARGETS[@]}" | tr -d '\n' | sed 's/  */ /g')"
  fi
  printf '\n'
)
  ],
  "targetsNote": "GENERATED — narrow this. Each code area was paired with every doc root found, which is over-broad on purpose so nothing is silently unmapped on day one. When a changed path matches more than one 'code' glob, the most specific (longest) match wins.",

  "locales": ["en"],
  "datedDocs": [],
  "neverAutoEdit": ["**/terms*", "**/terms*/**", "**/privacy*", "**/privacy*/**", "**/LICENSE*"],
  "neverAutoEditNote": "Published legal and policy documents. ESCALATE-ONLY, treated like Tier A no matter how confident the edit looks. Three effects compound: editing one is a legal act rather than a doc refresh; the 'locales' rule would rewrite the translated variants with no native speaker reviewing them; and 'datedDocs' would then stamp the result as freshly updated, which is precisely the signal a reader trusts.",

  "commitWeights": {
    "feat": "B",
    "fix": "B",
    "refactor": "none",
    "chore": "none",
    "docs": "none",
    "test": "none",
    "style": "none"
  },
  "commitWeightsNote": "Tier-B noise filter ONLY. It never suppresses the Tier A scan — a chore: or refactor: commit can still add an agent-instruction file. Drop this key entirely if the repo does not use conventional commits.",

  "driftThreshold": {
    "commits": 15,
    "days": 14,
    "_note": "check-drift nudges only past these — a watermark that fires on every commit trains itself into being ignored."
  },

  "provenance": {
    "_comment": "NOTE: the stamp field below is documentation, not configuration. The literal is hardcoded in stamp-verified.{sh,ps1} and in doc-audit.{sh,ps1}'s grep; changing it here changes nothing. If you edit it, edit those four scripts to match or the audit will stop recognising its own stamps.",
    "stamp": "<!-- doc-sync: verified-at {sha} -->",
    "rule": "THE STAMP IS THE CERTIFICATION, NOT THE BASELINE. Every Tier B doc verified in a run — edited, or checked and found current — gets stamped with the HEAD sha via scripts/stamp-verified.sh. A doc the run never looked at keeps its old stamp and stays visibly stale in doc-audit's aging report, instead of being silently certified by a baseline bump it never participated in. Never stamp Tier A files. The baseline in docs-sync.state.json is a scheduling hint: it bounds the next diff, it does not assert completeness."
  },

  "docAudit": {
    "_comment": "Read by doc-audit.{sh,ps1}. roots = doc trees to walk. topLevelDirs = this repo's top-level directories, used to recognise which backticked tokens are meant to be repo paths. skipDirs = vendored or unmaintained trees.",
    "roots": $(json_lines "    " "${DOC_ROOTS[@]:-docs}"),
    "topLevelDirs": $(json_lines "    " "${AUDIT_TOP_DIRS[@]}"),
    "skipDirs": $(json_lines "    " "${SKIP_DIRS[@]}")
  }
}
JSON
)"

if [ "${PRINT_ONLY}" = true ]; then
  printf '%s\n' "${CONFIG}"
  exit 0
fi

mkdir -p "$(dirname "${OUT}")"
printf '%s\n' "${CONFIG}" > "${OUT}"

# ---------------------------------------------------------------- report

echo "doc-sync init — scanned $(printf '%s\n' "${FILES}" | wc -l | tr -d ' ') tracked files"
echo
if [ -n "${AGENT_FILES}" ]; then
  echo "  Tier A (agent instructions):"
  printf '%s\n' "${AGENT_FILES}" | sed 's/^/    /'
else
  echo "  Tier A: none found — the **/CLAUDE.md and **/AGENTS.md globs will catch one when added."
fi
echo
echo "  doc roots:      ${DOC_ROOTS[*]:-none found (defaulted to docs/)}"
echo "  code areas:     ${#CODE_DIRS[@]} top-level, ${#WORKSPACE_DIRS[@]} workspace"
echo "  manifests:      ${MANIFESTS[*]:-none}"
echo
echo "wrote ${OUT}"
echo
# An empty targets map is not a benign default: with nothing mapped, every run reaches
# the skill's "nothing meaningful remains" exit and reports the repo as in sync forever.
# SKILL.md guards against acting on it, but the developer has to know to fix it.
if [ "${#CODE_DIRS[@]}" -eq 0 ] && [ "${#WORKSPACE_DIRS[@]}" -eq 0 ] && [ "${#MANIFESTS[@]}" -eq 0 ]; then
  echo "WARNING: nothing could be mapped — the 'targets' list is EMPTY."
  echo "         This usually means the code sits at the repository root rather than in"
  echo "         subdirectories. Add at least one { \"code\": ..., \"docs\": ... } entry"
  echo "         by hand: until you do, doc-sync has no Tier B routing, and it will"
  echo "         refuse to report the docs as in sync or advance the baseline."
  echo
fi
echo "Next:"
echo "  1. Edit ${OUT} — the 'targets' map is over-broad by design. Narrow it."
echo "  2. Replace the Tier A examples in references/classification.md with real"
echo "     conventions from this repo. They calibrate what counts as a rule change."
echo "  3. bash .claude/skills/doc-sync/scripts/doc-audit.sh   # should list every doc as unstamped"
echo "  4. /doc-sync --report-only                             # impact table, writes nothing"
