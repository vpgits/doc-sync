#!/usr/bin/env bash
# Deterministic doc staleness detection — no LLM involved.
#
# Two checks over every markdown file in the given roots:
#   1. Reference rot: backticked tokens that look like repo paths are existence-checked
#      against the working tree at HEAD. A doc citing a file that no longer exists is
#      stale by construction — no mapping and no model needed.
#   2. Provenance aging: per-doc `<!-- doc-sync: verified-at <sha> -->` stamps are
#      resolved to "commits behind HEAD". Unstamped docs are listed separately, because
#      the absence of a stamp means nothing certifies that doc at all.
#
# This is the safety net under the model's judgment: it catches what the hand-maintained
# `targets` map missed. Cheap enough to run in CI with --strict.
#
# Configuration is read from .claude/docs-sync.config.json under `docAudit`
# (roots, topLevelDirs, skipDirs) when jq or python3 is available; otherwise the
# built-in defaults below apply. Command-line roots always win.
#
# Exit 0 always, unless --strict, which exits 1 when broken references exist.
#
# Usage: doc-audit.sh [--strict] [root ...]
set -euo pipefail

CONFIG_FILE=".claude/docs-sync.config.json"

# Built-in fallbacks, used when the config is missing or unreadable without a JSON tool.
DEFAULT_ROOTS=(docs)
DEFAULT_TOP_LEVEL_DIRS=(src app apps lib libs packages services internal cmd pkg docs scripts tools .github .claude)
DEFAULT_SKIP_DIRS=(node_modules vendor archive legacy .venv target build dist)

# Read a JSON array from the config. No jq dependency is assumed: jq is used when
# present, python3 otherwise, and the caller falls back to defaults if neither is.
read_config_array() {
  [ -f "${CONFIG_FILE}" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -er --arg p "$1" '[getpath($p | split("."))] | flatten | map(select(. != null)) | .[]' \
      "${CONFIG_FILE}" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "${CONFIG_FILE}" "$1" <<'PY' 2>/dev/null
import json, sys
node = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    if not isinstance(node, dict) or key not in node:
        sys.exit(1)
    node = node[key]
if not isinstance(node, list) or not node:
    sys.exit(1)
print("\n".join(str(x) for x in node))
PY
  else
    return 1
  fi
}

# Whether the config was actually consulted. Falling back to built-in defaults silently
# is the dangerous case: a configured second doc root simply vanishes from the report
# and from --strict, and the run still exits 0 looking healthy.
CONFIG_READ=true
CONFIG_ERROR=""
if [ -f "${CONFIG_FILE}" ]; then
  if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    CONFIG_READ=false
    CONFIG_ERROR="neither jq nor python3 is available to read it"
  elif command -v jq >/dev/null 2>&1; then
    if ! jq -e . "${CONFIG_FILE}" >/dev/null 2>&1; then
      CONFIG_READ=false
      CONFIG_ERROR="the file is not valid JSON"
    fi
  elif ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${CONFIG_FILE}" >/dev/null 2>&1; then
    CONFIG_READ=false
    CONFIG_ERROR="the file is not valid JSON"
  fi
fi

# Populate an array from config, leaving the caller's default in place on failure.
load_into() {  # load_into <array-name> <config.path>
  local name="$1" path="$2" line
  local -a collected=()
  while IFS= read -r line; do
    [ -n "${line}" ] && collected+=("${line}")
  done < <(read_config_array "${path}" || true)
  [ "${#collected[@]}" -gt 0 ] || return 0
  eval "${name}=(\"\${collected[@]}\")"
}

STRICT=false
ROOTS=()
for arg in "$@"; do
  case "${arg}" in
    --strict) STRICT=true ;;
    -h | --help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ROOTS+=("${arg}") ;;
  esac
done

CONFIG_ROOTS=("${DEFAULT_ROOTS[@]}")
TOP_LEVEL_DIRS=("${DEFAULT_TOP_LEVEL_DIRS[@]}")
SKIP_DIRS=("${DEFAULT_SKIP_DIRS[@]}")
load_into CONFIG_ROOTS docAudit.roots
load_into TOP_LEVEL_DIRS docAudit.topLevelDirs
load_into SKIP_DIRS docAudit.skipDirs

