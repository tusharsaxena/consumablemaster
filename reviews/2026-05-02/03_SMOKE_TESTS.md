# Smoke Tests — 2026-05-02 review execution

**Scope.** Verify the changes in commits `c38f452` and `fef0acd` did not regress functionality and produced the user-visible behaviour the plan promised. Companion to `01_FINDINGS.md` / `02_PROPOSED_CHANGES.md` / `04_EXECUTION_PLAN.md`.

**Approach.** Per-milestone checklist. Each step lists the change, the action, what to observe, and what *must not* happen. Run sequentially — later steps assume earlier ones passed. Stop and report on the first failure rather than chaining them.

**Pre-test setup (do once).**

1. Pin the default chat frame and enable `/cm debug` so `[CM]` lines surface immediately.
2. Drag every `KCM_*` macro onto a visible action bar so icon and tooltip changes are observable: `KCM_FOOD`, `KCM_DRINK`, `KCM_HP_POT`, `KCM_MP_POT`, `KCM_HS`, `KCM_FLASK`, `KCM_CMBT_POT`, `KCM_STAT_FOOD`, `KCM_HP_AIO`, `KCM_MP_AIO`.
3. Have a target dummy or low-stakes mob nearby so you can enter combat on demand.
4. Have at least one alt with a different spec ready (or be ready to respec) — needed for M4.T4.2.
5. Note your current spec so you can compare before/after.

---

## M1 — Surface cleanup

Behaviour-neutral cleanup. The smoke test is mostly *negative*: nothing should look different.

### M1.T1.1 — Dead exports removed

1. `/reload`. Expect: no Lua errors, no nil-indexing tracebacks at file load.
2. `/cm` (the help dispatch) — every command in the help list still resolves.
3. `/cm dump pick FOOD`, `/cm dump pick HP_AIO`, `/cm dump pending` (if you have it), `/cm list`, `/cm get debug`, `/cm set debug true`, `/cm set debug false`. Each prints a sensible reply; none traceback.
4. Open the Options panel via `/cm config` — every sub-page renders, no errors.

**Must not see:** any `attempt to call a nil value` for `BagScanner.GetAllItemIDs`, `MacroManager.HasPending` / `PendingCount` / `IsAdopted`, `TooltipCache.IsPending` / `PendingIDs` / `Stats`, `Helpers.SchemaForPanel` / `MakeCheckbox`. (No code in the addon should reference them, but third-party WeakAuras / addons hooking these would trip here.)

### M1.T1.2 — `_inCombat` state and `OnRegenDisabled` removed

1. Engage a target dummy (enter combat). Expect: no Lua errors at combat-start.
2. Drop combat. Expect: any pending macro write from M2/M5 work flushes; you see the `FlushPending applied N macro(s)` debug line if there were any. No errors.
3. Re-enter combat, change bags (move an item between bag slots), drop combat. Expect macro queue flushes correctly and debug line shows.

**Must not see:** any Lua error referencing `_inCombat`, `OnRegenDisabled`, or `PLAYER_REGEN_DISABLED`. (None should — but a stray third-party hook on these would fail loudly.)

### M1.T1.3 — `Debug.Toggle` `next` rename

1. `/cm debug` — toggle once. Expect: chat prints "Debug prints are now enabled." (or "OFF" — depends on prior state).
2. `/cm debug` again. Expect symmetric result.
3. Confirm the General page checkbox flipped in lockstep.

