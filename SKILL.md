---
name: doc-sync
description: >-
  Syncs a repository's documentation with its code: diffs from the last
  documented commit to HEAD, works out which docs are now factually wrong, and
  fixes them. Use this skill whenever the user asks to "sync the docs", "update
  the docs for recent changes", or types "/doc-sync" — and also whenever they
  wonder aloud whether the documentation is still accurate, has drifted, or is
  out of date, which is a request for this even when they don't name it. Reach
  for it right after merging and before cutting a release, when changes to
  architecture, APIs, schema, config, infrastructure, or conventions may have
  invalidated something; when CLAUDE.md or AGENTS.md instructions look stale;
  when docs cite file paths that no longer exist; or when the user wants an
  audit of which docs are behind. Prefer it over editing docs ad hoc: it tracks
  a baseline commit, stamps each doc it verifies, escalates agent-instruction
  files rather than auto-editing them, and never commits on the user's behalf.
license: MIT
---

# doc-sync

Keep the project's documentation in step with the code. On request, diff the repo from
the last documented commit to HEAD, work out which docs are now factually wrong, and
update them — asking the developer whenever a change's intent cannot be read from the
diff.

Documentation is handled in **two tiers**:

| Tier  | What                                              | Default handling                               |
| ----- | ------------------------------------------------- | ---------------------------------------------- |
| **A** | Agent instructions (`CLAUDE.md`, `AGENTS.md`, …)  | always escalate, never auto-edit               |
| **B** | Human docs (`docs/`, `README.md`, …)              | auto-edit verified claims; stage, never commit |

The tiers differ by blast radius, and that is the whole reason for the split. Tier A is
read by every future agent session in this repo — a wrong line there mis-steers all later
work, so no confidence level unlocks an unattended edit. Tier B lives in the repo and
therefore inherits code review, so it is safe to edit; edits are left *staged* and the
developer writes the commit.

**Certification is per-doc, not per-run.** Every Tier B doc you verify gets a
`<!-- doc-sync: verified-at <sha> -->` stamp (`scripts/stamp-verified.sh`). The baseline
in the state file is only a scheduling hint that bounds the next diff — it never asserts
that a range was fully processed, because no single pass over hundreds of files can
honestly certify that. `scripts/doc-audit.sh` reads the stamps back as an aging report
and existence-checks every repo path a doc cites: deterministic staleness detection that
needs no model and no mapping.

## Critical rules

- **Tier A is always escalated — never auto-edit it.** Propose the change and let the
  developer decide. These files are read by every future agent session; getting them
  wrong has the highest blast radius of anything in the repo.
- **Never commit.** Make the edits and leave them staged. The developer reviews and
  commits separately, so the doc changes land as one reviewed, attributable commit.
- **Never auto-edit a path matching `neverAutoEdit`** (published legal and policy
  documents by default). Escalate like Tier A regardless of confidence. Editing one is
  a legal act, not a doc refresh; the `locales` rule would otherwise have you rewriting
  translated legal text that no native speaker reviews; and `datedDocs` would then stamp
  the result as freshly updated, which is precisely the signal a reader trusts.
- **Read all repo-specific values from `.claude/docs-sync.config.json`.** Do not
  hardcode paths, tiers, locales, or globs into this skill.
- **The `targets` map is a routing hint, not a coverage guarantee or a permission
  boundary.** It tells you where to look first. It is hand-maintained and therefore
  always somewhat behind the repo, so an unmapped path means "nobody mapped this yet",
  not "no doc is affected" — warn, and say so in the report rather than treating the
  silence as an all-clear. You may edit an off-map doc when the same verification bar is
  met (the claim is provably false against HEAD), but say plainly in the report that it
  was off-map, so the mapping gets fixed instead of quietly drifting further.
- **Always use `scripts/collect-diff.sh` to collect the diff.** Never substitute ad-hoc
  `git diff` commands with custom grep filters. The script produces the complete,
  authoritative file list that all classification depends on. Filtering it yourself
  before classification silently drops files.
- **`commitWeights` never suppresses the Tier A scan.** It is a Tier-B noise filter
  only. A `docs:`, `chore:`, or `refactor:` commit can still add or modify an
  agent-instruction file — those are always Tier A regardless of commit type. The Tier A
  scan is mandatory and unconditional on every run.
- **Orphaned baseline → stop and ask, never self-correct.** If `lastSyncedSha` is not an
  ancestor of HEAD, report the problem and ask the developer for the correct baseline.
  Do not attempt to locate the equivalent squash/merge commit yourself — history is
  ambiguous and a wrong guess produces a silent bad diff.

## When to run

- The developer types `/doc-sync` (optionally scoped: `/doc-sync backend`).
- The developer asks to "sync the docs" / "update the docs for recent changes".
- After merging a change to architecture, APIs, schema, infrastructure, or conventions.

