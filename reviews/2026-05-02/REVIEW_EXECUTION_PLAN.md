# Execution Plan — Ka0s Consumable Master review

**Date:** 2026-05-02
**Companion to:** `REVIEW_FINDINGS.md`, `REVIEW_PROPOSED_CHANGES.md`.

This plan sequences the LLD tasks for an agent-team execution. Each task names its files, its findings/LLD coverage, and its serialization vs parallelization profile. Each milestone has a clear "done when" exit criterion.

---

## Milestones

### M1 — Surface cleanup (low risk, high signal)

Reduce dead code and tidy small smells. No behavioural changes; everything is local to one file or trivially scoped.

**Done when:** dead exports removed, doc updated, smoke test (`docs/smoke-tests.md` quick suite) passes.

**Tasks:**

| Task | LLD | Findings | Files | Owner role | Concurrency |
|------|-----|----------|-------|------------|-------------|
| T1.1 | LLD-1 | F-002 | `BagScanner.lua`, `MacroManager.lua`, `TooltipCache.lua`, `settings/Panel.lua`, `docs/module-map.md` | lua-refactorer | parallelizable with T1.2 / T1.3 / T1.4 |
| T1.2 | LLD-13 | F-012 | `Core.lua` | lua-refactorer | parallelizable with T1.1 / T1.3 / T1.4 |
| T1.3 | LLD-14 | F-015 | `Debug.lua` | lua-refactorer | parallelizable |
| T1.4 | LLD-15 | F-019 | `KCMItemRow.lua` | lua-refactorer | parallelizable |
| T1.5 | LLD-10 | F-008 | `Classifier.lua` | lua-refactorer | parallelizable |

**Concurrency map.** All five tasks touch disjoint files. **All parallelizable.**

**Suggested commit:** one commit per task, OR a single rolled-up "Surface cleanup" commit. Recommendation: one commit (these are all polish; chunky commit is fine).

---

### M2 — UX/CLI clarity touches (low risk, user-facing)

Tighten chat output and CLI feedback paths. Each is one or two lines.

**Done when:** `/cm` smoke walk per the relevant section of `docs/smoke-tests.md` passes.

**Tasks:**

| Task | LLD | Findings | Files | Owner role | Concurrency |
|------|-----|----------|-------|------------|-------------|
| T2.1 | LLD-6 | F-013 | `SlashCommands.lua` | ux-cleanup | T2.2 + T2.3 also touch this file → serialize |
| T2.2 | LLD-7 | F-022 | `SlashCommands.lua` | ux-cleanup | serialize after T2.1 |
| T2.3 | LLD-8 | F-001 | `SlashCommands.lua` | ux-cleanup | serialize after T2.2 |

**Concurrency map.** All three touch `SlashCommands.lua`. **Must serialize.** Or roll all three into one PR if your VCS prefers.

**Suggested commit:** one commit covering all three (small CLI message tweaks).

---

### M3 — Settings layer simplification (medium risk, design)

Drop the unused `FireConfigChanged` extension point. Remove the second panel-registration path. These are design-intent changes; smoke-test the panel + slash dispatch end-to-end.

**Done when:** quick smoke-test plus the targeted Settings sub-tests in `docs/smoke-tests.md` pass.

**Tasks:**

| Task | LLD | Findings | Files | Owner role | Concurrency |
|------|-----|----------|-------|------------|-------------|
| T3.1 | LLD-2 | F-007, F-014 | `settings/Panel.lua`; verify all callers | wow-api-refactor | T3.2 also touches `Core.lua`/`settings/Panel.lua` → **serialize** |
| T3.2 | LLD-3 | F-006 | `Core.lua`, `settings/Panel.lua` | wow-api-refactor | serialize after T3.1 |

**Concurrency map.** Both touch `settings/Panel.lua`. **Must serialize.**

**Checkpoint after T3.1.** Run the schema-driven get/set CLI walk to confirm the 2-arg `Helpers.Set` migration didn't drop any caller. The `/cm set debug true`, `/cm set enabled false`, `/cm set enabled true` round-trip should still print state changes and refresh the panel.

**Checkpoint after T3.2.** Open `/cm config` — verify the parent (About) page renders, every sub-page lands without error, and `Settings.OpenToCategory` still finds the right ID. Toggle the debug checkbox to confirm round-trip still works.

**Suggested commit:** two commits (one per task) — these are conceptually independent and the panel-registration consolidation should be revertable on its own if a Blizzard patch breaks the bootstrap path.

---

### M4 — Pipeline + spec-aware UI behavior (medium risk, observable)

The two behaviour changes that the user *will* notice: panel refresh while master enable is off, and viewed-spec auto-tracking on respec.

**Done when:** smoke-test specifically for both changes — open panel while off, observe rows hydrate; respec mid-session, observe panel page tracks.

**Tasks:**

| Task | LLD | Findings | Files | Owner role | Concurrency |
|------|-----|----------|-------|------------|-------------|
| T4.1 | LLD-5 | F-003 | `Core.lua` (`Pipeline.Recompute`) | wow-pipeline | parallelizable with T4.2 |
| T4.2 | LLD-4 | F-004 | `Core.lua` (`OnSpecChanged`), `settings/StatPriority.lua` | wow-pipeline | parallelizable with T4.1 |

