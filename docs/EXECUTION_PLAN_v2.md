# Ka0s Consumable Master — Execution Plan v2 (post-1.0 hardening → v1.1.0)

Companion to [TECHNICAL_DESIGN_v2.md](./TECHNICAL_DESIGN_v2.md). Acts on PE review ([docs/PE_REVIEW.md](./PE_REVIEW.md)) §§3–6 only — critical bugs, high-priority issues, medium-priority issues that survived Q&A scoping, and performance items. Section §7+ (functionality gaps, low-priority polish) is not in this plan. Items explicitly deferred live in [TODO.md](../TODO.md) under the "Deferred from PE review" block.

[EXECUTION_PLAN.md](./EXECUTION_PLAN.md) tracked the v1.0.0 milestones (M0–M8) and stays frozen. This file adds **M9, M10, M11** on top.

**How to resume**: open this file, find the first milestone whose checkboxes aren't all ticked, start there. The "Resume hint" line at the end of every milestone tells you which file to open first.

---

## Status Legend
⬜ Not started | 🟡 In progress | ✅ Complete

## Version Policy

Target release tag: **1.1.0** (minor bump — `discovered[id]` format evolves from `true` to unix timestamp, which is a visible SavedVariables format change even though it remains backward-compatible via lazy coercion). `schemaVersion` stays at 1.

The `.toc` version bump + final in-game smoke is the last checkbox of M11.

---

## Milestone 9 — Correctness pass

**Goal**: every shippable bug/semantics fix from PE §§3–5 lands. After M9 the addon is functionally correct under all observed flows: no macro flap on stack-lock events, correct drag-icon tooltips for spell picks, one bad scorer doesn't break the other seven macros, combat-deferred writes de-dupe and give up after bounded retries.

Batch order below is chosen so each change is independently compilable and testable.

### B-1 — `BagScanner.Scan` must not exclude locked items

- ✅ M9.1 In `BagScanner.lua`, drop `and not info.isLocked` from the item-collection predicate. Locked items (mailing, splitting, equipping) are still owned; excluding them causes transient macro flap.
- ✅ M9.2 Verify no other site in `BagScanner.lua` filters on `isLocked`; if any does for a genuine reason, leave it but document *why* inline.

### B-2 — `KCMMacroDragIcon` tooltip must fork on spell vs item

- ✅ M9.3 In `KCMMacroDragIcon.lua` (~line 48) replace the unconditional `GameTooltip:SetItemByID(itemID)` call with a three-branch fork mirroring `KCMItemRow`:
  - `KCM.ID.IsSpell(lastID)` + `GameTooltip.SetSpellByID` → `SetSpellByID(KCM.ID.SpellID(lastID))`
  - `KCM.ID.IsItem(lastID)` + `GameTooltip.SetItemByID` → `SetItemByID(lastID)`
  - else → plain `SetText(macroName, 1, 0.82, 0)` plus the existing empty-state body.
- ✅ M9.4 Source `lastID` from `KCM.db.profile.macroState[macroName].lastItemID` via defensive lookups (handle `nil` db / profile / state / entry).

### H-1 — Per-category recompute must be pcall-guarded

- ✅ M9.5 In `Core.lua`'s `Pipeline.Recompute`, wrap `P.RecomputeOne(cat.key, ...)` in `pcall`. On failure, emit `KCM.Debug.Print("Recompute %s failed: %s", cat.key, tostring(err))`. Do **not** break the outer loop.
- ✅ M9.6 Keep the pcall cheap — one per category per recompute (8 per frame at peak). No inner pcalls.

### H-3 — `BagScanner.HasItem` must not fall back to a full `Scan`

- ✅ M9.7 In `BagScanner.lua`, rewrite `HasItem` to return `count > 0, count` from a single `C_Item.GetItemCount(itemID, false, false, true)` call. Drop the fallback `BS.Scan()` path entirely.
- ✅ M9.8 Verify `OnItemInfoReceived` in `Core.lua` still behaves: with `HasItem` now O(1), the hundreds of `GET_ITEM_INFO_RECEIVED` events during first panel open are near-free.

### H-2 — Unify ownership predicate

- ✅ M9.9 In `Selector.lua`'s `PickBestForCategory` fallback for items, route through `KCM.BagScanner.HasItem(id)` instead of calling `C_Item.GetItemCount(id, false)` directly. Ensures the "do I own this?" question has exactly one implementation across the codebase. (This depends on M9.7.)

### H-6 — Delete dead `MAX_CHARACTER_MACROS` constant

- ✅ M9.10 In `MacroManager.lua`, remove the unused `MAX_CHARACTER_MACROS` local (we use `perCharacter=false`, so the character-macro cap is never relevant).

### M-2 — `Selector.AddItem` returns `changed` on unblock

