#!/usr/bin/env bash
# Append one audit-trail entry to .claude/docs-sync.history.jsonl.
#
# Append-only, one JSON object per line. `--revert-last` reads the final line to find
# out what the previous run touched and which commit holds the pre-sync content.
#
# `files` is a JSON ARRAY, not a delimited string: a comma-joined list cannot be decoded
# unambiguously, because a comma is a legal character in a git path. Every string is
# escaped through a real JSON encoder when one is available, so a filename containing a
# quote or a backslash cannot corrupt the audit trail.
#
# `event` distinguishes a sync entry from a revert entry, so `--revert-last` can tell
# whether the previous run has already been reverted instead of undoing it twice.
#
# Usage: append-history.sh [--event sync|revert] <base-sha> <head-sha> <files-changed> \
#                          <items-escalated> [files...]
set -euo pipefail

EVENT=sync
if [ "${1:-}" = "--event" ]; then
  EVENT="${2:?--event needs a value}"
  case "${EVENT}" in sync|revert) ;; *) echo "ERROR: --event must be sync or revert" >&2; exit 2 ;; esac
  shift 2
fi

BASE="${1:?usage: append-history.sh <base-sha> <head-sha> <files-changed> <items-escalated> [files...]}"
HEAD_SHA="${2:?}"
FILES="${3:?}"
ESCALATED="${4:?}"
shift 4

# The counts land in JSON unquoted, so a non-numeric value would produce a malformed
# entry that silently breaks every later read of the history.
# Resolve both refs to canonical commit IDs rather than trusting the caller. A charset
# check would accept `nope` or a value starting with `-`, and `head` is later
# interpolated into `git checkout <head> -- <file>` by the revert flow, where a
# dash-leading value would be read as an option. Recording the resolved SHA also means
# the entry stays meaningful after a branch moves.
resolve_ref() {
  local out
  if ! out="$(git rev-parse --verify --quiet "${1}^{commit}" 2>/dev/null)"; then
    echo "ERROR: '${1}' does not resolve to a commit in this repository" >&2
    exit 2
  fi
  printf '%s' "${out}" | cut -c1-12
}
BASE="$(resolve_ref "${BASE}")"
HEAD_SHA="$(resolve_ref "${HEAD_SHA}")"

case "${FILES}" in ''|*[!0-9]*) echo "ERROR: files-changed must be a non-negative integer, got '${FILES}'" >&2; exit 2 ;; esac
case "${ESCALATED}" in ''|*[!0-9]*) echo "ERROR: items-escalated must be a non-negative integer, got '${ESCALATED}'" >&2; exit 2 ;; esac

HISTORY_FILE=".claude/docs-sync.history.jsonl"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build the entry with a real JSON encoder where possible. The fallback covers the two
# characters that actually break JSON and refuses anything it cannot encode safely,
# rather than writing a corrupt line and returning success.
build_entry() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
ts, base, head, files, esc = sys.argv[1:6]
# Reject the same inputs the no-python fallback rejects, so behaviour does not depend
# on whether python3 happens to be installed.
for p in sys.argv[7:]:
    if any(ord(c) < 32 or ord(c) == 127 for c in p):
        sys.stderr.write("ERROR: path contains a control character: %r\n" % p)
        raise SystemExit(2)
print(json.dumps({"timestamp": ts, "event": sys.argv[6], "base": base, "head": head,
                  "filesChanged": int(files), "itemsEscalated": int(esc),
                  "files": sorted(set(sys.argv[7:]))}, separators=(",", ":")))' \
      "${TIMESTAMP}" "${BASE}" "${HEAD_SHA}" "${FILES}" "${ESCALATED}" "${EVENT}" "$@"
    return
  fi
  local out="" f esc_f first=1
  for f in "$@"; do
    # JSON forbids every unescaped byte in U+0000-U+001F, not just newline and tab.
    # Rather than half-escape them, refuse: a path with a control byte in it is
    # pathological, and emitting a line that will not parse corrupts the whole trail.
    if printf '%s' "${f}" | LC_ALL=C grep -q '[[:cntrl:]]'; then
      echo "ERROR: path contains a control character and cannot be recorded without python3: $(printf '%s' "${f}" | LC_ALL=C tr -d '[:cntrl:]')" >&2
      exit 2
    fi
    esc_f="$(printf '%s' "${f}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    [ "${first}" -eq 1 ] && first=0 || out="${out},"
    out="${out}\"${esc_f}\""
  done
  printf '{"timestamp":"%s","event":"%s","base":"%s","head":"%s","filesChanged":%s,"itemsEscalated":%s,"files":[%s]}\n' \
    "${TIMESTAMP}" "${EVENT}" "${BASE}" "${HEAD_SHA}" "${FILES}" "${ESCALATED}" "${out}"
}

mkdir -p "$(dirname "${HISTORY_FILE}")"
# Build the line fully before touching the file. A crash or a full disk mid-encode would
# otherwise leave a truncated final line, and every later read of the trail fails on it.
TMP_ENTRY="$(mktemp)"
trap 'rm -f "${TMP_ENTRY}"' EXIT
build_entry "$@" > "${TMP_ENTRY}"
cat "${TMP_ENTRY}" >> "${HISTORY_FILE}"

echo "appended to ${HISTORY_FILE}: ${BASE}..${HEAD_SHA}, ${FILES} files, ${ESCALATED} escalated, $# path(s) recorded"