# Command-line roots override the config; the config overrides the built-in default.
[ "${#ROOTS[@]}" -gt 0 ] || ROOTS=("${CONFIG_ROOTS[@]}")

# Build the "looks like a repo path" regex from the repo's own top-level directories.
# A token only counts as a path claim if it starts with one of them — otherwise every
# backticked identifier in every doc would be probed.
#
# Every ERE metacharacter has to be escaped, not just the dot: a directory named `c++`
# or `my(app)` would otherwise make grep fail with "repetition-operator operand
# invalid", and because that error goes to stderr while the loop carries on, the audit
# would print "none found" and exit 0 over a repo full of broken references.
esc_ere() { printf '%s' "$1" | sed 's#[]\.[*^$+?(){}|/\\-]#\\&#g'; }
TOP_RE=""
for d in "${TOP_LEVEL_DIRS[@]}"; do
  TOP_RE="${TOP_RE}$(esc_ere "${d}")|"
done
TOP_RE="${TOP_RE%|}"

# Root-level files a doc commonly cites. Without these the matcher requires a
# directory prefix, so `package.json`, `Makefile` or `README.md` are never checked at
# all — and the report still claims a clean bill of health.
ROOT_FILES=(package.json package-lock.json pnpm-workspace.yaml tsconfig.json go.mod go.sum
            Cargo.toml pyproject.toml setup.py requirements.txt Gemfile composer.json
            Makefile Dockerfile docker-compose.yml docker-compose.yaml README.md LICENSE
            CONTRIBUTING.md CHANGELOG.md .nvmrc .tool-versions .editorconfig .gitignore)
ROOT_FILE_RE=""
for f in "${ROOT_FILES[@]}"; do
  ROOT_FILE_RE="${ROOT_FILE_RE}$(esc_ere "${f}")|"
done
ROOT_FILE_RE="${ROOT_FILE_RE%|}"

FIND_EXCLUDES=()
for d in "${SKIP_DIRS[@]}"; do FIND_EXCLUDES+=(-not -path "*/${d}/*"); done

REPO_ROOT="$(git rev-parse --show-toplevel)"
HEAD_SHA="$(git rev-parse --short HEAD)"
BROKEN_TOTAL=0
TRAVERSAL_OK=true

echo "## doc-audit @ ${HEAD_SHA}"
echo
if [ "${CONFIG_READ}" != true ]; then
  echo "WARNING: ${CONFIG_FILE} could not be used — ${CONFIG_ERROR}."
  echo "         Using built-in defaults — your configured roots, topLevelDirs and"
  echo "         skipDirs are NOT in effect, so this report may be incomplete."
  echo
fi
echo "### 1. Reference rot (cited paths that do not exist)"

for root in "${ROOTS[@]}"; do
  if [ ! -e "${root}" ]; then
    # A configured root that is not there means the audit covered less than it was told
    # to. Reporting "none found" and exiting 0 would turn a renamed docs directory into
    # a permanently green CI check.
    echo "  WARNING: configured root does not exist: ${root} — this report is INCOMPLETE"
    TRAVERSAL_OK=false
    continue
  fi
  while IFS= read -r doc; do
    BROKEN=""
    # Backticked tokens that look like repo paths: start with a known top-level dir,
    # contain a slash, and carry no spaces, globs, or placeholders — those are
    # patterns being described, not paths being cited.
    while IFS= read -r token; do
      case "${token}" in
        *'*'* | *'{'* | *'<'* | *' '* | *'…'* | *'...'*) continue ;;
      esac
      # Strip :line[-range] suffixes and a trailing / on directory references.
      probe="$(printf '%s' "${token}" | sed 's/:[0-9][0-9,-]*$//')"
      probe="${probe%/}"
      if [ ! -e "${REPO_ROOT}/${probe}" ]; then
        # A missing path that is GITIGNORED is a documented local artifact — .env
        # files, generated project dirs, machine-local configs. That is setup
        # instructions, not reference rot.
        if git -C "${REPO_ROOT}" check-ignore -q "${probe}" 2>/dev/null; then
          continue
        fi
        BROKEN="${BROKEN}    ✗ ${token}\n"
      fi
    done < <(grep -o '`[^`]*`' "${doc}" 2>/dev/null | tr -d '`' \
             | grep -E "^((${TOP_RE})/[^ ]+|${ROOT_FILE_RE})$" \
             | sort -u)
    if [ -n "${BROKEN}" ]; then
      count="$(printf '%b' "${BROKEN}" | grep -c '✗' || true)"
      BROKEN_TOTAL=$((BROKEN_TOTAL + count))
      echo "  ${doc}:"
      printf '%b' "${BROKEN}"
    fi
  done < <(find "${root}" -name '*.md' "${FIND_EXCLUDES[@]}" 2>/dev/null | sort)
  # A find that failed part-way (unreadable subtree) exits non-zero inside the process
  # substitution, where `set -e` cannot see it. Re-run it cheaply to detect that, so a
  # partial walk is never reported as a clean one.
  if ! find "${root}" -name '*.md' "${FIND_EXCLUDES[@]}" >/dev/null 2>&1; then
    echo "  WARNING: could not fully traverse ${root} (permissions?) — this report is INCOMPLETE"
    TRAVERSAL_OK=false
  fi