- ✅ M9.11 Rewrite `Selector.AddItem(catKey, id, specKey)` to track `changed` across both mutations:
  ```lua
  local changed = false
  if bucket.blocked[id] then bucket.blocked[id] = nil; changed = true end
  if not bucket.added[id] then bucket.added[id] = true; changed = true end
  return changed
  ```
- ✅ M9.12 Audit callers (Options panel `afterMutation`) to ensure they respect the new semantics — unblocking a previously-blocked item now correctly triggers a recompute.

### M-5 — `MacroManager.SetMacro` de-dupes queued pending writes

- ✅ M9.13 Before the main "no-op skip" branch, add: if `pendingUpdates[macroName]` exists AND `pendingUpdates[macroName].body == body`, clear the pending entry and return `"unchanged"`. Avoids redundant `EditMacro` on regen when the queued body matches current state.
- ✅ M9.14 Adjust the existing `state.lastBody == body` branch to return "unchanged" only when there is no pending entry for that macro (so we don't double-swallow).

### M-6 — Body > 255 bytes falls back to empty-state + one-shot error

- ✅ M9.15 In `MacroManager.SetMacro`, replace the silent `body = body:sub(1, MACRO_BODY_LIMIT)` truncation with:
  - Detect `#body > MACRO_BODY_LIMIT`.
  - Build the empty-state stub for `catKey` instead.
  - Emit a one-shot chat message `"|cffff8800[KCM]|r <catKey> macro body exceeds 255 bytes — macro is inert until the picked entry's body fits. Please report this."` (guard with a module-local `alreadyWarnedOversized[catKey] = true` so repeated flushes don't spam chat).
  - Also `KCM.Debug.Print` the full oversized body for troubleshooting.
- ✅ M9.16 Proceed with the empty-state body via the normal write path (combat-safe, dedupes, etc.).

### M-9 — `LEARNED_SPELL_IN_TAB` one-shot retrigger (spell-name hydration)

- ✅ M9.17 Register `LEARNED_SPELL_IN_TAB` in `Core:OnEnable`.
- ✅ M9.18 Handler: `Pipeline.RequestRecompute("learned_spell")`. This closes the narrow window where `spellNameFor(spellID)` returned nil during macro write but the spell becomes known later in the same session without a spec change or bag event.
- ✅ M9.19 Cost: one event subscription, one frame-coalesced recompute per learn. Negligible.

### M-12 — `MacroManager.FlushPending` bounds retry attempts

- ✅ M9.20 In `MacroManager.lua`, change `pendingUpdates[name]` entries to carry an `attempts` field (default 0).
- ✅ M9.21 Rewrite `FlushPending` to:
  - Wrap the `EditMacro` call in `pcall` (or check its return value if non-zero is success).
  - On success: persist `macroState`, clear pending entry.
  - On failure: increment `entry.attempts`; if `attempts >= MAX_FLUSH_ATTEMPTS` (3), emit a one-time chat error naming the macro and drop the pending entry.
- ✅ M9.22 Expose `MAX_FLUSH_ATTEMPTS` as a local constant so tuning is a single-line edit.

### M9 smoke test (manual, in-game)

Do **all** of the following on a test character. Record pass/fail per item; any fail blocks M10.

- ✅ M9.23 **B-1 gate.** With `/kcm debug` on, `KCM_FOOD` showing a specific food item, split the stack in your bag. `KCM_FOOD` should **not** change body (no flap). Repeat while a mail envelope is open with the food attached.
- ✅ M9.24 **B-2 gate.** With Recuperate (spell sentinel `KCM.ID.AsSpell(1231411)`) as the current FOOD pick, hover the drag-icon panel. Tooltip should render the Recuperate spell tooltip, not an empty item box.
- ✅ M9.25 **H-1 gate.** In chat: `/run KCM.Ranker._scorers.FOOD = function() error("test") end; KCM.Pipeline.RequestRecompute("h1_test")`. Confirm Debug.Print logs the failure for FOOD and the other 7 `KCM_*` macros still update normally. Restore the scorer with `/reload`.
- ✅ M9.26 **H-3 gate.** With `/kcm debug` on, open the Options panel cold (`/kcm config` immediately after `/reload`). Observe no visible stutter during the `GET_ITEM_INFO_RECEIVED` burst. Optionally wrap `BagScanner.HasItem` in a one-shot `GetTime()` probe to confirm sub-millisecond.
- ✅ M9.27 **H-6 gate.** `/run print(KCM.MacroManager.MAX_CHARACTER_MACROS)` prints `nil` (constant deleted).
- ✅ M9.28 **M-2 gate.** Block an item → confirm it disappears from the priority list. Add it again via the Add-by-ID row → confirm it reappears AND the macro recomputes (not a silent no-op).
- ✅ M9.29 **M-5 gate.** With `/kcm debug` on, enter combat, split a stack to queue a pending write whose body equals the current body (e.g. via a no-op bag event), leave combat. Debug log should show the pending entry cleared without an `EditMacro` call.
- ✅ M9.30 **M-6 gate.** `/run KCM.MacroManager.SetMacro("KCM_FOOD", nil, "FOOD")` with a forced oversized body via a debug harness; confirm chat shows the one-shot error and the macro is inert (empty-state body), not truncated.
- ➖ M9.31 (deferred to TODO.md) **M-9 gate.** Respec into a build that grants a known spell listed in the Food seed list (e.g. Recuperate for Rogue). After the spell is learned, `KCM_FOOD` should recompute to the spell pick within one frame — no bag event or spec change required.
- ➖ M9.32 (deferred to TODO.md) **M-12 gate.** Force three `EditMacro` failures on a single queued entry (via a debug harness that short-circuits `EditMacro` to return 0); confirm the fourth regen exits the pending entry and prints the give-up notice.

**Resume hint**: open `BagScanner.lua` (for B-1 first).

---

## Milestone 10 — Performance pass

**Goal**: `Pipeline.Recompute` stops redundantly recomputing the same `(catKey, id)` work across categories and across the panel-render round-trip. No behaviour change.

### H-4 — Ranker score cache plumbing

- ✅ M10.1 In `Core.lua`'s `Pipeline.Recompute`, create a fresh `scoreCache = { fields = {} }` table at the top. Pass it as a new arg to `RecomputeOne(catKey, scoreCache, reason)`.
- ✅ M10.2 In `Pipeline.RecomputeOne`, thread `scoreCache` into `Selector.PickBestForCategory(catKey, scoreCache)`.
- ✅ M10.3 In `Selector.lua`, widen `PickBestForCategory(catKey, scoreCache)` and `S.GetEffectivePriority(catKey, specKey, scoreCache)` signatures. Pass `scoreCache` through to `KCM.Ranker.SortCandidates(catKey, ids, ctx, scoreCache)`.
- ✅ M10.4 In `Ranker.lua`, rewrite `Score(catKey, id, ctx, scoreCache)`:
  - If `scoreCache` is non-nil, check `scoreCache[catKey] and scoreCache[catKey][id]`; return the cached score if present.
  - Look up `itemFields` via `scoreCache.fields[id]`; if missing, compute via `TooltipCache.Get` + `C_Item.GetItemInfo` and store.
  - Compute the score, store in `scoreCache[catKey][id]`, return.
- ✅ M10.5 In `Ranker.lua`, rewrite `SortCandidates(catKey, ids, ctx, scoreCache)` to pass `scoreCache` through on every `Score` call.
- ✅ M10.6 Panel-only render paths (Options `buildCategoryArgs` → `SortCandidates`) pass `nil`. Verify `Ranker` tolerates nil (fallback to direct computation, no caching). Cover with an explicit early-out `if not scoreCache then ... end`.
- ✅ M10.7 Verify `Ranker.Explain` is unaffected — it never cached anything and shouldn't need to.

### M10 smoke test

- ⬜ M10.8 **Instrument.** Add a throwaway `local t0 = GetTime()` / `GetTime() - t0` probe around `Pipeline.Recompute` behind `KCM.Debug.IsOn()`. Measure three cold recomputes + three warm recomputes, before and after M10.
- ⬜ M10.9 **Target.** Warm recompute drops at least ~3× per the PE H-4 estimate (conservative lower bound). Cold recompute drops at least ~5×. Record numbers in a scratch note; remove the probe before commit.
- ⬜ M10.10 **Correctness.** Run `/kcm dump pick FOOD` and `/kcm dump pick CMBT_POT` before and after M10; the picked item, the order of the list, and the per-entry `Ranker.Explain` breakdowns must match exactly. No behaviour drift.
- ⬜ M10.11 **Panel.** Open the Options panel cold. Click ↑ / ↓ / × on rows across two categories; verify behaviour is unchanged and no stale scores show up.

**Resume hint**: open `Core.lua` (`Pipeline.Recompute`).

---

## Milestone 11 — Discovered-set GC + version bump

**Goal**: bounded growth of `discovered` sets across sessions (PE M-1). Tag release as v1.1.0.

### M-1 — Discovered-set garbage collection

- ✅ M11.1 In `Selector.lua`, change the semantics of `discovered[id]`: the stored value is a unix timestamp (seconds), not `true`. Legacy `true` values must still be accepted by the reader (they represent "age unknown, eligible for sweep if not seen").
- ✅ M11.2 Rewrite `Selector.MarkDiscovered(catKey, id, specKey, nowUnix)`:
  - Reject spell sentinels (`KCM.ID.IsSpell(id)` → return).
  - If `bucket.discovered[id]` is missing OR `true` OR older than `nowUnix`, write `nowUnix`.
  - Return `true` when the entry was newly created, `false` when only the timestamp bumped, so the caller can skip a UI refresh on idempotent bumps.
- ✅ M11.3 Update `Core.lua`'s `runAutoDiscovery` to pass `time()` as `nowUnix` on every discovery call.
- ✅ M11.4 Extend `Selector.BuildCandidateSet` to treat both `true` and numeric timestamps as "present in discovered" — the sign of presence is key existence, not value type.
- ✅ M11.5 Add `Selector.SweepStaleDiscovered(nowUnix)`:
  - For every category (and for spec-aware categories, every spec bucket), iterate `bucket.discovered`.
  - If `id` is currently in bags (via `BagScanner.Scan()` result, fetched once and passed through), bump the timestamp to `nowUnix` and continue.
  - Else, compute `staleTs = (value == true) and 0 or value`. If `staleTs < nowUnix - 30 * 86400`, delete the entry. (Classifier re-check is optional — not required for the TTL-only case; keep scope tight.)
  - Never touch `bucket.added` or `bucket.blocked`.
- ✅ M11.6 In `Core.lua`'s `OnPlayerEnteringWorld`, call `Selector.SweepStaleDiscovered(time())` **after** `runAutoDiscovery` and **before** the first `Pipeline.RequestRecompute`, so the recompute sees the cleaned-up state.
- ✅ M11.7 Log the sweep outcome via `KCM.Debug.Print("GC: swept N entries across M categories")` for diagnostic visibility.

### Version bump

- ✅ M11.8 Update `ConsumableMaster.toc`:
  - `## Version: 1.1.0`
- ✅ M11.9 Update the `/kcm version` output source if it doesn't read from the TOC at runtime.
- ✅ M11.10 Update `docs/TECHNICAL_DESIGN_v2.md` §4 / §12 if any final implementation detail drifted from the design during M9–M11 (this plan is the design's contract).

### M11 smoke test

- ✅ M11.11 **Format migration.** On a v1.0.0 install with existing `discovered[id] = true` entries, `/reload` into v1.1.0. Entries must still be honoured (items still appear in priority lists). Then pick up one of those items; confirm its `discovered` entry flips to a numeric timestamp via `/run for k,v in pairs(KCM.db.profile.categories.FOOD.discovered) do print(k,v) end`.
- ✅ M11.12 **Sweep trigger.** Manually age an entry: `/run KCM.db.profile.categories.FOOD.discovered[12345] = 1 -- epoch`. Ensure the itemID is NOT in your bags. `/reload`. Entry should be gone after PEW.
- ✅ M11.13 **Owned protection.** Repeat M11.12 with an item currently in your bags. After `/reload`, the entry should exist and carry a fresh (current-time) timestamp, not be deleted.
- ✅ M11.14 **User-intentional protection.** Block an item (blocked set should still contain it after `/reload`); add an item and verify it stays in `added` after `/reload`. Sweep must not touch those sets.
- ✅ M11.15 **Version.** `/kcm version` prints `1.1.0`. Settings panel shows the correct version if it surfaces one.

**Resume hint**: open `Selector.lua` (for the format change first).

---

## Post-M11 Checklist

- ⬜ Merge or tag `v1.1.0` in git per the repo's release convention.
- ⬜ Update `CLAUDE.md` only if any ground-rule changed (none of the M9–M11 changes are ground-rule-level; expect no edit here).
- ⬜ Re-read [TODO.md](../TODO.md) "Deferred from PE review" block; confirm every deferred item is still correctly described and still deferred (not accidentally implemented or made obsolete by M9–M11).
- ⬜ Archive `docs/PE_REVIEW.md` only if the user asks; by default keep it alongside v2 docs for historical reference.

---

## Sign-Off Checklist

Reading this plan, please confirm:

1. **Milestone split** — M9 correctness, M10 performance, M11 discovered-GC — is the right granularity vs a single post-1.0 hardening milestone.
2. **B-1 through M-12 assignment to M9** — nothing moved to M10 or M11 that belongs in M9 or vice versa.
3. **Smoke tests** cover the right symptoms (stack split for B-1, spell pick for B-2, forced scorer error for H-1, etc.). If any gate is too easy or too hard, say so.
4. **M-6 error UX** — one-shot chat error + Debug.Print + empty-state fallback — acceptable, or do you want the chat error throttled per session instead of per-catKey-once-forever?
5. **M-12 `MAX_FLUSH_ATTEMPTS = 3`** — right number, or too aggressive / too lax?
6. **M11.5 classifier re-check** — I dropped it from the sweep to keep scope tight; TTL alone is the gate. Agree, or want the classifier re-check in?
7. **Version bump to 1.1.0** happens at M11.8 (end of the hardening pass), not earlier.

Once confirmed, I'll start executing M9.1.
