# doc-sync

A [Claude Code](https://claude.com/claude-code) skill that keeps a repository's
documentation honest.

It diffs your repo from the last documented commit to HEAD, works out which docs are now
factually wrong, and fixes them — escalating to you whenever a change's *intent* can't be
read from the diff.

It is not a doc generator. It corrects claims that have become false.

```
/doc-sync

  docs edited (staged, not committed)
    docs/architecture/backend.md      auth flow now goes through the gateway
    docs/getting-started/setup.md     node 20 -> 22

  ❓ needs human input
    CLAUDE.md                         new "migrations are inline SQL" rule — Tier A, your call
    docs/deployment/ci.md             why did the deploy job move to a matrix? can't tell from the diff

  unmapped path: services/billing/**  (no doc target — add one to `targets`)

  baseline a1b2c3d -> e4f5a6b
```

---

## The problem it solves

Most "sync the docs" automation quietly lies to you. It keeps one `lastSyncedSha`, bumps it
at the end of a run, and now every doc in the repo is marked current — including the
hundreds it never opened. The next run diffs from the new baseline and never revisits the
range. The lie is permanent and invisible.

doc-sync inverts that:

**Certification is per-doc, not per-run.** Every doc actually verified gets a stamp:

```markdown
<!-- doc-sync: verified-at a1b2c3d -->
```

The global baseline is demoted to a *scheduling hint* — it bounds the next diff and asserts
nothing about completeness. A doc the run never looked at keeps its old stamp and shows up
as stale, forever, until something actually checks it.

That makes staleness **measurable without a model**:

```console
$ .claude/skills/doc-sync/scripts/doc-audit.sh

## doc-audit @ e4f5a6b

### 1. Reference rot (cited paths that do not exist)
  docs/architecture/backend.md:
    ✗ services/api/src/LegacyAuth.ts

### 2. Provenance aging (commits behind HEAD per verified-at stamp)
       0 commits behind  docs/getting-started/setup.md (@ e4f5a6b)
     214 commits behind  docs/deployment/ci.md (@ 9c8b7a6)

### 3. Unstamped (nothing certifies these at all)
  docs/architecture/data-model.md

  (dirs skipped: node_modules vendor archive legacy .venv target build dist)

summary: 1 broken reference(s), 2 stamped doc(s)
```

No LLM runs there. It existence-checks the repo paths your docs cite — backticked tokens
that start with one of your top-level directories, plus common root-level files like
`package.json` — and reads the stamps back as an aging report. Run it in CI with `--strict` and a doc citing a deleted file fails
the build.

---

## Two tiers, different blast radius

| Tier  | What                                             | Handling                                       |
| ----- | ------------------------------------------------ | ---------------------------------------------- |
| **A** | Agent instructions — `CLAUDE.md`, `AGENTS.md`, … | always escalate, never auto-edit               |
| **B** | Human docs — `docs/`, `README.md`, …             | auto-edit verified claims; stage, never commit |

Tier A is read by every future agent session in the repo. A wrong line there mis-steers all
later work, so no confidence level unlocks an unattended edit — doc-sync proposes and you
decide. Tier B lives in the repo and inherits code review, so it's safe to edit; edits are
left **staged** and you write the commit.

doc-sync never commits and never pushes. That is not a limitation, it's the point.

---

## Confidence means verifiability

The thing that makes automated doc editing dangerous is a model that is *confident* rather
than *correct*. So the bar is explicit:

> "I am sure" is not a measurement — you can always write *an* exact edit, and doing so
> confidently is the failure mode, not the discriminator. The question is whether you
> *checked*.

- **High** — corrects a claim verified false against the working tree at HEAD, and every
  fact in the replacement is checkable there too. Only this level is auto-appliable.
- **Medium** — the doc is clearly affected, but the edit adds new prose or needs judgment.
- **Low** — impact suspected, unconfirmable.

With a hard ceiling: anything that depends on knowing **why** a change was made is at most
medium however obvious it feels, because a diff cannot evidence a reason. That's the content
most likely to be wrong and least likely to be caught in review.

---

## Install

The repo *is* the skill, so cloning it into place is the whole install:

```bash
git clone https://github.com/vpgits/doc-sync .claude/skills/doc-sync
chmod +x .claude/skills/doc-sync/scripts/*.sh
```

Then generate a starter config by scanning your repo:

```bash
bash .claude/skills/doc-sync/scripts/doc-sync-init.sh
```

```
doc-sync init — scanned 1,284 tracked files

  Tier A (agent instructions):
    CLAUDE.md
    services/api/AGENTS.md

  doc roots:      docs
  code areas:     4 top-level, 7 workspace
  manifests:      package.json pnpm-workspace.yaml .nvmrc

wrote .claude/docs-sync.config.json
```

**Then edit it.** The generated `targets` map pairs every code area with every doc root,
which is over-broad on purpose — nothing is silently unmapped on day one, and you narrow it
from there. Reviewing the "unmapped path" warnings in each run's report is the intended
maintenance loop; the map is a hint about where to look first, never a permission boundary.

Finally, a first run that writes nothing:

```
/doc-sync --report-only
```

<details>
<summary>Optional: nudge on session start</summary>

Add to `.claude/settings.json` so long-neglected docs surface on their own:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/skills/doc-sync/scripts/check-drift.sh 2>/dev/null || true"
          }
        ]
      }
    ]
  }
}
```

The `2>/dev/null || true` matters — a hook that fails must never break session start. It
nudges only past a threshold (15 commits or 14 days by default), because a warning that
fires after every commit trains itself into being ignored.

</details>

<details>
<summary>Windows / PowerShell</summary>

Every script ships in both shells. Swap `bash …/foo.sh` for `pwsh -File …/foo.ps1`
throughout, with named parameters: `-Base`/`-Head` (collect-diff), `-Sha`/`-Files`
(stamp-verified), `-Sha` (bump-state), `-Base`/`-Head`/`-FilesChanged`/`-ItemsEscalated`/
`-Files` (append-history), `-Strict`/`-Roots` (doc-audit), and `-Force`/`-Out`/`-Print`
(doc-sync-init).

> **The PowerShell ports are untested.** The `.sh` versions are canonical and have been
> run end-to-end; the `.ps1` files are careful line-by-line ports that have never been
> executed, because the author works on macOS. Treat them as a starting point rather than
> a supported path, and please open an issue if one misbehaves — or a PR if you fix it.

</details>

---

## Usage

```
/doc-sync                 # hands-on: asks before every Tier A and every uncertain edit
/doc-sync --report-only   # impact table, then stop — no edits, no state write
/doc-sync --dry-run       # show the proposed diffs, write nothing
/doc-sync --hands-off     # apply high-confidence Tier B edits; escalate the rest
/doc-sync --base v2.1.0   # override the baseline
/doc-sync backend         # scope to one area (never advances the baseline)
/doc-sync --revert-last   # undo the previous sync's edits and stamps
```

It also triggers on plain language — "sync the docs", "are these docs still accurate?",
"the setup guide looks out of date".

---

## Configuration

Everything repo-specific lives in `.claude/docs-sync.config.json`. The skill hardcodes no
paths, globs, or tiers — that separation is what makes it portable.

| Key              | What it does                                                              |
| ---------------- | ------------------------------------------------------------------------- |
| `tierA.patterns` | Globs for agent-instruction files. Always escalated.                       |
| `targets`        | `code` glob → `docs` paths. Longest matching glob wins, single match.      |
| `ignore`         | Dropped from the diff before classification — lockfiles, generated output. |
| `neverAutoEdit`  | Escalate-only regardless of confidence. Legal and policy docs.             |
| `locales`        | An edit to one locale variant is applied to all of them, in the same change. |
| `datedDocs`      | Files whose "last updated" line is bumped when edited.                     |
| `commitWeights`  | Conventional-commit noise filter. Tier B only — never suppresses the Tier A scan. |
| `driftThreshold` | When `check-drift` is allowed to nudge.                                    |
| `docAudit`       | Doc roots, top-level dirs, and skip dirs for the audit script.              |

The `*Note` and `_comment` strings in the config are **not decoration** — the model reads
them at runtime, and they carry reasoning the key name can't. Rewrite them for your repo
rather than deleting them.

Two worked examples in [`examples/`](examples/): a
[minimal config](examples/config.minimal.json) and a
[monorepo one](examples/config.monorepo.json) showing what a narrowed `targets` map looks
like once you've curated it.

---

## Scripts

The model does the judgment. The scripts do everything a model shouldn't be trusted with —
git plumbing, state writes, existence checks. Each ships as `.sh` and `.ps1`.

| Script             | Role                                                          | Exit codes            |
| ------------------ | ------------------------------------------------------------- | --------------------- |
| `doc-sync-init`    | Scan the repo, emit a starter config                           | `2` usage / not a repo |
| `collect-diff`     | The authoritative diff and file list                           | `2` baseline not an ancestor of HEAD |
| `stamp-verified`   | Upsert the per-doc `verified-at` stamp                         | `2` no files given    |
| `bump-state`       | Write the baseline                                             | —                     |
| `append-history`   | Append one audit-trail entry                                   | —                     |
| `doc-audit`        | Reference rot + provenance aging. No LLM.                      | `1` with `--strict` and broken refs |
| `check-drift`      | SessionStart nudge, threshold-gated                            | always `0`            |

They're plain git and **bash** (arrays and process substitution, so `sh`/`dash` will not
run them; bash 3.2 as shipped on macOS is fine) — usable outside Claude Code.
`doc-audit --strict` in CI is worth it on its own. Each also ships as a `.ps1`, though
those are unverified (see Windows / PowerShell above).

<details>
<summary>Portability notes</summary>

- **No hard `jq` dependency.** Anything read out of the hand-edited *config* goes through
  a real JSON parser — `jq` when present, `python3` otherwise, built-in defaults if
  neither. That matters because a config can grow a key of any name, and a naive grep for
  `"commits"` would happily pick up an unrelated one and redefine your drift threshold.
  The *state* file is different: it is written only by `bump-state` and holds two flat,
  uniquely-named keys, so a `grep`/`sed` pair is safe there and keeps the common path
  dependency-free.
- **`sed -i` is avoided** — BSD and GNU disagree on it, so `stamp-verified` writes to
  `mktemp` and moves.
- **Date parsing** tries BSD `date -j -f` first, then GNU `date -d`, then gives up to 0 days
  rather than reporting a wrong age.
- **`~` expansion is done by hand**, because config paths are quoted data and never pass
  through shell tilde expansion.

</details>

---

## Design notes

The decisions that are load-bearing, in case you fork it:

- **The stamp is the certification, not the baseline.** Everything else follows from this.
  Corollary: never stamp a Tier A file (it's instructions, not documentation, and a
  bookkeeping line there is noise every future agent session reads), and an
  unverified-but-stamped doc is worse than an unstamped one.
- **No-write modes and scoped runs never bump the baseline.** `--dry-run` and
  `--report-only` write no edits, so a bump would discard the whole range's doc debt. A
  scoped run deliberately leaves the rest of the range unprocessed.
- **Routing is a hint, not a permission boundary.** An unmapped path means "nobody mapped
  this yet", not "no doc is affected". Off-map docs *may* be edited when the same
  verification bar is met, but the report has to say so, or the mapping never gets fixed.
- **The Tier A scan is mandatory and unconditional.** `commitWeights` is a Tier B noise
  filter only — a `chore:` or `refactor:` commit can still add a `CLAUDE.md`.
- **Orphaned baseline → stop and ask.** If the baseline isn't an ancestor of HEAD, the
  history was rebased or squashed. Locating the equivalent commit is guesswork, and a wrong
  guess produces a silent bad diff.
- **Legal and policy docs are escalate-only.** Three effects compound: editing one is a
  legal act; the `locales` rule would rewrite every translated variant with no native
  speaker reviewing them; and `datedDocs` would then stamp the result as freshly updated —
  precisely the signal a reader trusts.
- **Counted facts get deleted, not updated.** Hardcoded counts are wrong between syncs by
  construction. Nobody acts differently at 74 versus 73 migrations, so describe the shape
  instead; keep a count only when it informs a decision, and recompute it from the repo.
- **Protected regions.** Text between `<!-- doc-sync:ignore -->` and
  `<!-- /doc-sync:ignore -->` is never touched.

---

## Known rough edges

Stated plainly, because you'll hit them:

- **Without `jq` or `python3`, the bash scripts cannot read the config.** They fall back
  to built-in defaults: `check-drift` uses 15 commits / 14 days, and `doc-audit` uses its
  default roots, top-level dirs and skip dirs — so a configured second doc root is simply
  not walked. `doc-audit` prints a warning when this happens; `check-drift` stays silent
  by design, since it must never disrupt session start.
- `doc-audit` walks only `docAudit.roots`. A doc that `targets` routes to but that lives
  outside those roots — a root `README.md`, most commonly — gets edited and stamped by
  every run and never appears in the aging report. Add it to `roots` if you care about it.
- `--revert-last` restores from the history entry's `head` commit — the code commit the
  run synced to, which holds the docs as they were just before the sync edited them. If
  the sync was already committed, that reversal is staged as a *new* change rather than
  removing the old commit; `git revert` may be what you actually want. And if you edited
  a doc yourself after the sync, a revert would discard that too, so it asks first.
- `doc-audit`'s reference-rot check only understands **backticked** repo paths. Markdown
  links, code fences, and prose references to files are invisible to it. It also checks
  the working tree rather than `HEAD`, so an untracked file can mask a reference that is
  genuinely missing from the commit.
- doc-sync compares committed objects but edits the working tree. It warns about
  pre-existing uncommitted changes to files it is about to touch, and stages only the
  files it edited — but it has no lock, so two runs at once (or a run racing your editor)
  is last-writer-wins. It is built for one developer running it by hand, not for CI or
  concurrent use.
- `--revert-last` checks whether the last history entry is already a revert, which stops
  the ordinary double-undo. It is an advisory check on the last line, not a transaction:
  two reverts started at the same moment could both see the same `sync` entry. The state
  file is replaced atomically; the history is an ordinary append.
- `collect-diff` caps the patch it emits (400 000 bytes by default, `--max-patch-bytes`).
  Past that you get the complete file list and a `TRUNCATED` marker instead of hunks.
- Nothing validates the config. There is no schema; a malformed file fails at model-read
  time, not at script time.
- The `targets` map is hand-maintained by design, so it is always somewhat behind the repo.
  That's why unmapped paths are reported rather than treated as an all-clear.
- `doc-sync-init` guesses. Its output is a starting point that needs narrowing, not a
  finished mapping.

---

## Prior art / origin

Extracted and generalized from a three-tier internal version that also synced a GitHub wiki
as a separate repo with commit-per-page review and an untrusted-content gate on page
metadata. That tier is dropped here because most repos don't have one — but the dual-baseline
design it required (two tiers advancing independently so skipping one never buried its debt)
is why the baseline is a scheduling hint rather than a watermark.

## License

MIT — see [LICENSE](LICENSE).
