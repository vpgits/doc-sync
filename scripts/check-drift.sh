#!/usr/bin/env bash
# SessionStart drift check.
#
# Nudges only past a threshold — a watermark that fires after every commit trains
# itself into being ignored. Thresholds come from the config's `driftThreshold`
# (commits / days), defaulting to 15 commits or 14 days.
#
# Exits silently when below the threshold, or when the skill has not been initialised
# yet. Wire it up so it can never break session start:
#   bash .claude/skills/doc-sync/scripts/check-drift.sh 2>/dev/null || true
set -euo pipefail

STATE_FILE=".claude/docs-sync.state.json"
CONFIG_FILE=".claude/docs-sync.config.json"

[ -f "${STATE_FILE}" ] || exit 0

# The state file is written only by bump-state.sh and holds two flat, uniquely-named
# keys, so a grep is safe there.
read_json_str() { grep "\"$2\"" "$1" 2>/dev/null | sed "s/.*\"$2\" *: *\"\([^\"]*\)\".*/\1/" | head -1 || true; }

# The CONFIG is hand-edited and may grow keys of any name, so its thresholds go through
# a real JSON parser when one is available. A stray `commits` key elsewhere in the file
# would otherwise silently redefine the threshold and quietly disable the nudge.
read_threshold() {  # read_threshold <config-file> <commits|days>
  [ -f "$1" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -er --arg k "$2" '.driftThreshold[$k] | numbers' "$1" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
try: v = json.load(open(sys.argv[1]))["driftThreshold"][sys.argv[2]]
except Exception: sys.exit(1)
sys.exit(1) if not isinstance(v, int) else print(v)' "$1" "$2" 2>/dev/null
  else
    return 1
  fi
}

LAST_SHA="$(read_json_str "${STATE_FILE}" lastSyncedSha)"
LAST_AT="$(read_json_str "${STATE_FILE}" lastSyncedAt)"
[ -n "${LAST_SHA}" ] || exit 0

T_COMMITS="$(read_threshold "${CONFIG_FILE}" commits || true)"; T_COMMITS="${T_COMMITS:-15}"
T_DAYS="$(read_threshold "${CONFIG_FILE}" days || true)"; T_DAYS="${T_DAYS:-14}"

BEHIND="$(git rev-list --count "${LAST_SHA}..HEAD" 2>/dev/null)" || exit 0

# BSD date first, then GNU, then give up to 0 rather than reporting a wrong age.
DAYS=0
if [ -n "${LAST_AT}" ]; then
  THEN="$(date -j -f %Y-%m-%d "${LAST_AT}" +%s 2>/dev/null || date -d "${LAST_AT}" +%s 2>/dev/null || echo '')"
  [ -n "${THEN}" ] && DAYS=$(( ($(date +%s) - THEN) / 86400 ))
fi

if [ "${BEHIND}" -ge "${T_COMMITS}" ] || [ "${DAYS}" -ge "${T_DAYS}" ]; then
  echo "⚠  docs may be stale — ${BEHIND} commits (${DAYS}d) since last sync at ${LAST_SHA}. Run /doc-sync to update."
fi
