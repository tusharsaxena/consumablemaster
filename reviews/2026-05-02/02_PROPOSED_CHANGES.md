# Proposed Changes — Ka0s Consumable Master

**Date:** 2026-05-02
**Companion to:** `01_FINDINGS.md` (this file maps each finding to a concrete change).

---

## High-Level Design (HLD)

### Theme A: Reduce dead surface area

**Problem.** Eight public functions across `BagScanner`, `MacroManager`, `TooltipCache`, and `settings/Panel.lua` have zero callers in the addon. They're named in `docs/module-map.md` as "public API" but nothing exercises them. Every dead export is a future maintenance trap (you can't safely refactor without grepping cross-repo, and even that misses reflection).

**Approach.** Delete the unused exports from source and from `docs/module-map.md`. Resist the temptation to move them under a `_debug` namespace "in case we need them" — they can be retrieved from git if a future change wants them.

**Alternatives considered.**

- *Promote the exports by wiring them into a debug surface (`/cm dump pending`, `/cm dump tooltipstats`).* Rejected: extends the API for callers that don't exist, locking us into more shape than we need.
- *Add a `_private` prefix and keep them.* Rejected: the convention isn't followed elsewhere; new convention costs more than the cleanup.

**Trade-off.** If any of the dead exports turns out to be intentionally provided for third-party consumers (e.g. a sister addon), removal breaks them. Risk is theoretically non-zero; the addon doesn't advertise itself as a library, so risk in practice is near-zero.

**Findings covered:** F-002.

### Theme B: Tighten the single-write-path convention

**Problem.** `Helpers.Set` exists and `Helpers.FireConfigChanged` is forwarded an unused `section` parameter. Callers that *aren't* schema-driven (pin reorder, AIO toggle, stat priority, reset) write directly to `db.profile.*`. The convention either matters or it doesn't.

**Approach (recommended).** Drop the convention. Delete `Helpers.FireConfigChanged`, change `Helpers.Set` to a 2-arg `Set(path, value)`, and document the simpler reality: schema-driven scalars route through `Helpers.Set` as a thin wrapper for path resolution; everything else writes the bucket fields directly. Add a small comment at the top of `Selector.lua`'s mutator section noting that mutators are the canonical write path for bucket fields.

**Alternatives considered.**

- *Wire `FireConfigChanged` to a CallbackHandler-1.0 dispatcher.* Rejected for now: there are no subscribers and the addon doesn't expose external integration points. Add the plumbing when a real consumer arrives.
- *Migrate every direct write through `Helpers.Set`.* Rejected: bucket-shaped data (pins, enabled, orderInCombat) doesn't fit the flat-path schema; forcing it would balloon the schema or invent non-schema setters that defeat the purpose.

**Trade-off.** Removing the no-op stub deletes a documented extension point. If an external integration arrives in the next quarter, we'd add it back. Net: simpler today, identical future cost.

**Findings covered:** F-007, F-014.

### Theme C: Consolidate panel registration to a single bootstrap path

**Problem.** `Settings.RegisterAddOnCategory` runs from two places: `OnInitialize` (via `KCM.Options.Register()`) and the `bootstrap` event listener for `PLAYER_LOGIN` / `ADDON_LOADED`. Idempotency via `if KCM.Settings.main then return end` keeps it correct today, but the dual-path design hides which path actually wins on a typical login.

**Approach.** Remove the `OnInitialize` call. Keep the bootstrap listener as the sole path. AceAddon `OnInitialize` runs *before* `PLAYER_LOGIN`, so the `Settings.Register*` API may not be ready in all client versions; depending on the listener is more robust.

**Alternatives considered.**

- *Keep both paths, add a comment.* Rejected: this is what's there today; a comment doesn't reduce surface.
- *Move the bootstrap to use AceEvent on `KCM` itself.* Plausible improvement, but mixes Ace-mixin events with global panel state. Defer.

**Trade-off.** A trivial first-render delay on `/cm config` invoked between `OnInitialize` and `PLAYER_LOGIN` (extremely narrow window). In exchange, one init path instead of two.

**Findings covered:** F-006.

### Theme D: Spec-aware UI state should follow live spec changes

**Problem.** `_viewedSpec` is sticky. After respec, the panel keeps showing the old spec's data; the user must manually pick the new spec from the dropdown. `Pipeline.RequestRecompute("spec_changed")` already drives the *macro* path — the panel doesn't get the same treatment.

