# Principal-Engineer Review — Ka0s Consumable Master v1.0.0

**Reviewer:** Claude Opus 4.7 (acting as principal engineer / WoW addon dev)
**Scope:** complete codebase audit — architecture, design, code quality, bugs, performance, functionality gaps.
**Method:** read every non-vendored Lua file plus `ConsumableMaster.toc`, `embeds.xml`, `defaults/`, design docs, and the diffs that landed since launch. Cross-referenced behaviour against documented intent in `CLAUDE.md`, `ARCHITECTURE.md`, `docs/TECHNICAL_DESIGN.md`, and `docs/REQUIREMENTS.md`.

> **Reading order if you only have ten minutes:** §0 Executive Summary → §3 Critical Bugs → §6 Performance.

---

## §0 Executive Summary

This is a **well-architected, idiomatically-written WoW addon**. The combat-safety story (single protected-API call site behind a deferral queue) is correct, the data model is clean and forward-compatible, the Ace3 wiring is conventional, and the documentation is unusually thorough. The codebase is in good shape for a 1.0.0 release.

The findings below are mostly **medium-severity polish** rather than red-flags. The two issues I would not ship without addressing are:

1. **B-1 — `BagScanner.Scan` skips `isLocked` items.** Causes the macro to flap to empty-state when a stack is briefly locked (mailing, equipping, splitting). Visible to users.
2. **B-2 — `KCMMacroDragIcon` calls `GameTooltip:SetItemByID` with a possibly-negative `lastItemID` for spell macros.** Will show a broken/empty tooltip on hover for the macro icon when the active pick is a spell.

Everything else is incremental.

---

## §1 Strengths Worth Preserving

These are the load-bearing decisions that the codebase gets right. Future refactors should not regress them.

1. **Pure-vs-protected split.** `MacroManager` is the only module that touches `CreateMacro` / `EditMacro`. Every other module (`Selector`, `Ranker`, `Classifier`, `BagScanner`, `TooltipCache`, `SpecHelper`, `Options`) is pure and combat-safe. This is the single most important property of the design — keep it inviolate.

2. **Frame-coalesced pipeline.** `Pipeline.RequestRecompute` collapses bursts of `BAG_UPDATE_DELAYED` / `GET_ITEM_INFO_RECEIVED` into one `C_Timer.After(0, ...)` recompute per frame. The right pattern for event-driven WoW work.

3. **Combat deferral with last-write-wins.** `MacroManager.pendingUpdates[macroName] = ...` correctly de-dupes by macro name, so a flurry of bag changes during combat collapses to one write at `PLAYER_REGEN_ENABLED`. No queued duplicates.

4. **Data-driven categories.** `defaults/Categories.lua` plus per-category `Defaults_*.lua` seed lists make adding a category a 7-step recipe (documented in `CLAUDE.md`). The decision to keep matchers/scorers in dispatch tables (not chains of `if catKey == ...`) keeps this extensible.

5. **Opaque-numeric ID convention.** Items are positive numbers, spells are negative numbers (`KCM.ID.AsSpell(spellID) → -spellID`). The whole pipeline (Selector buckets, pins, blocked, Ranker) treats them as opaque keys; only `MacroManager`, `Ranker.Score`'s spell shortcut, and the UI fork on the sign. This is a textbook example of using a discriminated union without a schema migration.

6. **Seed ∪ added ∪ discovered − blocked.** Membership math is centralised in `Selector.BuildCandidateSet` and the user can bump seed lists at patch time without breaking SavedVariables. Refresh is zero-migration. (Documented in `defaults/README.md`.)

7. **Centralised reset.** `KCM.ResetAllToDefaults` is the single mutation entrypoint shared by both the slash command's StaticPopup and the Options "Reset all priorities" execute. No semantic drift between paths.

8. **Tooltip parsing is documented and patch-aware.** The list of Midnight gotchas in `CLAUDE.md` (subtype renames, NBSP, `|4singular:plural;` escapes, `GET_ITEM_INFO_RECEIVED` not firing for cached items, FLASK skipping the tooltip gate) is the kind of institutional knowledge that prevents 1-day regressions every patch.

9. **Static popup taint discipline.** `SlashCommands.lua:13-19` correctly avoids re-assigning `StaticPopupDialogs` and explains the taint cascade. This is one of the most common Ace3 footguns and the comment alone justifies its existence.

10. **AceConfigDialog widget hijacking is principled.** The `KCM*` widgets stub `SetText` / `SetFontObject` / `SetLabel` no-ops where AceConfigDialog assumes a label-bearing widget; the widget then renders its own content. Comments explain why — this is the right way to extend AceConfig without forking it.

---

## §2 Architecture Review

### 2.1 Module map