**Must not see:** any `bad argument to next` or table-iteration errors (would indicate the old `local next` shadow was load-bearing somewhere it shouldn't be).

### M1.T1.4 — `applyLabelWidth` derived from constants

1. Open `/cm config` → any single-pick category page (e.g. **Food**, **Hp Pot**).
2. Scroll the priority list. Confirm row layout looks identical to before: owned-glyph, item icon, optional quality glyph, name, pick star.
3. Resize the Settings window narrower then wider. Names truncate / re-expand cleanly without overflowing into the pick star column.
4. Pick an item with a long name (e.g. a Midnight tier flask) — name truncates with `...` rather than crashing layout.

**Must not see:** rows where the name overlaps the pick star, names spilling onto a second line, or the pick star bumped to the next Flow cell.

### M1.T1.5 — `Classifier.MatchAny` skips composites

1. Loot or move a *single-pick* item into bags (a flask, food, pot — anything that wasn't there before).
2. `/cm dump pick FLASK` (or whatever cat). Expect: the item appears with a score; no chat lines reference HP_AIO / MP_AIO discovery.
3. With `/cm debug` on, watch the "Discovered" lines during a `/cm resync`. Expect: never see `Discovered: HP_AIO ...` or `Discovered: MP_AIO ...`.

**Must not see:** composite categories appearing in any `Discovered:` debug line or in `/cm dump` discovered-set output.

---

## M2 — UX/CLI clarity

### M2.T2.1 — `/cm priority reset` says discovered preserved

1. `/cm priority FOOD list` — note any items in the discovered set.
2. `/cm priority FOOD reset`. Expect chat: `reset FOOD — added/blocked/pins cleared (discovered items preserved).`
3. `/cm priority FOOD list` again — confirm the discovered items are still there. Macros recompute via `afterMutation`.

**Must not see:** the old wording (`added/blocked/pins cleared.` without the parenthetical), or the discovered set actually being wiped.

### M2.T2.2 — Combat-warning wording on `/cm resync` and `/cm rewritemacros`

1. Engage a target dummy.
2. While in combat: `/cm resync`. Expect chat: `in combat — picks computed now; macro writes will apply when combat ends.`
3. While still in combat: `/cm rewritemacros`. Same wording line.
4. Drop combat — pending macro writes flush.

**Must not see:** the old wording (`macro writes deferred until regen.`).

### M2.T2.3 — `/cm set` checks return value

1. `/cm set debug true` (or `false`). Expect chat: `debug = true`.
2. `/cm set debug false`. Expect: `debug = false`.
3. Confirm the General page checkbox tracks each toggle.
4. **(Optional, hard to reproduce):** if you have a way to trigger a Resolve failure (e.g. by editing the schema to point at a path that doesn't resolve, or running `/cm set` against an unhydrated DB), expect chat: `could not set debug — DB not ready?` instead of a fake "succeeded" line.

**Must not see:** `/cm set` printing the success-shaped `path = value` line when the DB write actually failed.

---

## M3 — Settings layer simplification

### M3.T3.1 — `Helpers.Set` 2-arg + `FireConfigChanged` deleted

This is the highest-risk change in the plan because the Helpers.Set arity migrated and every caller had to update.

1. `/reload`. Expect no Lua errors at load.
2. `/cm config` — open the Options panel. General page checkboxes (Enable, Debug) render with their correct values.
3. Toggle the Debug checkbox via the panel. Expect: chat prints state line, panel re-syncs, `/cm get debug` matches.
4. Toggle the Enable checkbox via the panel. Expect: pipeline behaves correctly (off → macros stop being rewritten on events; on → macros refresh).
5. `/cm set debug true`, `/cm set debug false`, `/cm set enabled true`, `/cm set enabled false`. Each round-trip prints the new value. The panel re-renders.
6. `/cm get debug`, `/cm get enabled` reflect the latest values.

**Must not see:** any `attempt to call a nil value (field 'FireConfigChanged')` or `bad argument #2 to 'Set'`. Any caller that wasn't migrated would trip here.

### M3.T3.2 — Single panel-registration path

1. `/reload`. Watch the chat for any registration error.
2. `/cm config` — Options panel opens to **Ka0s Consumable Master** parent (the About splash). Every sub-page (General, Stat Priority, Food, Drink, Hp Pot, Mp Pot, Hs, Flask, Cmbt Pot, Stat Food, Hp Aio, Mp Aio) is reachable via the AddOns sidebar.
3. Click each sub-page. Expect: header renders, content body renders, no errors.
4. Use Blizzard's settings search bar — search "Consumable" — confirm the parent appears.
5. Close and reopen the panel multiple times. Sub-page state (selected viewed spec, scroll position via re-render) behaves consistently.

**Must not see:** the panel failing to open from `/cm config`, "settings panel unavailable on this client" warnings on a normal client, duplicate panel entries in the sidebar, or sub-pages missing.

---

## M4 — Pipeline + spec-aware UI behaviour (observable changes)

### M4.T4.1 — Panel refresh fires while master enable is off

This is the test users will *see* the difference for.

1. Turn master enable **on**. Open `/cm config` → **Stat Priority**. Watch a priority list row that shows `[Loading]` if any (otherwise pick a category page like **Hp Pot** with several items).
2. `/reload` to force item-info hydration. Within 1–2 seconds rows should swap `[Loading]` for real names.
3. Now turn master enable **off** (General page checkbox).
4. `/reload` again so the item-info hydration storm fires while the addon is off. Open the panel.
5. Expect: rows swap `[Loading]` for real names within 1–2 seconds *despite* master enable being off.
6. Confirm macros are *not* being rewritten — drag a `KCM_*` macro icon, note the body, swap an item out of bags, observe the body does not change.
7. Turn master enable **on**. Macros recompute on the off→on transition (the toggle's onChange).
8. Debug log while off: with `/cm debug` on, expect `Pipeline.Recompute skipped writes (disabled): reason=...` lines (note the new `skipped writes` wording vs. the old `skipped (disabled)`).

**Must not see:** rows stuck on `[Loading]` permanently while master enable is off; macros being written while off.

### M4.T4.2 — Auto-track viewed spec on respec

1. Open `/cm config` → **Stat Priority**. Note the Viewing-spec dropdown shows your current spec.
2. Without touching the dropdown, respec to a different spec via the talents UI.
3. Reopen `/cm config` → **Stat Priority**. Expect: the dropdown now shows your *new* current spec; the priority editor shows the new spec's stats.
4. Now manually pick a *different* spec from the dropdown (one that is not your current spec).
5. Respec back to your original spec. Reopen the panel. Expect: the dropdown still shows the spec you manually pinned (the manual pin survives respec).
6. From the dropdown, manually pick the spec you are *currently* on. This re-arms auto-tracking.
7. Respec to a different spec. Reopen the panel — the dropdown now follows the new current spec.

**Must not see:** the panel sticking on the old spec after respec when you hadn't manually pinned anything; the manual pin being lost after respec.

---

## M5 — Stat priority dedupe

### M5.T5.1 — Secondary-stat compaction with dedupe

Test both the panel write path and the CLI write path.

**Panel path:**

1. Open `/cm config` → **Stat Priority**. Pick any spec.
2. Set Secondary #1 = `Critical Strike`, Secondary #2 = `(none)`, Secondary #3 = `Critical Strike` (duplicate), Secondary #4 = `Mastery`.
3. Click the dropdown for any other field to trigger the write. Then close + reopen the panel (forces re-read from DB).
4. Expect saved order: `[Critical Strike, Mastery]` — the empty slot was dropped, the duplicate `Critical Strike` was dropped.
5. Reset and try: `[Crit, Crit, Crit, Crit]` → should compact to `[Crit]` (single entry).

**CLI path:**

1. `/cm stat secondary CRIT,CRIT,MASTERY [specKey]` (use your current spec key from `/cm dump`). Expect chat: `statpriority.<specKey>.secondary = CRIT, MASTERY`.
2. `/cm stat secondary CRIT,HASTE,CRIT,MASTERY,HASTE`. Expect: `CRIT, HASTE, MASTERY` (dedupes both `CRIT` and `HASTE` while preserving order).
3. `/cm stat secondary CRIT,FOO,MASTERY` (with a bad token). Expect chat: `Unknown secondary stat(s): FOO. Allowed: ...`. The list is *not* written (validation failure preserves prior state).

**Must not see:** the secondary list ending up with two entries for the same stat (would double-weight in `Ranker.Score`).

---

## M6 — Perf nibbles

### M6.T6.1 — `bestImmediateAmount` cached

This is a perf change; behaviour must be unchanged.

1. `/cm dump pick HP_POT` — note the priority list and scores.
2. `/cm dump pick MP_POT` — note same.
3. Open `/cm config` → **Hp Pot** page. Hover over the score-info button on each priority row (this calls `Ranker.Explain` which calls `BuildContext`).
4. Expect: tooltips show the same scores as the dump, including the `bestImmediateAmount` signal.
5. With `/cm debug` on, sanity check a recompute via `/cm resync` — the run should be *fast* (subjectively) and produce the same picks as before the change.

**Must not see:** different HP_POT / MP_POT picks from the dump vs. the panel; the `bestImmediateAmount` signal in `Explain` differing from `SortCandidates`.

### M6.T6.2 — `specLabelCache` invalidation dropped

1. Open `/cm config` → **Stat Priority**. Open the Viewing-spec dropdown. Confirm class+spec icons render correctly for every entry.
2. Pick several specs in rapid succession. Each label renders correctly with its icon — no broken texture references.
3. `/reload`. Reopen the dropdown — same labels, no flicker, no stale icons.

**Must not see:** broken icon textures; missing class+spec labels.

### M6.T6.3 — `formatNumber` rewrite

1. `/cm dump pick FOOD` — confirm scores print with thousands separators (e.g. `12,345`).
2. Hover the score-info button on a priority list row in the panel — confirm the score-tooltip body has thousands separators on every numeric line.
3. Edge cases: any score under 1,000 prints without commas. Any large score (≥10,000) has commas in the right places. Negative scores (rare but possible from a punishment signal) format as `-12,345`. Fractional scores print with `.1` decimal.
4. Spot-check a known item and confirm the displayed score matches what the old code would have produced (compare against a recent screenshot or a second client running the prior version, if available).

**Must not see:** missing or misplaced commas; numbers like `1,2345` or `12,34,5`; negative sign in the wrong position.

### M6.T6.6 — `KCM.ResetAllToDefaults` comment touch (no behaviour change)

This is a comment-only change. No runtime test needed beyond confirming `/cm reset` and the **Reset all priorities** panel button still work:

1. `/cm reset` → confirm popup → accept. Expect: discovered set re-fills, macros refresh. No errors.
2. **General → Reset all priorities** button → confirm popup → accept. Same expectation.

**Must not see:** any error during reset; any macro left in a stale state.

---

## Final sign-off checklist

Run after all milestone tests pass.

- [ ] `/reload`, no Lua errors at load.
- [ ] `/cm` help prints, every documented command works.
- [ ] All 10 `KCM_*` macros exist with correct bodies and icons.
- [ ] `/cm config` opens, every sub-page renders.
- [ ] Master enable on/off transitions work cleanly (macros refresh on on; rows hydrate while off).
- [ ] Spec change auto-tracks the panel when no manual pin; honors the pin when set.
- [ ] Stat priority secondary list never contains duplicates.
- [ ] CLI confirmations match the new wording (priority reset, combat warning, set-failure).
- [ ] Combat-deferred macro writes flush on `PLAYER_REGEN_ENABLED`.
- [ ] Both reset paths (`/cm reset` and panel button) work end-to-end.

If any check fails, report the milestone + step number; the change set is small enough that bisecting between commits `c38f452` and `fef0acd` will isolate the regression.
