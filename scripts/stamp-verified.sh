#!/usr/bin/env bash
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
# future agent session reads. The default names are refused below, but the rule belongs
# to the skill — a repo with unusual Tier A filenames must still honour it.
#
# Usage: stamp-verified.sh <sha> <file.md> [file.md ...]
set -euo pipefail

SHA="${1:?usage: stamp-verified.sh <sha> <file.md> [file.md ...]}"
shift
[ "$#" -ge 1 ] || { echo "ERROR: no files given" >&2; exit 2; }

STAMPED=0
MISSING=0
SHORT_SHA="$(git rev-parse --short "${SHA}" 2>/dev/null || echo "${SHA}")"
STAMP="<!-- doc-sync: verified-at ${SHORT_SHA} -->"

for f in "$@"; do
  if [ ! -f "${f}" ]; then
    echo "SKIP (missing): ${f}" >&2
    MISSING=$((MISSING + 1))
    continue
  fi
  case "$(basename "${f}")" in
    CLAUDE.md | AGENTS.md | GEMINI.md | .cursorrules | .windsurfrules | copilot-instructions.md)
      echo "SKIP (Tier A is never stamped): ${f}" >&2
      continue
      ;;
  esac
  if grep -q '<!-- doc-sync: verified-at ' "${f}"; then
    # Portable in-place replace — BSD and GNU sed disagree on -i.
    #
    # Write the result back through `cat >`, never `mv`. A `mv` would replace the file
    # with the temp one, so the doc would silently inherit mktemp's 0600 and lose its
    # own mode — and a symlinked doc would be replaced by a regular file. Neither shows
    # up in a git diff (git tracks only the exec bit), so it would break shared
    # checkouts and CI invisibly. `cat >` truncates the original in place, keeping its
    # inode, mode, ownership, and symlink target.
    tmp="$(mktemp)"
    sed "s|<!-- doc-sync: verified-at [^>]*-->|${STAMP}|" "${f}" > "${tmp}"
    cat "${tmp}" > "${f}"
    rm -f "${tmp}"
  else
    printf '\n%s\n' "${STAMP}" >> "${f}"
  fi
  STAMPED=$((STAMPED + 1))
  echo "stamped ${f} @ ${SHORT_SHA}"
done

# Exiting 0 after stamping nothing lets the caller advance state and write history as if
# certification happened. A file that was skipped because it does not exist is a real
# failure; a Tier A skip is expected and does not count against the run.
if [ "${MISSING}" -gt 0 ] && [ "${STAMPED}" -eq 0 ]; then
  echo "ERROR: nothing was stamped (${MISSING} file(s) missing). Not a successful certification." >&2
  exit 3
fi
echo "stamped ${STAMPED} file(s); ${MISSING} missing"