## Flags

- `--hands-off` — apply high-confidence Tier-B edits without asking; escalate the rest in
  the report. Never extends to committing.
- `--report-only` — produce the impact summary and stop; write no edits.
- `--dry-run` — show proposed per-file diffs but don't write.
- `--revert-last` — undo the previous sync's doc edits (see below).
- `--base <ref>` — override the baseline (default: the SHA in the state file).
- `<scope>` — limit to one area, e.g. `backend`, `mobile`, `infra`. **A scoped run never
  advances the baseline** (step 7) — it deliberately leaves the rest of the range
  unprocessed, and bumping would bury it.

## Configuration

All repo-specific values live in `.claude/docs-sync.config.json`. Read it first. Keys:
`baseline`, `ignore`, `tierA.patterns`, `targets` (code→docs), `locales`, `datedDocs`,
`neverAutoEdit`, `commitWeights`, `driftThreshold`, `provenance`, and `docAudit`.

If the config does not exist, tell the developer to run
`bash .claude/skills/doc-sync/scripts/doc-sync-init.sh`, which scans the repo and writes
a starter config for them to edit. Do not invent a config yourself.

## Workflow

### 1. Load config + state

- Read `.claude/docs-sync.config.json`.
- Read `.claude/docs-sync.state.json` for **`lastSyncedSha`**.
- **First run (no state):** ask the developer for a baseline — last release tag, N
  commits back, or a specific SHA. Under `--hands-off`, follow the config's
  `baseline.strategy` rather than choosing for yourself (`"lastTag"` →
  `git describe --tags --abbrev=0`) and note the assumption; if that key is absent or
  unrecognised, use the last tag and say so. Don't write the state file
  until the run completes successfully.
