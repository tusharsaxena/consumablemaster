# MacroManager

The only module that calls Blizzard's protected macro APIs (`CreateMacro` / `EditMacro`). Everything else stays pure so the pipeline can run in combat without taint risk.

## Public surface

```lua
KCM.MacroManager.SetMacro(macroName, id, catKey)         -> "created" | "edited" | "unchanged" | "deferred" | "error"
KCM.MacroManager.SetCompositeMacro(cat, scoreCache)      -> same result codes
KCM.MacroManager.FlushPending()                          -> applied:int    -- on PLAYER_REGEN_ENABLED
KCM.MacroManager.BuildBody(catKey, id)                   -> string         -- pure helper
KCM.MacroManager.BuildCompositeBody(cat, pickFor)        -> string|nil     -- pure helper, exposed for /cm dump pick
KCM.MacroManager.InvalidateState()                       -- clears macroState + pendingUpdates + oversize warnings
```

## Body builders

### Single-pick body

| Pick kind | Body |
|-----------|------|
| Item (positive id) | `#showtooltip\n/use item:<id>` |
| Spell (negative id) | `#showtooltip\n/cast <Spell Name>` |
| `nil` (ownership miss) | category's `emptyText`, no `#showtooltip` |

The `item:<id>` form lets `/use` fire even if the item name is localized differently on the client. `/cast` requires the localized spell name (English here); `spellNameFor(spellID)` walks `C_Spell.GetSpellName` → `C_Spell.GetSpellInfo` → legacy `GetSpellInfo` for resilience.

### Empty-state body

Uses `/run print('|cff00ffff[CM]|r no <category> in bags')` — a `/run` line so clicking the macro still does *something* (a chat message) when the player has no qualifying item, rather than silently failing.

**Why no `#showtooltip` here:** with `#showtooltip` present and the stored icon set to `?` (`DYNAMIC_ICON`, used for active macros), WoW tries to resolve the icon from the first `/use` or `/cast` — but the empty body is a plain `/run` line, so the action bar would fall back to the `?` icon instead of the cooking-pot fallback. Dropping `#showtooltip` pairs with `iconFor(nil)` → `DEFAULT_ICON` so the cooking pot renders for empties.

## Composite body assembly

`SetCompositeMacro` resolves picks via `Selector.PickBestForCategory(refKey, nil, scoreCache)` for each enabled sub-cat in the configured order. The body has two halves:

### In-combat half

Every enabled in-combat sub-cat with a resolvable pick is folded into one `/castsequence` line:

```
/castsequence [combat] reset=combat <token>, <token>, ...
```

Tokens: items become `item:<id>`; spells use the localized spell name. `/castsequence` walks the list across clicks and rewinds to step 1 when the player leaves combat (`reset=combat`).

### Out-of-combat half

One `/use [nocombat]` (or `/cast [nocombat]`) line per enabled out-of-combat sub-cat with a resolvable pick:

```
/use [nocombat] item:<id>
/cast [nocombat] <Spell Name>
```

Multiple lines act as a fallback chain: `#showtooltip` resolves to the first usable line; subsequent lines no-op against the GCD if a higher-priority line already fired.

### Empty-step handling

Sub-categories with no current pick (item not in bags, spell not learned) are dropped from the body so `/castsequence` doesn't jam on an unusable token.

### Asymmetric-empty fallback

If exactly one combat-state side ends up empty but the other has picks, an extra `/run` line emits a chat-print fallback for the empty side:

```
/run if not InCombatLockdown() then print("|cff00ffff[CM]|r no AIO Health option out of combat") end
```

The Lua-conditional gate is necessary because `/run` doesn't accept `[combat]` / `[nocombat]` macro conditionals — those are evaluated by the secure-macro parser, which only attaches them to `/use` / `/cast` / `/castsequence` / `/click` / `/target` / etc.

If both sides end up empty, the body falls through to `buildEmptyBody` and the cooking-pot icon renders.

## Action-bar icon convention

Two stored-icon constants in `MacroManager.lua`:

```lua
local DEFAULT_ICON = 7704166   -- cooking pot
local DYNAMIC_ICON = 134400    -- the `?` fileID
```

`iconFor(itemID)` returns `DYNAMIC_ICON` when the body is active (`itemID ~= nil`) and `DEFAULT_ICON` when the body is empty.

### The `?` sentinel rule

WoW (and action-bar addons that render via `GetActionTexture` — ElvUI, Bartender, etc.) only let `#showtooltip` drive the action-bar button's icon when the macro's stored icon is the `?` file (fileID `134400`). Any other stored icon overrides `#showtooltip` on the action bar.

So:

- **Active body** stores `DYNAMIC_ICON`. Body keeps `#showtooltip` and either `/use item:N` or `/cast <Spell>`. Action bar adopts the picked item's / spell's icon.
- **Empty body** stores `DEFAULT_ICON` (cooking pot). Body has no `#showtooltip`. The static cooking pot renders directly.

**Never store `DEFAULT_ICON` on an active body** — you'll see the cooking pot on the action bar instead of the picked flask.

The Options panel's `KCMMacroDragIcon` widget is exempt — it resolves to `GetItemIcon(lastItemID)` / `C_Spell.GetSpellTexture(spellID)` directly, since the `?` sentinel looks meaningless on a static UI widget.

## Internal flow per call

