# Tier classification heuristics

Used by the doc-sync skill (workflow step 3) to decide whether a code change affects
**Tier A** (agent instructions), **Tier B** (human docs), or **neither**. A change can be
in both tiers at once — classify into all that apply, not just the first that matches.

## The buckets

### Tier A — agent instructions — ALWAYS ESCALATE

Files matching `tierA.patterns`, plus `**/CLAUDE.md` and `**/AGENTS.md` unconditionally —
those two are matched whatever the config says, so a newly added agent-instruction file is
caught before anyone updates the config, and narrowing `tierA.patterns` cannot silently
disable the check.

A change is Tier A only when it changes a **rule, convention, or invariant** that a
future contributor — human or agent — must follow. Signals:

- New or changed build / test / lint / run commands or workflows.
- A new architectural pattern or constraint.
- A new directory or package that changes the project map.
- Changed naming conventions, branch or commit rules, or cross-cutting policies.
- New "always do this / never do that" guidance.

**Not** Tier A: implementing a feature that merely _follows_ an existing convention.
Using a pattern is not the same as changing the rule about the pattern.

> **Calibrate these for your repo.** Replace the examples below with two or three real
> conventions of your own. They are what tells the model where the line between a *rule*
> change and a *use* of a rule falls, and generic examples calibrate it poorly.
>
> - _"All database migrations are written as SQL in the migration file itself, never in
>   a side-car resource."_
> - _"Feature flags are read through the `flags` package only — never from the
>   environment directly."_

Tier A is **always escalated** — propose the edit, never write it unattended.

### Tier B — human docs — auto-edit if confident

A change is Tier B when it changes **what the system does or how it is built**, in a way
the prose docs describe. Signals:

- A new or changed feature, user flow, screen, or API endpoint.
- A schema or migration that adds or reshapes data.
- A new environment variable, config value, secret, or infrastructure resource.
- Changed setup or getting-started steps.
- New or removed module behaviour described in architecture docs.

Map to target docs by the changed file's path (config `targets`).

### Neither — no doc change

- Bug fixes that restore intended behaviour without changing the contract.
- Pure refactors (rename, extract, move) with no external behaviour change.
- Formatting, comments, and test-only changes.
- Dependency bumps — unless they change setup or run instructions.

When unsure between **Tier B** and **neither**, prefer _neither plus a low-confidence
note_ over editing docs speculatively.

## Confidence

**The gate is verifiability, not self-confidence.** "I am sure" is not a measurement —
you can always write _an_ exact edit, and doing so confidently is the failure mode, not
the discriminator. The question is whether you _checked_.

- **High** — the edit corrects an existing claim you have verified false against the
  working tree at HEAD, and every fact in the replacement is checkable there too: a path,
  a version, a count, a flag, an enumerated list. Hands-off may auto-apply (Tier B only;
  never Tier A, never `neverAutoEdit`).
- **Medium** — a doc is clearly affected, but the edit adds new explanatory prose rather
  than correcting a checkable claim, or the wording needs judgment. Escalate in
  hands-off; ask in hands-on.
- **Low** — you suspect impact but cannot confirm it from the diff or the repo. Escalate
  or note; never auto-edit.

Anything that depends on knowing **why** a change was made — intent, motivation, a
trade-off someone weighed — is at most medium however obvious it feels, because a diff
cannot evidence a reason. That is the content most likely to be wrong and least likely to
be caught in review.

## Ambiguous purpose

If you can't tell _why_ a change was made from the diff plus the commit message, don't
guess its doc impact — escalate it.

## Counted facts

Hardcoded counts and version pins rot fastest: they are wrong between syncs by
construction. Default action is to **delete the number** and describe the shape instead.
Keep a count only when it genuinely informs a decision, and then recompute it from the
repo — never trust the doc or the diff for it. Version pins that gate behaviour (runtime,
SDK, protocol) stay, verified against HEAD.

## Locales and dated docs

- If an edited doc has locale variants (config `locales`), apply the same edit to every
  variant, in the same change.
- If an edited file matches `datedDocs`, bump its "last updated" line to today — in every
  locale, using each locale's own wording for that line — as part of the same change.

## Protected regions

Never edit text between `<!-- doc-sync:ignore -->` and `<!-- /doc-sync:ignore -->`.