- **Baseline sanity check:** if the chosen baseline resolves to HEAD (e.g. the newest tag
  sits on HEAD, so the range is empty), the repo is NOT necessarily in sync. Fall back to
  the config's `baseline.fallback` (`"previousTagOrNCommits"` → `git describe --tags
  --abbrev=0 HEAD^`, else N commits back), and warn
  which baseline you used and why. Never report "already in sync" off an empty range that
  only an on-HEAD tag produced.

### 1b. Check the working tree

Run `git status --porcelain` before editing anything. doc-sync compares committed
objects but edits and stamps the *working tree*, so pre-existing changes matter:

- **Uncommitted changes to files you are about to edit or stamp** — stop and show them.
  Staging your edits on top would merge them into the developer's work, and
  `--revert-last` would later discard both.
- **Unrelated uncommitted work** — fine to proceed, but say it is there, and stage only
  the files you actually edited (step 6) so nothing of theirs is swept in.

### 2. Collect the diff

- Run `scripts/collect-diff.sh <lastSyncedSha> HEAD` (or `scripts/collect-diff.ps1` on
  Windows). Do NOT substitute ad-hoc `git diff` — the script's output is the
  authoritative file list. It gives you four things: each commit with its own changed
  files (so `commitWeights` can be applied per commit rather than guessed across the
  range), the whole-range name-status list, a diffstat, and **the patch itself**.
- The patch is what lets you verify a claim false. If it comes back marked `TRUNCATED`
  because the range exceeded the byte cap, the file list is still complete but the hunks
  are not — read `git diff <base>..HEAD -- <path>` for each file as you classify it. Do
  not treat a claim as verified against a patch you did not read; that is the difference
  between high and low confidence.
- If the script exits `2` because `lastSyncedSha` is not an ancestor of HEAD
  (rebase/squash), **stop and ask the developer for a new baseline.** Do not attempt to
  locate the equivalent merge commit yourself.
- Drop files matching any `ignore` glob — **for Tier B routing only**. Keep the
  unfiltered list for the Tier A scan in step 3, which must not be narrowed by config.
- Use `commitWeights` as a first-pass hint to skip obvious noise (formatting,
  lockfile-only commits). Never apply it to the full file list before classification —
  always classify first.
- Take the "nothing meaningful remains" exit **only if all three hold**: no Tier A file
  anywhere in the file list (including the `**/CLAUDE.md` and `**/AGENTS.md` backstop),
  nothing maps to a Tier-B target, and **`targets` is non-empty and at least one changed
  path was actually matched by some glob in it**. Then report "docs already in sync", run
  `bump-state` (unless in a no-write mode — see step 7), and stop.
- That third condition is what separates "nothing to do" from "nothing is mapped". If
  `targets` is empty, or every changed path fell through unmapped, the run has learned
  nothing about whether the docs are stale — it has only discovered the map is missing.
  Say exactly that, list the unmapped paths, point at `doc-sync-init.sh`, and **do not
  bump the baseline**: bumping would hide this range from the next run's diff and the
  repo would report itself in sync forever.
- Otherwise do not take this exit: a range of pure `chore:`/`refactor:` commits can still
  add an agent-instruction file, and this shortcut would skip the mandatory Tier A scan.

### 3. Classify each change

- **Tier A scan first — mandatory on every run.** Before classifying anything else, scan
  the complete file list for additions or modifications to any path matching a
  `tierA.patterns` glob, **or matching `**/CLAUDE.md` or `**/AGENTS.md` regardless of
  what that config key says**. Scan for **any** status — added, modified, deleted, or
  renamed; a deleted or renamed-away instruction file matters at least as much as an
  edited one, and `collect-diff`'s name-status output distinguishes them. Scan the
  **unfiltered** file list, before `ignore` globs are applied: `ignore` is a Tier-B noise
  filter, and letting it hide an instruction file would make this supposedly
  unconditional scan conditional on config after all. Those two are a backstop deliberately placed outside the
  config's reach: they catch a newly added agent-instruction file before anyone has
  updated `tierA.patterns`, and they survive a user narrowing that key by mistake.
  Nothing validates the config, so the highest-blast-radius rule in this skill does not
  depend on it. Do the scan unconditionally — commit type, `commitWeights`, and "the docs
  already look current" are not reasons to skip it.
- For each remaining change decide: **Tier A**, **Tier B**, or **neither**. See
  `references/classification.md` for the heuristics — read it before classifying. A
  single change can land in both tiers.
- Map Tier-B changes to target docs via `targets`: match the changed file's path against
  each `code` glob, and when several match, prefer the most specific (longest) one.
- `commitWeights` is only a first-pass hint for dropping Tier-B noise — the
  `classification.md` heuristics take precedence (e.g. a `fix:` that only quiets logs is
  still *neither*). It never affects the Tier A scan.
- If a changed area matches no target, **warn** ("unmapped path: X — no doc target") and
  move on.
- Assign a confidence (high / medium / low) to each proposed edit.

### 4. Build the impact summary

- Produce a table: change → affected doc(s) → proposed edit → tier → confidence.
- This is also the `--report-only` output. **Stop here if `--report-only`.**

### 5. Decide (mode branch)

- **Tier A → always escalate.** Propose, never write unattended.
- **`neverAutoEdit` match → always escalate**, regardless of confidence or mode.
- **Hands-on (default):** use AskUserQuestion on every Tier-A item and every
  low/medium-confidence Tier-B item.
- **Hands-off:** apply high-confidence Tier-B edits; queue everything else for
  escalation. `--hands-off` still never commits.
- **Auto-escalate regardless of mode** if a change's purpose can't be read from the diff
  plus commit message.
- Headless (no interactive session): collect all escalations into a
  `❓ Needs human input` block in the final report instead of asking.

### 6. Apply edits

- Edit only the affected docs. Match each file's existing tone and structure — terse for
  agent-instruction files, explanatory for `docs/`.
- **Protected regions:** never modify text between `<!-- doc-sync:ignore -->` and
  `<!-- /doc-sync:ignore -->`.
- **Locales:** if an edited doc has locale variants (per `locales`), apply the equivalent
  edit to every variant in the same change — never defer one.
- **Dated docs:** if an edited file matches `datedDocs`, bump its "last updated" date
  line to today, in every locale, using each locale's own wording for that line.
- **Counted facts** — hardcoded counts and version pins are the fastest-rotting doc
  content, wrong between syncs by construction. Prefer deleting the number and describing
  the shape instead ("one file per schema change"); nobody acts differently at 74 versus
  73 migrations. Keep a count only when it genuinely informs a decision, and then
  recompute it from the repo rather than trusting either the doc or the diff. Version
  pins that gate behaviour stay, verified against HEAD.
- **Stamp everything you verified** — run `scripts/stamp-verified.sh <head-sha> <files…>`
  over every Tier B doc you verified this run, **including ones you checked and found
  already correct**. A verified-but-unstamped doc looks permanently stale in `doc-audit`;
  an unverified-but-stamped doc is a lie. The script exits `3` if it stamped nothing
  because every file was missing — treat that as a failed certification: report it and do
  not advance the baseline in step 7. Never stamp Tier A files — the script refuses
  the default agent-instruction filenames, but the rule is yours to hold, not its.
- **Stage what you changed**: `git add -- <edited-doc> [<edited-doc> …]`, naming the
  files explicitly. The `--` is not decoration: without it, a doc whose path begins with
  a dash is parsed as an option, and `git add -A` is a real filename an attacker or an
  unlucky author could create — which would stage the whole tree, the exact opposite of
  what the next sentence forbids. This is what makes good on "edits are left staged" — nothing else in this
  workflow and none of the scripts does it, so skipping it leaves the developer to find
  the changes themselves. Never `git add -A` or `git add .`: the working tree may hold
  their own unrelated work, and sweeping that into the same change is exactly the
  surprise this skill exists to avoid.
- If `--dry-run`, show the proposed diffs instead of writing.

### 7. Record

**Write nothing here in a no-write mode.** Under `--dry-run` or `--report-only`, skip
this step entirely — bumping the baseline after writing no edits silently discards the
doc debt for that whole range, and the next run will never look at it again. The same
applies to the "nothing meaningful remains" early exit in step 2.

**The stamps from step 6 are the real certification** — this step only moves the
scheduling hint that bounds the next diff. A doc this run never examined keeps its old
stamp and stays visibly stale in `doc-audit`, so a bump can no longer silently certify
it. But a bump still hides that range from the next run's diff, so it is not free.

- **Scoped run (`/doc-sync <area>`) — skip `bump-state` entirely.** The baseline does not
  move. Say so in the report, and note that the next full run will re-cover the range.

Otherwise write the record first and the baseline second — **in that order**. The bump is
what hides this range from the next run's diff, so it must not happen until the entry that
makes the run revertible exists. If the append fails, stop and do not bump.

1. `scripts/append-history.sh <base-sha> <head-sha> <files-changed> <items-escalated>
   <edited-file> [edited-file …]` — list **every** doc file you edited or stamped. That
   trailing list is the only record of what the run touched and `--revert-last` reads it
   back; omit it and the entry records an empty `files` array, leaving a later revert
   with nothing to restore.
2. `scripts/bump-state.sh <head-sha>` (or `.ps1`).

### 8. Report

- Summarize: docs edited, items escalated (the `❓` block), unmapped warnings, and the
  new baseline.
- **Do not commit.** Leave the edits staged for the developer.
- Consider ending with `scripts/doc-audit.sh` — its broken-reference and aging report is
  cheap and catches what the mapping missed.

## --revert-last

Read the last entry in `.claude/docs-sync.history.jsonl`. Its `files` field lists what the
run touched and its `base` field is the baseline that run started from.

Restore each of those files with **`git checkout <head> -- <file>`**, using the entry's
**`head`** SHA — not `base`. Which ref you restore *from* is the whole problem here, and
three plausible answers are wrong:

- `git checkout -- <file>` restores from the **index**. doc-sync stages its edits, so the
  index already holds the new content and this is a no-op.
- `git checkout HEAD -- <file>` works only while the edits are still staged. The
  documented workflow is that the developer then *commits* them, and after that `HEAD`
  contains the sync's edits too — a no-op in exactly the case a revert is most wanted.
- `git checkout <base> -- <file>` reaches too far back. `base` is the start of the whole
  review range, so this also discards any legitimate doc edit committed between `base`
  and the sync.

`head` is the code commit the run synced *to*. doc-sync never commits, so at the moment it
ran, the docs stored at `head` were the pre-sync ones — and unlike live `HEAD`, that SHA
does not move when the developer commits. It is therefore correct both before and after
they do. Restoring from it also removes the stamps that run added, since a stamp rode
along in the same edit.

Then restore `lastSyncedSha` to the entry's `base` value.

Two cases to handle rather than assume away:

- **A file that does not exist at `head`** was created by the sync, so the checkout fails.
  Delete it instead — but say so first; deleting a file is not the same as reverting an
  edit.
- **The sync was already committed.** The checkout stages the reversal as a *new* change
  rather than removing that commit. Say so plainly; the developer may prefer `git revert`
  on it, and that is their call.

`head` holds the docs as they were *when the sync ran*. If the developer edited a doc
themselves after the sync, restoring from `head` discards that too — and you cannot tell
their edit apart from the sync's own, because the history records the pre-sync content
and not the post-sync content. So do not try to infer it. Show the developer
`git diff <head> -- <file>` for every file and get confirmation before writing, in every
mode including `--hands-off`. A revert is the one operation here that destroys work
rather than creating it, so it does not get an unattended path.

Finally record the revert:
`scripts/append-history.sh --event revert <base> <head> <n-files> 0 <file> [file …]`.
That `--event revert` is what a later run reads to tell a revert entry from a sync entry.
If the last entry already has `"event": "revert"`, stop and say the previous sync has
already been reverted rather than undoing it twice.

Confirm before discarding any uncommitted work, and check first whether the developer has
made their own edits on top of the sync — those sit in the same files and a checkout
would take them too. If so, show them what would be lost and let
them decide rather than reverting.

## Common issues

- **"No config file"** → not installed yet; run `scripts/doc-sync-init.sh`.
- **"No baseline / state file"** → first run; bootstrap a baseline (step 1).
- **Baseline not an ancestor of HEAD** → history was rebased or squashed; re-ask for a
  baseline. Never guess the equivalent commit.
- **Huge diff (many commits)** → summarize per commit; never load one giant diff at once.
- **Not on the default branch** → run against the default branch by default; warn if on a
  feature branch.