```
Core.lua                  -- AceAddon entry, DB defaults, Pipeline orchestrator,
                              event handlers, KCM.ID sentinel helpers, ResetAllToDefaults

Debug.lua                 -- Conditional logger gated on profile.debug

defaults/Categories.lua   -- Category metadata table + BY_KEY index
defaults/Defaults_*.lua   -- Seed lists; each writes KCM.SEED.<KEY>

SpecHelper.lua            -- Spec identity + stat-priority resolution (user → seed → fallback)
TooltipCache.lua          -- C_TooltipInfo parser + session cache
BagScanner.lua            -- C_Container enumeration → {[itemID]=count}
Classifier.lua            -- (itemID,tt,subType) → bool, MatchAny → [catKey]
Ranker.lua                -- Per-category scorers + Explain + SortCandidates
Selector.lua              -- Candidate set + pin merge + GetEffectivePriority + PickBestForCategory
MacroManager.lua          -- The ONLY caller of CreateMacro/EditMacro

Options.lua               -- AceConfig-driven settings panel
SlashCommands.lua         -- /kcm dispatcher

KCMItemRow.lua            -- AceGUI custom row widget (icon + status + name + pick star)
KCMIconButton.lua         -- AceGUI gold-hover icon button (used for ↑/↓/×)
KCMScoreButton.lua        -- AceGUI info-button (per-row score breakdown)
KCMHeading.lua            -- AceGUI section heading (large font variant)
KCMTitle.lua              -- AceGUI page-title banner (22pt gold)
KCMMacroDragIcon.lua      -- AceGUI draggable macro icon (places KCM_* on action bar)
```

This is a clean dependency graph. Pipeline is at the top (depends on most things); Categories + KCM.ID are at the bottom (depended on by most things). No cycles. No file imports a downstream module.

### 2.2 Data flow (recompute path)

```
event (PEW / BAG_UPDATE_DELAYED / SPEC_CHANGED / GET_ITEM_INFO_RECEIVED)
   ↓
Core.<event handler>
   ↓
runAutoDiscovery (where applicable)        -- BagScanner.Scan + Classifier.MatchAny
   ↓                                          + Selector.MarkDiscovered
Pipeline.RequestRecompute                  -- frame-coalesced
   ↓
Pipeline.Recompute
   ↓ for each category
Pipeline.RecomputeOne(catKey)
   ↓
Selector.PickBestForCategory(catKey)       -- GetEffectivePriority → first-owned walk
   ↓                                         (TooltipCache.Get + Ranker.Score per item)
MacroManager.SetMacro(macroName, pick, catKey)
   ↓
   in combat?  → pendingUpdates[macroName] = {body,...}; return "deferred"
   unchanged?  → return "unchanged"
   else        → CreateMacro / EditMacro; persist macroState
```

PR: this is correct and well-factored. Note one subtlety: `Pipeline.Recompute` also calls `Options.RequestRefresh` so the panel debounces a rebuild. User-driven panel mutations call `Options.Refresh` directly via `afterMutation` for snappy click feedback. Good split.

### 2.3 Persistence

- `ConsumableMasterDB` (AceDB profile-scoped). Profile defaults declared in `Core.dbDefaults`.
- `schemaVersion = 1` set; no migration shim yet (correct — v1 is the launch version).
- Spec-aware buckets live in `categories[<KEY>].bySpec[<classID>_<specID>]`; non-spec-aware buckets are flat.
- `macroState[macroName] = { lastItemID, lastBody, lastCat }` so SetMacro can early-out on unchanged bodies.

The schema is forward-compatible with a `Migrations.lua` shim added when needed (per `TECHNICAL_DESIGN.md` §7). Don't migrate prematurely.

### 2.4 Concerns at the architecture level

- **No bounded-growth strategy for `discovered` sets.** They accumulate across sessions. See M-3.
- **No `pcall` around per-category recompute.** A bug in one scorer could break the entire pipeline. See M-1.
- **`OnItemInfoReceived` and `Pipeline.Recompute` paths can both call `O.RequestRefresh` in the same frame.** That's fine (debouncer collapses), but worth noting that the panel's open-state has a measurable cost during burst events.

Otherwise the architecture is sound and I would not refactor it.

---

## §3 Critical Bugs (ship-blockers, in my view)

### B-1 — `BagScanner.Scan` excludes locked items, causing macro flap

**Location:** `BagScanner.lua:36`

```lua
if info and info.itemID and not info.isLocked then
```

`info.isLocked` becomes true briefly in many normal flows — splitting a stack, picking up to mail, equipping, dragging to the trade window, etc. While locked, `Scan` reports zero copies of that item, `PickBestForCategory` falls through to the next priority entry, the macro rewrites, and on unlock it rewrites back. From the user's perspective the macro flaps.

**Fix:**
```lua
if info and info.itemID then
```

**Why:** the lock is transient and unrelated to "do I have this item" — it just means another in-flight action holds the slot.

**Verification (pending in-game test):** trigger by splitting any stack of food in your bag and observing whether the FOOD macro changes briefly. Should NOT.

### B-2 — `KCMMacroDragIcon` passes spell-sentinel itemID to `GameTooltip:SetItemByID`