**Concurrency map.** T4.1 touches `Core.lua` `Pipeline.Recompute`. T4.2 touches `Core.lua` `OnSpecChanged`. Both same file, but disjoint functions — **parallelizable** if the team can manage two PRs against `Core.lua`. If preferring serial, do T4.1 first.

**Checkpoint after T4.1.** Toggle master enable off, open panel, scroll the priority list — confirm rows hydrate (no permanent `[Loading]` placeholders). Toggle on, confirm macros recompute on the next event.

**Checkpoint after T4.2.** Set viewed spec manually to spec A on the Stat Priority page. Respec to spec B. Reopen panel: viewed spec stays at spec A (manual pin held). Reset by clicking "current spec" or comparable. Then leave viewed spec on auto, respec — confirm panel follows.

**Suggested commit:** two commits.

---

### M5 — Compaction and dedupe (small bug fix)

Stat priority secondary list dedupe. Touches both panel write path and slash CLI write path.

**Done when:** `/cm stat secondary CRIT,CRIT,MASTERY` and dropdown-driven duplicate selection both produce a deduped, gap-free list.

**Tasks:**

| Task | LLD | Findings | Files | Owner role | Concurrency |
|------|-----|----------|-------|------------|-------------|
| T5.1 | LLD-9 | F-005 | `settings/StatPriority.lua` (writeStatPriority), `SlashCommands.lua` (statSecondary) | wow-data-fix | **serialize** with M2 (which also touches `SlashCommands.lua`) |

If M2 is merged before M5, no conflict.

---

### M6 — Perf nibbles (lowest priority)

Optional, defer until profiling shows it matters.

**Tasks:**

| Task | LLD | Findings | Files | Owner role | Concurrency |
|------|-----|----------|-------|------------|-------------|
| T6.1 | LLD-11 | F-009 | `Ranker.lua` | perf-nibble | parallelizable |
| T6.2 | LLD-12 | F-010 | `settings/StatPriority.lua` | perf-nibble | parallelizable (defer if M5 still in flight on this file) |
| T6.3 | LLD-17 | F-017 | `settings/Category.lua` | perf-nibble | parallelizable |
| T6.4 | LLD-18 | F-020 | `KCMItemRow.lua` | perf-nibble | parallelizable; recommend skip until profiled |
| T6.5 | LLD-19 | F-021 | `SlashCommands.lua` | perf-nibble | latent — implement when first numeric dropdown row lands |
| T6.6 | LLD-16 | F-011 | `Core.lua` | doc-touch | comment-only, parallelizable |

**Concurrency map.** All disjoint files. **All parallelizable.**

---

## Critical-path summary

```
M1 (parallel)
  ↓
M2 (serial within itself; SlashCommands.lua)
  ↓
M3.T3.1 (settings/Panel.lua)
  ↓ checkpoint
M3.T3.2 (Core.lua + settings/Panel.lua)
  ↓ checkpoint
M4 (parallel within; Core.lua)
  ↓ checkpoint
M5 (depends on M2 having released SlashCommands.lua)
  ↓
M6 (parallel)
```

---

## Pause / verification points

1. **After M1.** Diff is small (deletes + renames). Smoke: `/cm`, `/cm config`, `/cm dump pick FOOD`. Quick.
2. **After M3.T3.1.** Schema-driven CLI round-trip. The Helpers.Set arity change is the riskiest piece of the plan because it touches every caller of the central setter — ensure no caller was missed.
3. **After M3.T3.2.** First panel open after a fresh login. If the bootstrap doesn't fire, panel won't open from `/cm config`.
4. **After M4.** Observable behaviour change for users. Worth a longer test session.
5. **Before M6.** Optional. M6 is opportunistic polish; only run if M1–M5 land cleanly and there's bandwidth.

---

## Incremental commit strategy

Recommend per-task commits with the following format:

```
<area>: <one-line summary>

<two-three line body>

Closes F-XXX (and F-YYY if rolled up).
```

Where `<area>` is one of: `core`, `macro`, `selector`, `ranker`, `classifier`, `tooltip`, `bagscanner`, `spechelper`, `settings`, `slash`, `widgets`, `defaults`, `docs`.

Examples:

- `selector: drop unused BagScanner.GetAllItemIDs`
- `core: remove dead _inCombat write — InCombatLockdown is canonical`
- `settings: simplify Helpers.Set to (path, value), drop FireConfigChanged stub`
- `core: fire panel refresh even when master enable is off`
- `slash: confirm /cm priority reset preserves discovered items`

---

## Out-of-scope follow-ups (noted, not in this plan)

- Wiring `FireConfigChanged` to a real CallbackHandler. Add when an external integration arrives.
- A "Track current spec" checkbox on Stat Priority to make the auto-tracking explicit.
- Memoizing `craftingQualityAtlas` results in a session-scoped cache rather than per-render.
- Profiling-driven `formatNumber` improvement.
- A `/cm gc` command if users want to manually trigger the discovered-set sweep without waiting for PEW.
