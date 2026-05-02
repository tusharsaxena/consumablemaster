# Midnight quirks — tooltip parsing, subtype renames, secret values

Catalog of WoW Midnight (Interface 12.0.x) behaviors that bite the addon. When something breaks at patch time, this is where to look first.

## Subtype renames

Blizzard renamed several consumable subTypes in Midnight. The underlying `classID` / `subClassID` are unchanged but `GetItemInfoInstant` returns the display string, which is what the addon classifies on.

| Old | New |
|-----|-----|
| `"Potion"` | `"Potions"` |
| `"Flask"` / `"Phial"` | `"Flasks & Phials"` |
| `"Food & Drink"` | unchanged |

The matcher strings live as `ST_*` constants at the top of `Classifier.lua`:

```lua
local ST_POTION      = "Potions"
local ST_FOOD        = "Food & Drink"
local ST_FLASK_PHIAL = "Flasks & Phials"
```

If another rename lands, edit these constants. `Classifier.MatchAny(id)` returns `{ catKeys }`, so a single item can classify into multiple categories (e.g. "Refreshing Serum" for both `HP_POT` and `MP_POT`).

## Tooltip parsing — grammar escapes and NBSP

`C_TooltipInfo.GetItemByID` returns **raw template strings**, not the rendered text WoW shows in-game. Two specific issues:

- **`|4singular:plural;` grammar escapes.** Strings like `"for 1 |4hour:hrs;"` are not pre-substituted. `TooltipCache.normalizeTooltipText` strips them before the regex pass. Don't bypass `normalizeTooltipText`.
- **Non-breaking spaces (U+00A0) between numbers and units.** Tooltip lines like `"Restores 241,303 health"` use NBSP in the position you'd expect a regular space. Lua's `%s` pattern class does NOT match NBSP. Normalize first; the parser does this for you.

If a new tooltip line refuses to match a pattern that "obviously should work", run `/cm dump item <id>` and inspect the raw lines for unexpected characters. The dump command prints the parsed fields plus the raw tooltip lines underneath — pattern-debugging view.

## `GET_ITEM_INFO_RECEIVED` does not fire for already-cached items

If an item's data is already in WoW's client-side cache when the addon starts (because another addon or the loot UI hydrated it earlier), `GET_ITEM_INFO_RECEIVED` does **not** fire for it on the addon's first scan. The discovery retry path (`OnItemInfoReceived` → `discoverOne`) only helps the not-yet-cached case.

That's why **FLASK is classified from `subType` alone** (no tooltip gate) — the subType is already available without a tooltip fetch, so flasks looted before login still get discovered on the first bag scan. Don't regress this: routing FLASK back through tooltip-gated classification breaks first-login discovery for already-cached flasks.

## Combat lockdown taints protected APIs

`CreateMacro` / `EditMacro` / `DeleteMacro` are protected and may taint or fail if called during combat. Any path that could reach `EditMacro` must check `InCombatLockdown()` first.

The only sanctioned path is `MacroManager.SetMacro` / `SetCompositeMacro`. Every other module — Selector, Ranker, Classifier, BagScanner, TooltipCache, SpecHelper — must stay pure so the recompute pipeline can run in combat without taint risk. Combat-deferred writes queue in `pendingUpdates` and flush on `PLAYER_REGEN_ENABLED`. See [macro-manager.md](./macro-manager.md#combat-deferral).

## Secret values

WoW Midnight marks certain protected returns as opaque tokens that error if Lua tries to compare them. CM's pipeline doesn't currently rely on any secret-valued field, but if one becomes load-bearing in the future (e.g. interrupt flags from `UnitCastingInfo`), the comparison must happen C-side via `Frame:SetAlphaFromBoolean` / `C_CurveUtil.EvaluateColorValueFromBoolean`, not in Lua.

## Stored macro icon vs `#showtooltip`

WoW (and action-bar addons that render via `GetActionTexture` — ElvUI, Bartender) only let `#showtooltip` drive the action-bar button's icon when the macro's stored icon is the `?` sentinel (fileID `134400`, exposed as `DYNAMIC_ICON` in `MacroManager.lua`). Any other stored icon overrides `#showtooltip` on the bar.

Consequence: active macro bodies must store `DYNAMIC_ICON`; empty-state bodies must drop `#showtooltip` entirely and store `DEFAULT_ICON = 7704166` (cooking pot). Storing `DEFAULT_ICON` on an active body shows the cooking pot on the bar instead of the picked item's icon.

The Options panel's `KCMMacroDragIcon` widget is exempt — it resolves to `GetItemIcon(lastItemID)` / `C_Spell.GetSpellTexture(spellID)` directly, since the `?` sentinel looks meaningless on a static UI widget.

See [macro-manager.md](./macro-manager.md#action-bar-icon-convention) for the full convention.

## AceConfigDialog `AddToBlizOptions` returns `(frame, categoryID)`

On modern clients this returns two values: the frame object and the numeric category ID. `Settings.OpenToCategory` wants the **numeric ID**; passing the frame produces a range error. Always capture both return values:

```lua
local frame, categoryID = AceConfigDialog:AddToBlizOptions(REGISTRY_KEY, name, parentID, pathKey)
```

`/cm config` (in `SlashCommands.lua`) uses the captured General sub-page ID stored in `KCM._settingsCategoryID` to open directly to General instead of the empty parent shell.

## `LEARNED_SPELL_IN_TAB` removed in retail

Blizzard removed `LEARNED_SPELL_IN_TAB` from retail; AceEvent throws `Attempt to register unknown event` when registering it. The addon uses its modern replacement `LEARNED_SPELL_IN_SKILL_LINE` so newly-learned spell entries (e.g. Recuperate on level-up) hydrate their macro body without a reload.

If a future patch removes another event the addon listens for, the failure mode is the same: AceEvent throws on registration. Replace with whatever modern event covers the same trigger.
