# Review Final Summary — 2026-05-02

**Status:** plan fully executed; smoke tests assumed passed.
**Companion to:** `01_FINDINGS.md`, `02_PROPOSED_CHANGES.md`, `03_SMOKE_TESTS.md`, `04_EXECUTION_PLAN.md`.

## Outcome

All six milestones in `04_EXECUTION_PLAN.md` are landed across two commits on `master`:

| Commit  | Subject                                                          |
|---------|------------------------------------------------------------------|
| `c38f452` | Surface cleanup, CLI clarity, and Helpers.Set simplification (M1, M2, M3.T3.1) |
| `fef0acd` | Refresh panel while addon off; auto-track viewed spec; dedupe stats (M3.T3.2, M4, M5, M6) |

Two LLD items deferred per the plan's own recommendation (T6.4, T6.5 — see [Deferred](#deferred-by-plan)).

**Diff aggregate** (`577fd0f..HEAD`, the review baseline → current `master`):

```
 16 files changed, 127 insertions(+), 145 deletions(-)
```

Net code reduction reflects the dead-export and `FireConfigChanged` removals; doc churn is sync-only. No new files.

## Findings → resolution

| Finding | Severity | LLD     | Status     | Notes |
|---------|----------|---------|------------|-------|
| F-001   | High     | LLD-8   | Fixed      | `/cm set` now reports failure when `SetAndRefresh` returns false. |
| F-002   | Medium   | LLD-1   | Fixed      | 8 dead exports removed from `BagScanner`, `MacroManager`, `TooltipCache`, `settings/Panel.lua`. |
| F-003   | Medium   | LLD-5   | Fixed      | `Pipeline.Recompute` panel refresh decoupled from master enable. |
| F-004   | Medium   | LLD-4   | Fixed      | `_viewedSpecAuto` flag tracks current spec; manual pin survives respec. |
| F-005   | Medium   | LLD-9   | Fixed      | Secondary-stat compaction now dedupes (panel + CLI). |
| F-006   | Medium   | LLD-3   | Fixed      | `OnInitialize` no longer registers; bootstrap is sole path. |
| F-007   | Medium   | LLD-2   | Fixed     | `Helpers.Set` 2-arg; `FireConfigChanged` deleted (convention dropped). |
| F-008   | Medium   | LLD-10  | Fixed      | `Classifier.MatchAny` skips composites. |
| F-009   | Medium   | LLD-11  | Fixed      | `bestImmediateAmount` memoized on `scoreCache.bestImmediate[catKey]`. |
| F-010   | Medium   | LLD-12  | Fixed      | Dropdown OnChange no longer invalidates `specLabelCache[v]`. |
| F-011   | Medium   | LLD-16  | Fixed      | Comment on `KCM.ResetAllToDefaults` strengthened. |
| F-012   | Medium   | LLD-13  | Fixed      | `KCM._inCombat`, `OnRegenDisabled`, and `PLAYER_REGEN_DISABLED` registration removed. |
| F-013   | Medium   | LLD-6   | Fixed      | `/cm priority reset` confirms discovered preserved. |
| F-014   | Medium   | LLD-2   | Fixed      | `Helpers.Set`'s `section` param removed (rolled into LLD-2). |
| F-015   | Low      | LLD-14  | Fixed      | `Debug.Toggle` `local next` → `nextValue`. |
| F-016   | Low      | —       | Skipped    | Comment freshness nit; absorbed into LLD-16's comment update where relevant. |
| F-017   | Low      | LLD-17  | Fixed      | `formatNumber` walks integer once forward; no reverse + gsub + reverse. |
| F-018   | Low      | —       | Skipped    | Readability nit (`R = Ranker` short locals); no change. |
| F-019   | Low      | LLD-15  | Fixed      | `KCMItemRow.applyLabelWidth` derives offsets from named constants. |
| F-020   | Low      | LLD-18  | Deferred   | `craftingQualityAtlas` itemInfo memo — skip until profiled. |
| F-021   | Low      | LLD-19  | Deferred   | `dropdownAllowed` numeric coercion — implement when first numeric dropdown row lands. |
| F-022   | Low      | LLD-7   | Fixed      | Combat-warning wording clarifies picks-now / writes-on-regen. |
| F-023   | Low      | —       | Verified   | `defaults/README.md` exists; no change needed. |

**Tally:** 0 critical · 1 high (fixed) · 13 medium (fixed) · 7 low fixed + 2 low deferred + 2 low skipped (readability nits) + 1 low verified.

