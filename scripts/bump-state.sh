#!/usr/bin/env bash
# Write .claude/docs-sync.state.json with the synced baseline SHA and today's date.
#
# This is a SCHEDULING HINT, not a certification: it bounds the next run's diff and
# asserts nothing about completeness. The per-doc stamps written by stamp-verified.sh
# are what actually certify a doc. Bumping still hides the range from the next diff,
# so the skill skips this step entirely in no-write modes and on scoped runs.
#
# Usage: bump-state.sh [sha]     (default: HEAD)
set -euo pipefail

# Reject extra arguments rather than ignoring them. An earlier three-tier version of
# this skill took a second `scope` argument (code|wiki|both); a model carrying that
# contract, or a stale SKILL.md in a fork, would call `bump-state.sh HEAD code` and
# otherwise get a silent success while writing something different from what it meant.
if [ "$#" -gt 1 ]; then
  echo "ERROR: bump-state.sh takes at most one argument (the sha); got $#: $*" >&2
  echo "usage: bump-state.sh [sha]" >&2
  exit 2
fi

SHA_IN="${1:-HEAD}"

SHORT_SHA="$(git rev-parse --short "${SHA_IN}")"
TODAY="$(date +%Y-%m-%d)"
STATE_DIR=".claude"
STATE_FILE="${STATE_DIR}/docs-sync.state.json"

mkdir -p "${STATE_DIR}"
# Write to a temp file in the same directory and rename over the target. A direct
# truncate-and-write can leave a half-written state file if the process dies mid-write,
# and the next run then reads a corrupt baseline. rename(2) within one filesystem is
# atomic, so a reader sees either the old file or the new one.
#
# No jq dependency: the field names must stay unique within this file, since
# check-drift.sh reads them back with grep + sed.
TMP_STATE="$(mktemp "${STATE_DIR}/.docs-sync.state.XXXXXX")"
trap 'rm -f "${TMP_STATE}"' EXIT
printf '{\n  "lastSyncedSha": "%s",\n  "lastSyncedAt": "%s"\n}\n' \
  "${SHORT_SHA}" "${TODAY}" > "${TMP_STATE}"
chmod 644 "${TMP_STATE}"
mv "${TMP_STATE}" "${STATE_FILE}"
trap - EXIT

echo "wrote ${STATE_FILE}: ${SHORT_SHA} @ ${TODAY}"