**Location:** `KCMMacroDragIcon.lua:48-50`

```lua
local itemID = entry and entry.lastItemID
if itemID and GameTooltip.SetItemByID then
    GameTooltip:SetItemByID(itemID)
```

When the active pick is a spell entry (e.g. Recuperate at the top of FOOD), `macroState.lastItemID` holds a *negative* spell sentinel (set by `MacroManager.SetMacro` from the opaque `id`). `SetItemByID(-1231411)` will error or render an empty tooltip.

**Fix:**
```lua
local KCM = _G.KCM
local state = KCM and KCM.db and KCM.db.profile and KCM.db.profile.macroState
local entry = state and state[macroName]
local lastID = entry and entry.lastItemID
if lastID and KCM.ID and KCM.ID.IsSpell(lastID) and GameTooltip.SetSpellByID then
    GameTooltip:SetSpellByID(KCM.ID.SpellID(lastID))
elseif lastID and KCM.ID and KCM.ID.IsItem(lastID) and GameTooltip.SetItemByID then
    GameTooltip:SetItemByID(lastID)
else
    GameTooltip:SetText(macroName, 1, 0.82, 0)
    -- ...existing fallback body block
end
```

This mirrors `KCMItemRow`'s already-correct fork (`SetSpellByID` vs `SetItemByID`). Worth adding a regression test path: set Recuperate as the pick, drag the macro icon, verify the tooltip.

---

## §4 High-Priority Issues

### H-1 — Pipeline-wide recompute is unguarded; one bad scorer breaks all eight macros

**Location:** `Core.lua:86-102` (`Pipeline.Recompute`)

```lua
for _, cat in ipairs(KCM.Categories.LIST) do
    P.RecomputeOne(cat.key, reason)
end
```

If `RecomputeOne(cat.key)` raises (e.g. a malformed tooltip causes a Ranker scorer to nil-arith), the loop terminates and the remaining categories are left at their previous macro body. With AceDB's silent error swallow there's no surfaced symptom — just stale macros.

**Fix:** wrap each per-category call:
```lua
for _, cat in ipairs(KCM.Categories.LIST) do
    local ok, err = pcall(P.RecomputeOne, cat.key, reason)
    if not ok and KCM.Debug and KCM.Debug.Print then
        KCM.Debug.Print("Recompute %s failed: %s", cat.key, tostring(err))
    end
end
```

Cost: a `pcall` per category per recompute. Recompute fires at most once per frame, so 8 pcalls/frame at peak. Negligible.

### H-2 — `PickBestForCategory` and `BagScanner.HasItem` have inconsistent reagent-bank semantics

**Location:** `Selector.lua:246` vs `BagScanner.lua:51`

```lua
-- Selector.PickBestForCategory fallback:
elseif C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id, false) > 0 then

-- BagScanner.HasItem:
local count = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(itemID, false, false, true)
```

`GetItemCount(itemID, includeBank, includeUses, includeReagentBank)` — `BagScanner.HasItem` includes the reagent bank, the Selector fallback does not. The Selector fallback only triggers when `BagScanner` is unavailable, which is unlikely in practice, but the divergence is a maintenance trap.

**Fix:** route the Selector fallback through `BagScanner.HasItem` or pin both call sites to the same arg list. Prefer the former — there's no reason for two ownership predicates.

### H-3 — `OnItemInfoReceived` assumes `BagScanner.HasItem` is cheap; it does a full `Scan()` on its fallback path

**Location:** `Core.lua:266` calls `KCM.BagScanner.HasItem(itemID)`. `BagScanner.HasItem` uses `C_Item.GetItemCount` first (cheap), but if that returns 0 it falls back to a **full `BS.Scan()`** (every bag, every slot) just to look up one ID.

```lua
function BS.HasItem(itemID)
    local count = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(itemID, false, false, true)
    if count and count > 0 then return true, count end
    local counts = BS.Scan()       -- ← O(bags * slots) for a single-item question
    local c = counts[itemID] or 0
    return c > 0, c
end
```

During first PEW the panel may receive 100+ `GET_ITEM_INFO_RECEIVED` events for non-bag items. Each one does `HasItem(itemID) → returns false → triggers a refresh debounce` — but the path also runs the fallback `Scan` for every event, which is the dominant CPU cost. (The `count > 0` branch is taken when the item *is* in bags, but for non-bag items the GetItemCount returns 0 and the scan fires.)

**Fix:** drop the fallback. `C_Item.GetItemCount` is reliable for the "is it in my bags" question; the linear-scan fallback was a defensive over-engineering and is the wrong tool when called from a hot event path.

```lua
function BS.HasItem(itemID)
    if not itemID then return false, 0 end
    local count = (C_Item and C_Item.GetItemCount) and C_Item.GetItemCount(itemID, false, false, true) or 0
    return count > 0, count
end
```

If a real-world case turns up where `GetItemCount` lags behind `BAG_UPDATE_DELAYED`, fix it via a single `Scan()` cached per-frame, not a per-call rescan.

