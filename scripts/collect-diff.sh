#!/usr/bin/env bash
# Emit the raw git data doc-sync needs between a baseline ref and HEAD.
#
# Deterministic plumbing only — ignore-glob filtering and classification are done by
# the skill (the model), not here. This output is the authoritative file list; the
# skill must never substitute an ad-hoc `git diff` with its own grep filters, because
# filtering before classification silently drops files.
#
# It emits the PATCH as well as the file list. The skill asks the model to decide
# whether a documented claim is now false, and to judge a change's intent — neither is
# possible from names and line counts alone, and without the patch here the model would
# have to run its own git commands, which is exactly what this script exists to prevent.
# Commits are printed WITH their own changed files so `commitWeights` can be applied per
# commit rather than guessed across a whole range.
#
# Usage: collect-diff.sh <base-ref> [head-ref] [--max-patch-bytes N]
#        default cap: 400000 bytes of patch (0 disables the patch section entirely)
set -euo pipefail

BASE=""
HEAD_REF="HEAD"
MAX_PATCH=400000
POSITIONAL=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-patch-bytes) MAX_PATCH="${2:?--max-patch-bytes needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      POSITIONAL=$((POSITIONAL + 1))
      if [ "${POSITIONAL}" -eq 1 ]; then BASE="$1"; elif [ "${POSITIONAL}" -eq 2 ]; then HEAD_REF="$1"; else
        echo "ERROR: unexpected argument '$1'" >&2; exit 2
      fi
      shift ;;
  esac
done
[ -n "${BASE}" ] || { echo "usage: collect-diff.sh <base-ref> [head-ref] [--max-patch-bytes N]" >&2; exit 2; }
case "${MAX_PATCH}" in ''|*[!0-9]*) echo "ERROR: --max-patch-bytes must be an integer" >&2; exit 2 ;; esac

# Fail clearly if the baseline isn't an ancestor of HEAD (rebase/squash). The skill
# must stop and ask for a new baseline here — guessing the equivalent squash-merge
# commit produces a silent bad diff.
if ! git merge-base --is-ancestor "${BASE}" "${HEAD_REF}" 2>/dev/null; then
  echo "ERROR: '${BASE}' is not an ancestor of '${HEAD_REF}' (history rewritten?)." >&2
  echo "Re-bootstrap the baseline before syncing." >&2
  exit 2
fi

echo "## doc-sync diff: ${BASE}..${HEAD_REF}"
echo
echo "### commits, each with the files it touched (newest first, merges excluded)"
git log --no-merges --name-status --pretty=format:'%n--- %h %s' "${BASE}..${HEAD_REF}"
echo
echo
echo "### changed files (name-status, whole range)"
git diff --name-status "${BASE}..${HEAD_REF}"
echo
echo "### diffstat"
git diff --stat "${BASE}..${HEAD_REF}"
echo

if [ "${MAX_PATCH}" -eq 0 ]; then
  echo "### patch"
  echo "(omitted: --max-patch-bytes 0)"
  exit 0
fi

# Cap the patch rather than letting one huge range blow up the agent's context. When it
# does not fit, say so explicitly and name the command to fetch a single file's patch —
# silence here would read as "nothing else changed".
PATCH_BYTES="$(git diff "${BASE}..${HEAD_REF}" | wc -c | tr -d ' ')"
echo "### patch (${PATCH_BYTES} bytes)"
if [ "${PATCH_BYTES}" -le "${MAX_PATCH}" ]; then
  git diff "${BASE}..${HEAD_REF}"
else
  echo "TRUNCATED: the patch is ${PATCH_BYTES} bytes, over the ${MAX_PATCH}-byte cap."
  echo "The file list above is complete; the hunks are not shown. Read the patch for"
  echo "individual files as you classify them:"
  echo "  git diff ${BASE}..${HEAD_REF} -- <path>"
  echo "Do not treat a claim as verified against a patch you did not read."
fi