```
SetMacro(name, id, catKey):
    body = BuildBody(catKey, id)
    if #body > 255:
        body = empty-state stub
        emit one-shot oversize warning to chat + Debug.Print
        effectiveItemID = nil       -- so iconFor returns DEFAULT_ICON
    icon = iconFor(effectiveItemID)
    state   = macroState[name]
    pending = pendingUpdates[name]
    if state.lastBody == body and state.lastIcon == icon and (pending == nil or pending.body == body):
        clear pendingUpdates[name] if redundant
        return "unchanged"
    if InCombatLockdown():
        pendingUpdates[name] = { body, itemID, catKey, attempts = pending.attempts or 0 }
        return "deferred"
    result = doEdit(name, icon, body, catKey)   -- CreateMacro if new, else EditMacro
    persist macroState[name] = { lastItemID = id, lastBody = body, lastIcon = icon, lastCat = catKey }
    pendingUpdates[name] = nil
    return result
```

`SetCompositeMacro` follows the same ladder, with the body coming from `buildCompositeBody(cat, pickFor)` instead of `BuildBody`. Pending entries for composites carry `entry.cat = cat` so `FlushPending` can dispatch.

## Combat deferral

`pendingUpdates[macroName] = { body, itemID, catKey, attempts }` for single picks; `{ body, itemID=nil, catKey, cat, attempts }` for composites.

**Last write wins.** If the body changes again before `PLAYER_REGEN_ENABLED`, only the final version is applied — that's the documented goal of coalescing bag flurries into a single macro write. The `attempts` counter is preserved across re-queues during a single combat window so a bad `EditMacro` doesn't reset its retry counter on every new pipeline run before regen fires.

## Flush retry

`FlushPending` runs on `PLAYER_REGEN_ENABLED`:

```
FlushPending():
    for name, entry in pairs(pendingUpdates):
        if entry.cat and entry.cat.composite:
            ok, result = pcall(SetCompositeMacro, entry.cat, nil)
        else:
            ok, result = pcall(SetMacro, name, entry.itemID, entry.catKey)
        if ok and result not in {"error", "deferred"}:
            applied += 1
        elif result == "deferred":
            still[name] = entry            -- combat re-entered; preserve as-is
        else:
            entry.attempts += 1
            if entry.attempts >= 3:
                print one-time chat warning "[CM] gave up on <name>"
            else:
                still[name] = entry
    pendingUpdates = still
    return applied
```

Bounded to **3 attempts** before giving up, with a one-time chat notice. Prevents an infinite re-queue loop across regen cycles when something — usually a Blizzard bug or another addon tainting the macro APIs — persistently rejects the write.

## Edge cases and error handling

| Edge case | Handling |
|-----------|----------|
| Macro pool full (120 account-wide already exist) | `CreateMacro` returns 0; `doEdit` returns `"error"` with `"account macro quota full (120)"`. Existing `KCM_*` macros continue. |
| `EditMacro` returns 0 | `doEdit` returns `"error"`. `FlushPending` increments `attempts`; bounded retry (3) before give-up. |
| User adds a non-existent ID | The Add-by-ID `onSubmit` handler in `settings/Category.lua` rejects it (item: `C_Item.GetItemInfoInstant`; spell: `C_Spell.GetSpellName`); `Selector.AddItem` is never called with an invalid id. |
| Item classifies into no category | Allowed — user knows best. Enters candidate set with score=0 from `Ranker`; sorted last. |
| Spec-aware category without a current spec | `GetEffectivePriority` returns `{}`; `PickBestForCategory` returns nil; empty-state body written. No-op edge. |
| Tooltip never loads | `TooltipCache.Get` returns the `pending=true` marker; Ranker scores 0 until `GET_ITEM_INFO_RECEIVED` fires the retry. |
| Body > 255 bytes | Falls back to empty-state stub; emits one-shot chat warning + `Debug.Print` naming the category. Silent truncation is gone — it corrupted `/use` lines in v1.0.x. |
| Spell name unresolvable | `buildActiveBody` writes `"#showtooltip\n/run print('|cff00ffff[CM]|r spell %d name unavailable')"`. `PLAYER_SPECIALIZATION_CHANGED` / `BAG_UPDATE_DELAYED` / `GET_ITEM_INFO_RECEIVED` / `LEARNED_SPELL_IN_SKILL_LINE` will retrigger recompute when state changes. |
| Locked items in bags (mailing / splitting / equipping) | `BagScanner.Scan` counts them — lock is transient ownership, not absence. Macro does not flap. |
| Drag-icon tooltip for spell pick | `KCMMacroDragIcon` reads `macroState.lastItemID` and forks on `KCM.ID.IsSpell` to call `SetSpellByID` vs `SetItemByID`. |
| User renames a `KCM_*` macro | Next recompute can't find the name; addon creates a fresh one in a free account-wide slot. The renamed macro is left alone — the addon never deletes. |
| `/cm resync` during combat | Prints a notice that macro writes are deferred until regen; the rescan + recompute still run (pure modules are combat-safe). |

## InvalidateState — `/cm rewritemacros`

Clears `macroState` + `pendingUpdates` + the oversized-warning gate. The next pipeline run re-issues every macro unconditionally because the early-out fingerprints are gone. Used by `/cm rewritemacros` (and the Force rewrite macros button in General settings) when an action-bar icon looks stale and you want a fresh `EditMacro` call even though the body hasn't changed.