### H-4 — `Ranker.SortCandidates` repeats `TooltipCache.Get` work for every Score call within one sort

**Location:** `Ranker.lua:60-64` (`itemFields`)

`itemFields` calls `TooltipCache.Get(itemID)` for each scorer invocation. `SortCandidates` invokes `Score` once per candidate; pin merge and effective-priority don't re-invoke. So *for one category* the per-item cost is one `TC.Get` per candidate — fine. **But** `Pipeline.Recompute` walks all 8 categories, and `PickBestForCategory` may be called twice per recompute when the panel is open (once for macro write, once for Options panel build).

For a typical user with Stat Food (~17 entries) + Flask (~6) + Combat Pot (~6) + others, that's roughly 100 TC.Get calls per recompute when the panel is open, doubled to 200 if the panel is rebuilding. Each `TC.Get` is a cache hit after the first session — cheap — but the call overhead adds up during PEW.

**Fix:** memoise per-recompute. Either:
- pass an explicit `cache` table through `SortCandidates` → `Score` so a single `Pipeline.Recompute` reuses the lookups; or
- have `Pipeline.Recompute` build a `Map<itemID, ttEntry>` for every candidate-set union upfront and feed it via ctx; or
- cache `Score` results per `(catKey, itemID, ctx-fingerprint)` with invalidation on TooltipCache invalidate.

Simplest is #1. Lowest code change. ~10× speedup on hot paths.

### H-5 — `Pipeline.RequestRecompute` keeps `_recomputeReason` only for the *first* request in the burst

**Location:** `Core.lua:104-121`

```lua
function P.RequestRecompute(reason)
    KCM._recomputePending = true
    KCM._recomputeReason  = reason or KCM._recomputeReason or "unknown"
```

The `or KCM._recomputeReason` clause means once the reason is set, subsequent requests in the same burst can't override it (they pass a non-nil reason but it falls through because of the precedence — actually wait, `reason or ...` → if `reason` is non-nil, that's the value used, so the comment in code is misleading).

Looking again: the OR chain is `reason or _recomputeReason or "unknown"`. If `reason` is truthy, `_recomputeReason` is overwritten. So actually the *last* request's reason wins. That's fine semantically.

But: the field is read once and cleared inside the callback — multiple reasons within the same burst are flattened to the last-set one, which loses debugging information. Low priority.

**Suggestion:** if you ever need richer reason tracking, accumulate into a set. Otherwise leave it.

### H-6 — `MAX_CHARACTER_MACROS` is dead code

**Location:** `MacroManager.lua:18`