**Approach.** When `OnSpecChanged` fires and the *previous* `_viewedSpec` matched the previous current spec (i.e. the user hadn't manually picked another spec), re-track to the new current spec. If the user has manually picked a spec, leave it alone — that's intentional cross-spec editing.

**Alternatives considered.**

- *Always retrack to current spec on respec.* Rejected: breaks the "edit other specs while playing this one" use case.
- *Add a "Track current spec" checkbox.* Plausible, but heavier UX than the problem warrants right now. Mark as future work.

**Trade-off.** State machine grows by one bit (`_viewedSpecIsTracking`). Worth the ergonomic win.

**Findings covered:** F-004.

### Theme E: Off-state UX coherence

**Problem.** When master enable is off, `Pipeline.Recompute` early-returns *before* `Options.RequestRefresh()` — so panel rebuild never fires for events that happen during off-state. Open the panel while off, see "[Loading]" forever for any item whose info hasn't hydrated.

**Approach.** Move the `Options.RequestRefresh()` call above the master-enable gate. The macro write path stays gated; the panel still re-renders for item-info hydration, which is what the user expects when looking at the priority list while debugging.

**Alternatives considered.**

- *Disable the priority list rendering entirely while off.* Rejected: the user opens the panel *to* check picks while off; killing the data view isn't helpful.

**Trade-off.** Negligible perf cost (the debounced refresh is cheap when nothing changed).

**Findings covered:** F-003.

### Theme F: CLI/UX clarity touches

**Problem.** Several CLI surfaces are technically correct but read confusingly: combat warnings followed by synchronous recomputes, `priority reset` not announcing what it preserves, `set` returning success-shaped feedback even when the write didn't land.

**Approach.** Tighten the messages, check the `Helpers.Set*` return value before printing the confirmation, and surface the "discovered preserved" detail in `priority reset`'s confirmation.

**Findings covered:** F-001, F-013, F-022.

### Theme G: Small-cost cleanups

**Problem.** Dead state (`KCM._inCombat`), `Classifier.MatchAny` walking composites, secondary-stat compaction de-duping, redundant work in `Ranker.Explain` / `KCMItemRow.craftingQualityAtlas`, the `Debug.Toggle` `next` shadow.

**Approach.** Each is a one-spot fix; group them in one milestone to amortize the per-task overhead.

**Findings covered:** F-005, F-008, F-009, F-010, F-012, F-015, F-016, F-017, F-019, F-020, F-021.

---

## Low-Level Design (LLD)

Each entry below names file/function, sketches before → after, and links the finding IDs it implements.

### LLD-1 — Delete dead exports (F-002)

**Files:** `BagScanner.lua`, `MacroManager.lua`, `TooltipCache.lua`, `settings/Panel.lua`, `docs/module-map.md`.

Functions to remove:

| Module | Function | Reason |
|--------|----------|--------|
| `KCM.BagScanner` | `GetAllItemIDs` | unused |
| `KCM.MacroManager` | `HasPending`, `PendingCount`, `IsAdopted` | unused |
| `KCM.TooltipCache` | `IsPending`, `PendingIDs`, `Stats` | unused |
| `KCM.Settings.Helpers` | `SchemaForPanel`, `MakeCheckbox` | unused |

Verify with `grep -rn 'X' /mnt/d/.../*.lua /mnt/d/.../settings/*.lua /mnt/d/.../defaults/*.lua` before each delete.

**Risk:** API removal — but no consumer exists in repo. Remote consumers are theoretical.

**Doc impact:** prune the rows from `docs/module-map.md`'s API listings.

### LLD-2 — Simplify `Helpers.Set` to 2-arg + drop FireConfigChanged (F-007, F-014)

**File:** `settings/Panel.lua`.

Before:

```lua
function Helpers.Set(path, section, value) ... Helpers.FireConfigChanged(section) ... end
function Helpers.SetAndRefresh(path, value)
    if not Helpers.Set(def.path, def.section, value) then return false end
    fireOnChange(def, value)
    Helpers.RefreshAllPanels()
end
```

After:

```lua
function Helpers.Set(path, value)
    local parent, key = Helpers.Resolve(path)
    if not parent then return false end
    parent[key] = value
    return true
end
function Helpers.SetAndRefresh(path, value)
    local def = Helpers.FindSchema(path)
    if not def then return false end
    if not Helpers.Set(def.path, value) then return false end
    fireOnChange(def, value)
    Helpers.RefreshAllPanels()
    return true
end
```

Drop `Helpers.FireConfigChanged`. Update doc index.

**Risk:** if any external caller passes 3 args to `Helpers.Set` they'll silently see `value = nil`. Compatibility shim: keep `Helpers.Set(path, section, value)` as a 2-or-3-arg variadic for one version, log a deprecation warning. Preferred: cut it cleanly — every caller in the repo gets updated in this same change.

### LLD-3 — Single panel-registration path (F-006)

**File:** `Core.lua`, `settings/Panel.lua`.

Before (Core.lua:67-69):

```lua
if KCM.Options and KCM.Options.Register then
    KCM.Options.Register()
end
```

After: remove this block. The bootstrap at `settings/Panel.lua:823-832` already runs on `PLAYER_LOGIN` / `ADDON_LOADED` and is idempotent.

Update `Helpers.SetRenderer` users that depended on `KCM.Settings.main` being non-nil at `OnInitialize` time (none today; verify with grep).

**Risk:** trace-time test that `/cm config` invoked between `OnInitialize` and `PLAYER_LOGIN` (an extremely narrow window — basically impossible from Lua, since chat slash dispatch only runs after `PLAYER_ENTERING_WORLD`) still works.

### LLD-4 — Spec change tracks `_viewedSpec` if user hadn't pinned (F-004)

**File:** `Core.lua` and `settings/StatPriority.lua`.

Add a flag to record whether `_viewedSpec` was last set by the user manually or by auto-resolve. On `OnSpecChanged`, if the flag says "auto", retrack:

```lua
-- settings/StatPriority.lua
O._viewedSpecAuto = O._viewedSpecAuto == nil and true or O._viewedSpecAuto
function resolveViewedSpec()
    if O._viewedSpec and not O._viewedSpecAuto then return O._viewedSpec end
    local cur = currentSpecKey()
    if cur then
        O._viewedSpec = cur
        O._viewedSpecAuto = true
    end
    return O._viewedSpec
end

-- on dropdown OnValueChanged:
O._viewedSpec = v
O._viewedSpecAuto = false
H.RefreshAllPanels()
```

In `Core:OnSpecChanged`, after `RequestRecompute`, also retrack the panel viewed spec when `_viewedSpecAuto` is true:

```lua
function KCM:OnSpecChanged()
    KCM.Pipeline.RequestRecompute("spec_changed")
    if KCM.Options and KCM.Options._viewedSpecAuto and KCM.SpecHelper then
        local _, _, key = KCM.SpecHelper.GetCurrent()
        if key then KCM.Options._viewedSpec = key end
    end
end
```

Then refresh panels (debounced — `Pipeline.Recompute` already calls `Options.RequestRefresh` on the recompute that follows).

**Risk:** the new flag is in `O` (KCM.Options) which is a UI/state surface; document its semantics in `settings/StatPriority.lua` header.

### LLD-5 — Panel refresh fires regardless of master enable (F-003)

**File:** `Core.lua`, `Pipeline.Recompute`.

Before: master-enable gate at line 124-129 returns *before* `Options.RequestRefresh`.

After: gate the macro write loop only; always call `Options.RequestRefresh()` at the end:

```lua
function P.Recompute(reason)
    if not KCM.Categories or not KCM.Categories.LIST then return end
    local enabled = not (KCM.db and KCM.db.profile and KCM.db.profile.enabled == false)
    if enabled then
        local scoreCache = { fields = {} }
        for _, cat in ipairs(KCM.Categories.LIST) do
            local ok, err = pcall(P.RecomputeOne, cat.key, scoreCache, reason)
            if not ok and KCM.Debug and KCM.Debug.Print then
                KCM.Debug.Print("Recompute %s failed: %s", cat.key, tostring(err))
            end
        end
    elseif KCM.Debug and KCM.Debug.Print then
        KCM.Debug.Print("Pipeline.Recompute skipped (disabled): reason=%s", tostring(reason))
    end
    if KCM.Options and KCM.Options.RequestRefresh then
        KCM.Options.RequestRefresh()
    elseif KCM.Options and KCM.Options.Refresh then
        KCM.Options.Refresh()
    end
end
```

**Risk:** the panel renderer reads live state via `Selector` / `BagScanner`; running it while macros are off doesn't write anything, so no taint risk.

### LLD-6 — Surface "discovered preserved" in CLI reset confirmation (F-013)

**File:** `SlashCommands.lua:796-797`.

Before:

```lua
say(("reset %s%s — added/blocked/pins cleared.")
```

After:

```lua
say(("reset %s%s — added/blocked/pins cleared (discovered items preserved).")
```

### LLD-7 — Combat-warning wording on `/cm resync` and `/cm rewritemacros` (F-022)

**File:** `SlashCommands.lua:1158-1184`.

Before:

```lua
say("in combat — macro writes deferred until regen.")
```

After:

```lua
say("in combat — picks computed now; macro writes will apply when combat ends.")
```

(Same change in both commands.)

### LLD-8 — Check `Helpers.SetAndRefresh` return before printing confirmation (F-001)

**File:** `SlashCommands.lua:603-604`.

Before:

```lua
H.SetAndRefresh(def.path, newValue)
say(("%s = %s"):format(def.path, formatValue(def, H.Get(def.path))))
```

After:

```lua
if not H.SetAndRefresh(def.path, newValue) then
    say(("Could not set %s — DB not ready?"):format(def.path))
    return
end
say(("%s = %s"):format(def.path, formatValue(def, H.Get(def.path))))
```

### LLD-9 — Compaction with dedupe + gap-aware (F-005)

**File:** `settings/StatPriority.lua:116-119`.

Before:

```lua
local compacted = {}
for _, s in ipairs(cur.secondary) do
    if s and s ~= "" then table.insert(compacted, s) end
end
```

After:

```lua
local compacted, seen = {}, {}
for _, s in ipairs(cur.secondary) do
    if s and s ~= "" and not seen[s] then
        seen[s] = true
        table.insert(compacted, s)
    end
end
```

Same change in `SlashCommands.lua:statSecondary`.

**UX touch:** when the user picks a duplicate, the dropdown should refuse the change with a one-line chat warning. That's a deeper UX change — punt to follow-up.

### LLD-10 — `Classifier.MatchAny` skips composites + protect `C.Match` (F-008)

**File:** `Classifier.lua:153`.

Before:

```lua
for _, cat in ipairs(KCM.Categories.LIST) do
    if C.Match(cat.key, itemID) then ...
```

After:

```lua
for _, cat in ipairs(KCM.Categories.LIST) do
    if not cat.composite and C.Match(cat.key, itemID) then ...
```

### LLD-11 — Cache `bestImmediateAmount` per recompute (F-009)

**File:** `Ranker.lua:282-290`.

Before:

```lua
function R.BuildContext(catKey, itemIDs, existing, scoreCache)
    local ctx = existing or {}
    if catKey == "HP_POT" then
        ctx.bestImmediateAmount = bestImmediateAmount("HP", itemIDs, scoreCache)
    elseif catKey == "MP_POT" then
        ctx.bestImmediateAmount = bestImmediateAmount("MP", itemIDs, scoreCache)
    end
    return ctx
end
```

After:

```lua
function R.BuildContext(catKey, itemIDs, existing, scoreCache)
    local ctx = existing or {}
    if catKey == "HP_POT" or catKey == "MP_POT" then
        local kind = (catKey == "HP_POT") and "HP" or "MP"
        if scoreCache then
            scoreCache.bestImmediate = scoreCache.bestImmediate or {}
            local cached = scoreCache.bestImmediate[catKey]
            if cached == nil then
                cached = bestImmediateAmount(kind, itemIDs, scoreCache)
                scoreCache.bestImmediate[catKey] = cached
            end
            ctx.bestImmediateAmount = cached
        else
            ctx.bestImmediateAmount = bestImmediateAmount(kind, itemIDs, scoreCache)
        end
    end
    return ctx
end
```

### LLD-12 — Drop `specLabelCache[v] = nil` on dropdown change (F-010)

**File:** `settings/StatPriority.lua:193`.

Either drop the line and the comment, or move the cache invalidation to a real trigger (login event in another file). Cleanest: drop. The comment claims protection against an event the cache survives anyway (a fresh login resets the file-local table).

### LLD-13 — Remove `KCM._inCombat` (F-012)

**Files:** `Core.lua:301-303` (write), nowhere reads it.

Delete the `_inCombat = true / false` writes. Keep `OnRegenDisabled` / `OnRegenEnabled` handlers — `OnRegenEnabled` still drives `MacroManager.FlushPending`.

After:

```lua
function KCM:OnRegenDisabled() end
function KCM:OnRegenEnabled()
    if KCM.MacroManager and KCM.MacroManager.FlushPending then
        ...
    end
end
```

Or unregister `PLAYER_REGEN_DISABLED` entirely (no handler needed). Slightly cleaner.

### LLD-14 — `Debug.Toggle` rename `next` to `nextValue` (F-015)

**File:** `Debug.lua:17`.

Cosmetic. One line change.

### LLD-15 — `applyLabelWidth` derive offsets from constants (F-019)

**File:** `KCMItemRow.lua:108-115`.

Replace hardcoded `20 + 4 + 22 + 4` with `OWNED_ICON_SIZE + ICON_GAP + ICON_SIZE + ICON_GAP`, and `14 + 1` with `QUALITY_SIZE + QUALITY_GAP`, and `22 + 4` with `PICK_SIZE + ICON_GAP`. Constants already exist at the top of the file.

### LLD-16 — Annotate `KCM.ResetAllToDefaults`'s direct `Recompute` call (F-011)

**File:** `Core.lua:262-278`.

Add a comment explaining the deliberate use of `Pipeline.Recompute` (not `RequestRecompute`) and the fact that the safety relies on `MacroManager` being the only protected-API caller. Optionally swap to `RequestRecompute` if a tick of latency before the panel refresh is acceptable; the user-facing perception is that `/cm reset` already takes a frame.

Recommendation: keep `Recompute` (immediate is the right UX), strengthen the comment.

### LLD-17 — `formatNumber` micro-perf (F-017)

**File:** `settings/Category.lua:78-85`.

Replace the reverse + gsub + reverse pattern with a single forward gsub:

```lua
local function formatNumber(n)
    if type(n) ~= "number" then return tostring(n) end
    local sign = n < 0 and "-" or ""
    local abs = math.abs(n)
    local body = (abs == math.floor(abs)) and ("%d"):format(abs) or ("%.1f"):format(abs)
    -- Insert thousands separators every three digits from the decimal point.
    local int, frac = body:match("^(%d+)(.*)$")
    int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return sign .. int .. (frac or "")
end
```

Alternatively, use Lua's `tostring` and let the user accept unseparated digits — score numbers fit in 9-10 digits and aren't usually large enough to need separators.

### LLD-18 — `craftingQualityAtlas` reuses the per-render itemInfo cache (F-020)

**File:** `KCMItemRow.lua:126-142`.

Pass an `itemInfo` table down or stash on `self` between calls. Or: skip — RefreshDisplay already runs once per row per panel render, so the cost is bounded.

Recommendation: skip unless profiling shows real cost.

### LLD-19 — `dropdownAllowed` accepts numeric values (F-021)

**File:** `SlashCommands.lua:556-560` and `applyFromText`.

If `def.type == "number"` and `def.values` is supplied, compare numerically:

```lua
local function dropdownAllowed(def)
    local values = type(def.values) == "function" and def.values() or def.values or {}
    local out = {}
    for i, item in ipairs(values) do out[i] = item.value end
    return out
end
```

Then in `applyFromText`'s number branch, also check `out` membership numerically.

Latent fix; ship only when a numeric dropdown row is added.

---

## Roll-up: Findings → LLD mapping

| Finding | LLD |
|---------|-----|
| F-001 | LLD-8 |
| F-002 | LLD-1 |
| F-003 | LLD-5 |
| F-004 | LLD-4 |
| F-005 | LLD-9 |
| F-006 | LLD-3 |
| F-007 | LLD-2 |
| F-008 | LLD-10 |
| F-009 | LLD-11 |
| F-010 | LLD-12 |
| F-011 | LLD-16 |
| F-012 | LLD-13 |
| F-013 | LLD-6 |
| F-014 | LLD-2 |
| F-015 | LLD-14 |
| F-016 | (comment touch-ups; absorb into other tasks) |
| F-017 | LLD-17 |
| F-018 | (no change; readability nit) |
| F-019 | LLD-15 |
| F-020 | LLD-18 |
| F-021 | LLD-19 |
| F-022 | LLD-7 |
| F-023 | (verify only) |