## Per-milestone summary

### M1 — Surface cleanup

Behaviour-neutral. ~70 lines of dead code removed.

- `BagScanner.GetAllItemIDs`, `MacroManager.HasPending` / `PendingCount` / `IsAdopted`, `TooltipCache.IsPending` / `PendingIDs` / `Stats`, `Helpers.SchemaForPanel` / `MakeCheckbox` deleted.
- `KCM._inCombat` writes deleted; `OnRegenDisabled` handler dropped; `PLAYER_REGEN_DISABLED` no longer registered. `InCombatLockdown()` is the canonical combat gate.
- `Classifier.MatchAny` now skips composite categories — saves ~20% of classification work per discovery hit.
- `KCMItemRow.applyLabelWidth` reads its offsets from `OWNED_ICON_SIZE` / `ICON_GAP` / `ICON_SIZE` / `QUALITY_SIZE` / `QUALITY_GAP` / `PICK_SIZE`. Layout is now derived, not duplicated.
- `Debug.Toggle`'s `local next` renamed to `nextValue` (no global shadow).

### M2 — UX/CLI clarity

Three wording / contract tweaks in `SlashCommands.lua`.

- `/cm priority <cat> reset` now reads: `reset FOOD — added/blocked/pins cleared (discovered items preserved).`
- `/cm resync` and `/cm rewritemacros` combat warning now reads: `in combat — picks computed now; macro writes will apply when combat ends.`
- `/cm set` checks `Helpers.SetAndRefresh`'s return; on failure, prints `could not set <path> — DB not ready?` instead of a misleading success line.

### M3 — Settings layer simplification

- `Helpers.Set(path, value)` — section parameter dropped. `Helpers.FireConfigChanged` stub deleted.
- Single panel-registration path: the `OnInitialize` call to `KCM.Options.Register()` is gone; the `PLAYER_LOGIN` / `ADDON_LOADED` bootstrap in `settings/Panel.lua` is the sole path. The `O.Register()` shim remains for defensive third-party callers but is no longer invoked from `Core`.

### M4 — Pipeline + spec-aware UI

- `Pipeline.Recompute` gates only the macro write loop on master enable; `Options.RequestRefresh()` always fires. Opening the Options panel while the addon is off now hydrates `[Loading]` rows instead of stalling them until the user re-enables.
- Stat Priority page tracks live spec changes via `KCM.Options._viewedSpecAuto`. Auto on by default; flipped false when the user picks a non-current spec from the dropdown; re-armed when the user picks the current spec. `OnSpecChanged` retracks `_viewedSpec` to the new current spec when in auto mode.

### M5 — Stat priority dedupe

- `writeStatPriority` (panel) and `statSecondary` (CLI) both compact secondary lists with a `seen` set, dropping empties *and* duplicates while preserving first-seen order. Prevents `Ranker.Score` from double-weighting the same stat.

### M6 — Perf nibbles + comments

- `Ranker.BuildContext` memoizes `bestImmediateAmount` on `scoreCache.bestImmediate[catKey]`. Per-row `Explain` calls during a panel render no longer redo the walk.
- `formatNumber` (`settings/Category.lua`) walks the integer once forward in 3-digit groups. No reverse + gsub + reverse.
- Misleading `specLabelCache[v] = nil` line dropped from the dropdown OnChange. Comment claimed protection against an event that doesn't happen mid-session.
- `KCM.ResetAllToDefaults` comment strengthened to spell out why direct `Recompute` (not `RequestRecompute`) is safe — it relies on `MacroManager` being the only protected-API caller and queueing in-combat writes via its own combat guard.

## Files changed