Defined, never read. Either delete or actually enforce it (we use `perCharacter=false` so character macros aren't relevant — delete).

---

## §5 Medium-Priority Issues

### M-1 — `discovered` sets grow unboundedly across sessions

If a user loots a one-shot consumable that classifies into a category, it's marked discovered and stays in SavedVariables forever. Over months, the discovered set for FOOD could hold dozens of stale IDs. They all show in the priority list as "not in bags" rows.

**Fix:** garbage-collect by sweeping `discovered` and dropping IDs that no longer match the classifier OR haven't been seen in N days. Add a `lastSeenAt` timestamp on discovery and prune entries older than ~30 days during `OnPlayerEnteringWorld`. Don't sweep `added` (user-intentional) or `blocked` (user-intentional).

### M-2 — `Selector.AddItem` clears the blocklist but doesn't return that as a separate signal

```lua
function S.AddItem(catKey, itemID, specKey)
    local bucket = S.GetBucket(catKey, specKey)
    if not bucket or not itemID then return false end
    bucket.blocked[itemID] = nil
    if bucket.added[itemID] then return false end
    bucket.added[itemID] = true
    return true
end
```

If the item was blocked but already in `added`, we clear the block and return `false` — the caller (Options panel) thinks "no change" and skips the recompute, but actually unblocking IS a meaningful change (the item now appears in candidates).

**Fix:** track whether either field changed:
```lua
local changed = false
if bucket.blocked[itemID] then bucket.blocked[itemID] = nil; changed = true end
if not bucket.added[itemID] then bucket.added[itemID] = true; changed = true end
return changed
```

### M-3 — `Pipeline.RecomputeOne(catKey, reason)`: `reason` is unused

The per-category log is commented out; the parameter is dead. Either keep the log live behind a more granular debug flag, or drop the parameter. (Mild — affects readability only.)

### M-4 — `Ranker.itemFields` uses legacy `GetItemInfo`, not `C_Item.GetItemInfo`

```lua
local _, _, quality, ilvl, _, _, subType = GetItemInfo(itemID)
```

`C_Item.GetItemInfo` is the modern equivalent (legacy global still works). Same for `KCMItemRow`'s `_G.GetItemInfo` / `_G.GetItemCount` calls. Migrate when convenient — Blizzard hasn't deprecated the globals, but the modern API is more future-proof.

### M-5 — `MacroManager.SetMacro` writes when body matches but `pendingUpdates` has the same body

**Location:** `MacroManager.lua:154-156`

```lua
if state and state.lastBody == body and (pendingUpdates[macroName] == nil) then
    return "unchanged"
end
```

If we have a pending write queued from combat, even though the queued body equals the current body, we re-process. Won't cause a bug (still writes the same body), but it's an unnecessary `EditMacro` call.

**Fix:** if `pendingUpdates[macroName]` exists and its `body == body`, drop the pending entry and return "unchanged".

### M-6 — `MacroManager.SetMacro` truncates body at 255 bytes mid-line

```lua
if #body > MACRO_BODY_LIMIT then
    body = body:sub(1, MACRO_BODY_LIMIT)
end
```

If a future spell name (or a localised string) pushes a body over 255 bytes, this produces a malformed macro. English-only project so unlikely in practice, but if it happens the macro silently fails.

**Fix:** if `#body > MACRO_BODY_LIMIT`, fall back to the empty-state body and log an error so the user sees something actionable rather than a truncated `/cast Recupe`.

### M-7 — `PickBestForCategory` for spell entries doesn't fall back to `IsSpellKnown`

**Location:** `Selector.lua:241`

```lua
if spellID and IsPlayerSpell and IsPlayerSpell(spellID) then
    return id
end
```

`IsPlayerSpell` covers class/spec/talent-granted spells but has reportedly missed certain talent-overridden spells in retail. `IsSpellKnown(spellID)` is the older API and sometimes catches the gap.

**Suggestion:** fall back: `IsPlayerSpell(spellID) or (IsSpellKnown and IsSpellKnown(spellID))`. Cheap insurance.

### M-8 — `Ranker.PCT_WEIGHT` may be undersized vs flat-value Midnight food

```lua
local PCT_WEIGHT = 1e4
```

Stated intent: "amplify so Midnight %-based food outranks flat tiers". For pct=7%, contribution is 7e4 = 70,000. A late-game flat-value food restoring 200,000 health would still beat a 7% food on a level-cap character with ~3M health (where 7% = 210k). The pct food is *better* in absolute restore, but the ranker would prefer the flat one.

**Verification needed in-game** with current Midnight values. If real numbers show flat food beating pct food, bump `PCT_WEIGHT` (e.g. 1e5) or change the model: compute pct's notional value as `pct/100 * UnitHealthMax("player")` and compare apples-to-apples.

I cannot verify this without game access. Worth a deliberate test before users notice.

### M-9 — `MacroManager.spellNameFor` has three fallbacks; the first failure is silent

```lua
local function spellNameFor(spellID)
    if not spellID then return nil end
    if C_Spell and C_Spell.GetSpellName then ... end
    if C_Spell and C_Spell.GetSpellInfo then ... end
    if GetSpellInfo then ... end
    return nil
end
```

If all three return nil (genuine unknown spell), the macro body becomes `/run print('KCM: spell %d name unavailable')`. That's correct — but the addon never RETRIES once the spell name resolves later. So if a user respeccs into a build that grants the spell after macro was written, the macro stays in the error state until the next bag change or spec change.

The architecture handles this implicitly (`PLAYER_SPECIALIZATION_CHANGED` triggers recompute), so it's mostly fine. The risk is a spell name that takes longer to hydrate than the Recompute that fires on PEW. Worth filing under "unlikely but observed once = revisit".

**Minor improvement:** if `buildActiveBody` produces the error stub, register a one-shot `LEARNED_SPELL_IN_TAB` listener that triggers a recompute when the spell shows up. Skipping for now is fine.

### M-10 — `KCMItemRow.applyLabelWidth` duplicates layout constants

```lua
local leftOffset = 20 + 4 + 22 + 4 -- ownedTex (OWNED_ICON_SIZE) + gap + itemTex (ICON_SIZE) + gap
```

Hardcoded `20`, `4`, `22`, `4` instead of referencing `OWNED_ICON_SIZE`, `ICON_GAP`, `ICON_SIZE`. If anyone tweaks the constants, this calculation desyncs silently and the label clips wrong.

**Fix:**
```lua
local leftOffset = OWNED_ICON_SIZE + ICON_GAP + ICON_SIZE + ICON_GAP
if widget.qualityTex and widget.qualityTex:IsShown() then
    leftOffset = leftOffset + QUALITY_SIZE + QUALITY_GAP
end
local rightOffset = PICK_SIZE + ICON_GAP
```

### M-11 — `Options.O.RequestRefresh` doesn't reset `_refreshFirstAt` on superseded fires

```lua
C_Timer.After(delay, function()
    if O._refreshToken ~= myToken then return end  -- superseded; no-op
    if O._refreshPending then
        O._refreshFirstAt = nil
        O.Refresh()
    end
end)
```

When superseded, `_refreshFirstAt` stays set. The next `RequestRefresh` reads stale `waited` time and may compute a tiny `delay`, defeating the debounce intent for the next burst. Mild — fires once during a settling phase.

**Fix:** also reset `_refreshFirstAt` whenever the pending state clears (e.g. in `O.Refresh` itself, which already sets `O._refreshPending = false`).

### M-12 — `MacroManager.FlushPending` retries failed writes forever

If a write fails with `error` (e.g. macro quota), it's re-queued and tried again on the next `PLAYER_REGEN_ENABLED`. For permanent failures this burns CPU each regen.

**Fix:** track an attempt count; after N failures, drop the entry and log a one-time error to chat so the user knows the macro isn't being maintained.

### M-13 — `Pipeline.Recompute` isn't tested against the spec-aware-no-spec edge

If the player is at a low level and has no spec, spec-aware categories' `GetEffectivePriority` returns `{}` and `PickBestForCategory` returns `nil`. `MacroManager.SetMacro(macroName, nil, catKey)` builds the empty body. So the macro exists with the empty-state stub. Correct.

But if the user later picks a spec without re-logging (impossible in practice — `PLAYER_SPECIALIZATION_CHANGED` fires), all is well. Documented as a no-op edge.

(No bug, just confirming the pipeline copes.)

---

## §6 Performance Issues

The hot paths are: PEW (login + reload), BAG_UPDATE_DELAYED storms, GET_ITEM_INFO_RECEIVED bursts, Options panel open/refresh.

### P-1 — `Ranker.Score` recomputes `itemFields` for every Score call (covered in H-4)

The single biggest CPU saving is to memoize `(catKey, itemID, ctx-fingerprint) → score` within a single `Pipeline.Recompute`. Trivial change for an estimated 8-10× cut on cold cache and 3-5× on warm cache.

### P-2 — Options.Build is heavy and gets blown away on every Refresh

`Options.O._cache` mitigates rebuild churn but `Refresh` always invalidates. Every panel mutation is followed by `afterMutation → RequestRecompute → Pipeline.Recompute → Options.RequestRefresh → Refresh → invalidate cache → NotifyChange → AceConfigDialog rebuilds`.

This is correct and acceptable for click latency, but it means:
- Sorting a stat-priority dropdown re-runs the full pipeline + rebuilds the panel.
- Pressing ↑ on a row triggers Selector mutation + recompute + UI rebuild.

Profiling would tell whether AceConfigDialog's Flow-layout pass is the dominant cost. If it is, look at incremental updates (mutate only the affected widget instead of full rebuild). Out of scope for 1.0.

### P-3 — `OnItemInfoReceived` fires hundreds of times during first panel open

Documented in code comments. The current optimization (split bag vs non-bag) is correct. Combined with H-3's HasItem fix, this should be near-free.

### P-4 — `BagScanner.Scan` creates a fresh table on every call

Currently called once per recompute (acceptable) and as fallback in `HasItem` (avoid — see H-3). After H-3 lands, this is fine.

If profiling later shows GC pressure from these scans, recycle a single buffer table and clear-then-fill.

### P-5 — `Options.O.Refresh` always re-registers via `NotifyChange` even when the panel is closed

`NotifyChange` is cheap when the registered consumer isn't visible, so this is fine. Just noting it.

---

## §7 Functionality Gaps

### G-1 — No support for "use on someone else" macro modifiers

Spec is intentionally minimal (per `REQUIREMENTS.md`), but a future feature like `/use [@target,help] item:X` for healers handing out healthstones would be a natural extension. Out of scope for 1.0; worth tracking.

### G-2 — No per-character override for account-wide macros

The macros are account-wide by design. A user with one DPS and one tank may want a different combat-pot priority per character. Today they edit the spec-aware bucket, which works for spec-aware categories but not non-spec-aware ones (HP_POT, MP_POT). For 1.0 this is fine; if users ask, the path is "make HP_POT spec-aware" or "add per-character override flag".

### G-3 — No "preview macro body" UI

The user sees the priority list and the picked entry but cannot see the actual macro body that will be written without opening the macro UI. Add a small "current macro body" readout below the drag icon. Low priority.

### G-4 — No conflict resolution for user macros named `KCM_*`

If a user has manually created a macro called `KCM_FOOD` before installing, the addon adopts it (overwrites). Documented behaviour but not surfaced in UI. A one-time "We adopted N existing macros" toast on first run would prevent confusion. Optional.

### G-5 — No keybinding helper

Users have to bind the action-bar slot themselves. A `/kcm bind` helper or an "assign to keybind" UI affordance would close the loop from "addon installed" to "I press a key and eat food". Significant UX win.

### G-6 — No telemetry on what happens when no macro can be picked

When `PickBestForCategory` returns nil, the macro body is the empty-state print. There's no chat log or panel callout that "your FOOD macro is currently empty because no candidate is owned" — the user has to open the panel and notice the priority list. A subtle indicator on the macro drag icon (greyed-out, "no pick" tooltip) would help.

### G-7 — No bulk-import / share

A user who has tuned their priorities can't easily share the config with a guildmate. AceSerializer + a `/kcm export` / `/kcm import` flow would close this. Out of scope for 1.0.

### G-8 — No `/kcm pick <catKey>` slash command

`/kcm dump pick <catKey>` shows the *list*. There's no command to print just the current pick (without all the rank scores). Trivial to add — wraps `Selector.PickBestForCategory`.

---

## §8 Low-Priority / Code-Quality Notes

### L-1 — Defensive nil-check noise

Many call sites have:
```lua
if not (KCM.Selector and KCM.Selector.MoveUp and KCM.Selector.MoveUp(...)) then ...
```

Once the load order is correct (which it is), `KCM.Selector` and `KCM.Selector.MoveUp` are guaranteed at OnEnable time. The defensive checks add ~30 lines of clutter across the codebase. Can be tightened by an init-asserting helper, but not worth a refactor.

### L-2 — `Selector.GetEffectivePriority` is called twice per recompute when the panel is open

Once by `PickBestForCategory` (which calls it), once by `Options.buildCategoryArgs` for the panel render. Consider caching the result on the bucket with a "dirty" flag flipped by every mutator. Worth ~30% saving on panel-open recomputes.

### L-3 — `Categories.LIST` table is mutable from any caller

```lua
KCM.Categories.LIST = { ... }
```

Nothing prevents a downstream module from mutating this in place. Not a real risk in this codebase but worth a `setmetatable(LIST, { __newindex = function() error("LIST is read-only") end })` if you want to lock it.

### L-4 — `O._cache = nil` in `Refresh` happens *before* the `NotifyChange` call

Order is correct (cache must be invalid when AceConfig reads `O.Build`), but worth a comment to explain why these two lines must stay in this order.

### L-5 — `Debug.Print` swallows `string.format` errors silently

```lua
local ok, msg = pcall(string.format, fmt, ...)
if not ok then msg = tostring(fmt) end
```

If a format-string mismatch happens, you see the raw format string instead of the formatted message. Acceptable but worth an "invalid Debug.Print call" prefix so future-you spots the bug fast.

### L-6 — `KCMTitle.SetFontObject` swallows AceConfigDialog calls

Documented (`KCMTitle.lua:31`). Correct behaviour. Just flagging as the kind of thing a code reviewer might rip out without understanding the AceConfigDialog hijack pattern.

### L-7 — `STAT_FOOD`, `CMBT_POT`, and `FLASK` scorers are byte-for-byte identical except for the function name

```lua
STAT_FOOD = function(itemID, ctx) ... return scoreByStatPriority(...) + ilvl + quality * QUALITY_WEIGHT end,
CMBT_POT  = function(itemID, ctx) ... return scoreByStatPriority(...) + ilvl + quality * QUALITY_WEIGHT end,
FLASK     = function(itemID, ctx) ... return scoreByStatPriority(...) + ilvl + quality * QUALITY_WEIGHT end,
```

DRY refactor: a shared `statPriorityScorer` factory. Minor — but if any of the three diverges in the future, you'll either copy-paste again (drift) or finally extract.

### L-8 — `Selector.Unblock` is exposed but never called from the codebase

Defined for completeness; only `AddItem` uses the unblock side effect. Either find a UI use or mark with a comment that it's intentionally part of the public API for future consumers.

### L-9 — `KCMItemRow.RefreshDisplay` uses `_G.GetItemCount` directly instead of `BagScanner.HasItem`

For consistency, route through BagScanner. Currently it shows raw item count which is what we want, but BagScanner could expose a `Count(itemID)` method.

### L-10 — `O.Build` doesn't include the panel title's `desc` field

AceConfigDialog will use `desc` as a tooltip on the registered panel name in some clients. Adding `desc = "Auto-managed account-wide consumable macros."` is a one-line UX win.

### L-11 — Comments in places duplicate what well-named code does

For example `Core.lua:130-138` describes `discoverOne` in nine lines of prose before the function body. Comment-density is healthy across the codebase but this one is long enough to suggest extracting two helpers (one for the "is it in seed" check, one for the "mark discovered" call). Cosmetic.

### L-12 — `Pipeline.RecomputeOne` doesn't expose its result to callers

It's void. The slash-command `/kcm dump pick` re-runs the pipeline because there's no way to ask "what did the last recompute decide for FOOD?". The `macroState` table partially answers this. Minor — currently fine.

---

## §9 Anti-Patterns NOT present (worth calling out)

These are common WoW addon footguns this codebase correctly avoids. Worth calling out so reviewers don't accidentally regress them in future PRs:

1. **No `_G.SomeProtectedFunction = ...` rebindings.** Many addons get clever and re-wrap protected calls; this one doesn't.
2. **No use of `RunMacro` or `RunMacroText`.** Both can taint and have ESC menu cascade issues; the design avoids them.
3. **No reading from the macro frame.** The addon owns its macros by name and never inspects `MacroFrame` state.
4. **No `for k,v in pairs(_G)`** sweeps. Well-scoped lookups only.
5. **No swallowing of nil from `LibStub`.** `embeds.xml` includes everything once; no opportunistic LoadAddOn.
6. **No `ChatFrame_DisplayUsageError` or other deprecated chat APIs.**
7. **No SetCVar calls.** The addon never modifies user CVars.
8. **No persistent timers.** Every `C_Timer.After` is bounded (one-shot debounce).
9. **No taint via re-saving Blizzard tables.** The `StaticPopupDialogs` comment in SlashCommands shows the author understands the risk.
10. **No "fix it later" hardcoded paths inside frame XML or template strings.** The widget files use texture paths and atlas names, not template inheritance.

---

## §10 Recommended Roadmap

If I were sequencing the next sprint:

**Sprint 1 — ship-blockers (1 day):**
- B-1, B-2 (definite bugs).
- H-1 (pcall guard around per-category recompute).
- H-3 (drop the BagScanner.HasItem fallback scan).
- H-6 (delete dead constant).

**Sprint 2 — performance & polish (2-3 days):**
- H-4 (memoize Ranker.Score per recompute).
- M-2, M-5 (mutator return semantics & macro write de-dup).
- M-10 (KCMItemRow constants).

**Sprint 3 — nice-to-haves (1-2 days):**
- M-1 (discovered-set GC).
- G-3 (preview macro body in panel).
- G-8 (`/kcm pick` slash).
- L-7 (DRY Ranker scorers).

**Sprint 4 — investigate (open-ended):**
- M-8 (`PCT_WEIGHT` in-game verification).
- M-7 (`IsSpellKnown` fallback).
- G-5 (keybinding helper).
- G-7 (export/import).

---

## §11 Test Strategy Recommendation

The codebase has zero automated tests. For an addon of this complexity, a small WoW-stub-based unit test harness on the **pure** modules would catch a meaningful fraction of regressions:

- **Selector.BuildCandidateSet** — given seed/added/discovered/blocked, returns the expected set in the expected order.
- **Selector.mergePins** — pin ordering edge cases (collisions, overshoot, missing items).
- **Ranker.Score / SortCandidates / Explain** — golden-output fixtures per category; one fixture per scoring rule.
- **Classifier.MatchAny** — a corpus of (itemID, mock-tooltip, expected-categories) tuples, including each Midnight subtype rename.
- **TooltipCache.parseLines** — golden-output fixtures for each pattern (NBSP, `|4...;` escapes, conjured, feast, HOT pots, pct-combined, stat tokens).
- **MacroManager.BuildBody** — output exactness for items vs spells vs empty-state.

These can run outside WoW with a few stubbed globals (`GetItemInfo`, `IsPlayerSpell`, `C_TooltipInfo.GetItemByID`, `C_Item.GetItemCount`, etc.). The pure modules are deliberately structured to allow this; the project just hasn't pulled the trigger yet.

`MacroManager`, `BagScanner`, `Options` are all harder to stub but also less likely to regress silently — the integration test for them is "load the addon and try it".

---

## §12 File-by-File Notes (quick reference)

| File | LOC | Notes |
|---|---|---|
| `Core.lua` | 282 | Solid. Apply H-1, M-3. |
| `Debug.lua` | 32 | Fine. Optional L-5. |
| `BagScanner.lua` | 69 | Apply B-1, H-3. |
| `Classifier.lua` | 165 | Solid. No changes needed. |
| `TooltipCache.lua` | 371 | Solid. Heavy parsing — well documented. |
| `SpecHelper.lua` | 105 | Solid. |
| `Ranker.lua` | 411 | Apply H-4, L-7, optional M-8. |
| `Selector.lua` | 376 | Apply M-2, H-2 (cross-file), L-2 (cache). |
| `MacroManager.lua` | 226 | Apply B-2 (cross-file), H-6, M-5, M-6, M-9, M-12. |
| `Options.lua` | 992 | Largest file by far. Apply M-11. Layout consts in widget files (M-10) overlap. |
| `SlashCommands.lua` | 392 | Solid. Optional G-8. |
| `KCMItemRow.lua` | 300 | Apply M-10. Optional L-9. |
| `KCMIconButton.lua` | 145 | Solid. |
| `KCMScoreButton.lua` | 115 | Solid. |
| `KCMHeading.lua` | 72 | Solid. |
| `KCMTitle.lua` | 58 | Solid. |
| `KCMMacroDragIcon.lua` | 152 | Apply B-2. |
| `defaults/*.lua` | n/a | Data-only. Apply normal patch-time refresh per `docs/REFRESH_ITEMS.md`. |

---

## §13 Closing

This is a 1.0.0 I would happily run on my own client. The bones are right; the only changes I would gate the release on are B-1 and B-2. Everything else is a roadmap, not a release blocker.

The documentation discipline (CLAUDE.md, ARCHITECTURE.md, the docs/ directory) is exceptional for a hobby-scale project and pays for itself many times over in maintenance velocity. Keep it.

— *Review complete. No code changes made; this document is read-only feedback.*