done
[ "${BROKEN_TOTAL}" -eq 0 ] && [ "${TRAVERSAL_OK}" = true ] && echo "  none found"
echo "  (dirs skipped: ${SKIP_DIRS[*]})"

echo
echo "### 2. Provenance aging (commits behind HEAD per verified-at stamp)"
STAMPED=0
UNSTAMPED=""
for root in "${ROOTS[@]}"; do
  [ -e "${root}" ] || continue
  while IFS= read -r doc; do
    sha="$(grep -o '<!-- doc-sync: verified-at [^ >]*' "${doc}" 2>/dev/null | awk '{print $NF}' | head -1 || true)"
    if [ -n "${sha}" ]; then
      STAMPED=$((STAMPED + 1))
      if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
        printf '  %6s  %s (@ %s — commit not found; history rewritten?)\n' "?" "${doc}" "${sha}"
      elif ! git merge-base --is-ancestor "${sha}" HEAD 2>/dev/null; then
        # `rev-list --count A..HEAD` happily returns a number when A is on another
        # branch or ahead of HEAD — sometimes 0, which would read as "fully current".
        # Only an ancestor can be meaningfully counted behind.
        printf '  %6s  %s (@ %s — NOT an ancestor of HEAD; stale branch or rebase)\n' "!" "${doc}" "${sha}"
      else
        behind="$(git rev-list --count "${sha}..HEAD" 2>/dev/null || echo '?')"
        printf '  %6s commits behind  %s (@ %s)\n' "${behind}" "${doc}" "${sha}"
      fi
    else
      # Tier A files are deliberately never stamped (they are agent instructions, not
      # documentation). Listing them under "nothing certifies these" would be a
      # permanent false positive that nudges a reader toward the one action the
      # never-stamp rule forbids.
      case "$(basename "${doc}")" in
        CLAUDE.md | AGENTS.md | GEMINI.md | .cursorrules | .windsurfrules | copilot-instructions.md)
          ;;
        *)
          UNSTAMPED="${UNSTAMPED}  ${doc}\n"
          ;;
      esac
    fi
  done < <(find "${root}" -name '*.md' "${FIND_EXCLUDES[@]}" | sort)
done
[ "${STAMPED}" -eq 0 ] && echo "  (no stamped docs yet)"

echo
echo "### 3. Unstamped (nothing certifies these at all)"
if [ -n "${UNSTAMPED}" ]; then printf '%b' "${UNSTAMPED}"; else echo "  none"; fi

echo
echo "summary: ${BROKEN_TOTAL} broken reference(s), ${STAMPED} stamped doc(s)"

if [ "${STRICT}" = true ] && { [ "${BROKEN_TOTAL}" -gt 0 ] || [ "${TRAVERSAL_OK}" != true ] || [ "${CONFIG_READ}" != true ]; }; then
  # Under --strict an INCOMPLETE audit must fail too. A green build off a partial walk,
  # or off a config that could not be read, is worse than no check at all.
  exit 1
fi