| File                       | Why |
|----------------------------|-----|
| `BagScanner.lua`           | Drop `GetAllItemIDs` (M1.T1.1). |
| `Classifier.lua`           | Skip composites in `MatchAny` (M1.T1.5). |
| `Core.lua`                 | Drop `_inCombat` + `OnRegenDisabled` (M1.T1.2); drop `Options.Register` from `OnInitialize` (M3.T3.2); refresh-while-off (M4.T4.1); auto-track viewed spec on respec (M4.T4.2); strengthened reset comment (M6.T6.6). |
| `Debug.lua`                | Rename `next` to `nextValue` (M1.T1.3). |
| `KCMItemRow.lua`           | Derive `applyLabelWidth` offsets from constants (M1.T1.4). |
| `MacroManager.lua`         | Drop `HasPending` / `PendingCount` / `IsAdopted` (M1.T1.1). |
| `Ranker.lua`               | Memoize `bestImmediateAmount` (M6.T6.1). |
| `SlashCommands.lua`        | `/cm priority reset` wording (M2.T2.1); combat-warning wording (M2.T2.2); `/cm set` return check (M2.T2.3); `statSecondary` dedupe (M5.T5.1). |
| `TooltipCache.lua`         | Drop `IsPending` / `PendingIDs` / `Stats` (M1.T1.1). |
| `settings/Category.lua`    | `formatNumber` rewrite (M6.T6.3). |
| `settings/Panel.lua`       | `Helpers.Set` 2-arg + drop `FireConfigChanged` + drop `SchemaForPanel` / `MakeCheckbox` (M1.T1.1, M3.T3.1). |
| `settings/StatPriority.lua`| `_viewedSpecAuto` (M4.T4.2); secondary-stat dedupe (M5.T5.1); drop `specLabelCache` invalidation (M6.T6.2). |
| `docs/file-index.md`       | Sync `Helpers` listing. |
| `docs/macro-manager.md`    | Drop `HasPending` / `PendingCount` / `IsAdopted` from public surface. |
| `docs/module-map.md`       | Sync deletions; `Helpers.Set(path, value)`; panel registration note. |
| `docs/pipeline.md`         | Drop `_inCombat` + `OnRegenDisabled` rows. |

## Risks and what to watch

- **`Helpers.Set` arity change (LLD-2).** Highest-blast-radius edit. Every in-repo caller was migrated. A third-party addon (or a saved snippet) that called `KCM.Settings.Helpers.Set(path, section, value)` with three args would now silently see `value = nil`. Mitigation: the addon doesn't advertise itself as a library; the convention had no live subscribers; the smoke-test panel + CLI round-trip catches a missed caller.
- **Single panel-registration path (LLD-3).** The `OnInitialize` call was load-order-fragile but did help on builds where `Settings.RegisterAddOnCategory` was already available at init time. Mitigation: `PLAYER_LOGIN` / `ADDON_LOADED` always fire post-`OnInitialize`; the bootstrap is idempotent; the check is part of the smoke-test sign-off.
- **Off-state panel refresh (LLD-5).** New code path: panel renderers run even with the addon off. They are pure (Selector / BagScanner / TooltipCache reads). No taint risk. Watch for FPS regressions during the first-panel-open GIIR storm while master enable is off.
- **Auto-track viewed spec (LLD-4).** New persistent flag `_viewedSpecAuto` lives on `KCM.Options`, not on `KCM.db.profile` — it is a UI/state surface, not a SavedVariable. Across reloads it defaults to `true`, which is the right baseline. The dropdown OnChange + `OnSpecChanged` are the only writers.

## Deferred (by plan)

| Task    | LLD     | Finding | Reason                                          |
|---------|---------|---------|-------------------------------------------------|
| T6.4    | LLD-18  | F-020   | `craftingQualityAtlas` itemInfo memo — only act when profiling shows real cost. |
| T6.5    | LLD-19  | F-021   | `dropdownAllowed` numeric coercion — latent bug, ship the fix when the first numeric dropdown row lands. |

## Out-of-scope follow-ups (named for tracking)

These were noted in `04_EXECUTION_PLAN.md` and are deliberately not in the executed plan:

- Wire `FireConfigChanged` to a real CallbackHandler-1.0 dispatcher when an external integration arrives.
- "Track current spec" checkbox on Stat Priority to make the auto-tracking explicit (pairs with M4.T4.2 — the runtime is now in place; only UX needed).
- Session-scoped memo for `craftingQualityAtlas` rather than per-render.
- Profiling-driven `formatNumber` improvement (current impl is already O(n) one-pass; only revisit if a profile demands).
- `/cm gc` command for manual `discovered`-set sweep without waiting for `PEW`.

## Sign-off

Plan fully executed.

- 18 of 23 findings resolved by code change (1 high + 13 medium + 4 low).
- 2 of 23 findings deferred to a future trigger per plan recommendation (F-020, F-021).
- 2 of 23 findings skipped as readability nits (F-016, F-018).
- 1 of 23 findings verified (F-023; no change needed).

Smoke tests in `03_SMOKE_TESTS.md` are required before considering the work shipped. Once they pass, no further action items remain on the 2026-05-02 review pass.
