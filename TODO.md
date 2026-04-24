# TODO

- ✅ Increase the spacing between the item name label and the icons to its right.
- ✅ Add a draggable macro icon at the top of each category panel (below the title) so users can drag the macro onto an action bar.
- ✅ Consolidate the per-category Stat Priority section into a single shared "Stat Priority" panel. Move the "Viewing spec" dropdown there. Place the new section directly below the General tab in the tab selector.
- ✅ Move the sub text :Spec-aware. Viewing 12_581" to be just below the title and above the macro drag icon row. Add some row spacing between this text and macro selector.
- ✅ Replace spec-id strings (e.g. `7_264`) with the actual class and spec names, optionally with class/spec icons.
- ✅ In the General tab: move "Force resync" to the second line and "Reset all priorities" to the third line. Remove the version number.
- ✅ Add a `/kcm version` slash command that prints the addon version.
- ✅ Change the delete button glyph from a red X (collides with the "not in bags" icon) to a different glyph — i would suggest a red circle with a diagonal line through it (no-entry sign).
- ✅ Check the Stat Food section — formatting looks off. The separator and reset category and stat priority sections appear midway through the list - the list is long. screenshot here: https://i.ibb.co/rK5MpPys/Untitled.png and https://i.ibb.co/VcQPT7NG/image.png
- ✅ Check default seed items again once - remove classic fallbacks and use items from midnight silvermoon innkeeper as seed items - ask the user for which items should be a part of the seed list.
- ✅ relook into the .md files which has instructions on how to build the seed lists
- ✅ Add conjured food and recuperate to the seed list. Recuperate (spell id: 1231411) should be the top ranked item in food in the seed list, unless manually overriden (removed and order dropped) by the user. Conjured food (Conjured Mana Bun, item id 113509) should by default be the second item in the food category and top item in the drink categry; unless deleted or order changed by the user
- ✅ Simplify the dump commands
- ✅ Rename the entry in the Settings Panel to be Consumable Master instead of Ka0s Consumable Master. The addon name should be retained as Ka0s Consumable Master though. Do not rename the directory name. 
- ✅ Add the ability to add an item or spell to each category. Achieve this by having a dropdown to select Item or Spell to the left of the inputbox. Add a validator to check whether a valid itemid or spellid has been entered. 
- ✅ Add a confirmation dialog before adding an item or spell
- ⬜ relook at seed lists and sort order
- ⬜ check resync behavior
- ⬜ test combat behavior
- ⬜ test what happens when a specific consumable is exhausted
- ⬜ Add support for vantus runes, weapon oils, whethstones and weightstones, jumper cables, drums, invis pots
- ⬜ Add fallback icons for every category macro when empty (not the question mark)
- ⬜ Change order of panel entries - food > drink > healing potion > mana potion > healthstone > flask > combat potion > stat food
- ⬜ Add stat weights alongside stat priorities for primary and secondary stats to better improve ranking
- ⬜ for every item, add a checkbox to disable a specific item from being picked by the macro. this will allow the user to preserve ordering without deleting the item altogether

## Deferred M9 smoke tests

- ⬜ M9.31 (M-9 gate): respec into a build that grants a spell on the Food seed list (e.g. Recuperate for Rogue). After learning the spell, `KCM_FOOD` should recompute to the spell pick within one frame — no bag event or spec change needed. Code path is wired (`LEARNED_SPELL_IN_TAB` in `Core.lua`); needs in-game verification.
- ⬜ M9.32 (M-12 gate): force three `EditMacro` failures on a single queued entry via a debug harness (`/run _G._orig=EditMacro; EditMacro=function() return 0 end`), enter/exit combat three times, confirm the third regen drops the entry and prints the give-up notice. Restore with `/run EditMacro=_G._orig`.

## Deferred from PE review (post-1.0 hardening, sections 3–6 not scheduled in v1.1.0)

- ⬜ PE M-3: drop the unused `reason` parameter on `Pipeline.RecomputeOne` (or revive the per-category debug log behind a more granular flag).
- ⬜ PE M-4: migrate legacy `GetItemInfo` / `GetItemCount` globals to `C_Item.GetItemInfo` / `C_Item.GetItemCount` across `Ranker.lua`, `KCMItemRow.lua`, and any other call sites. Not a bug; just future-proofing.
- ⬜ PE M-11: `Options.O.RequestRefresh` — also reset `_refreshFirstAt` inside `O.Refresh` (or whenever `_refreshPending` clears) so superseded fires don't leak stale wait time into the next burst.
- ⬜ PE H-5: if richer reason tracking becomes useful for debugging, accumulate `Pipeline.RequestRecompute` reasons into a set instead of last-write-wins. Currently fine.
- ⬜ PE P-5: `Options.O.Refresh` calls `NotifyChange` even when the panel is closed. Cheap today; keep an eye on it if profiling ever shows cost.
- ⬜ PE M-8: verify in-game whether `Ranker.PCT_WEIGHT = 1e4` is still large enough at level-cap that Midnight %-based food outranks the best flat-value food. If it isn't, either bump the weight or switch the model to `pct/100 * UnitHealthMax("player")` and compare apples-to-apples. Test recipe: equip highest-level flat food + highest-level pct food; run `/kcm dump pick FOOD` and confirm pct food wins. See `docs/TECHNICAL_DESIGN_v2.md` §14.
- ⬜ PE L-7 (out of primary PE scope but parked here): DRY the three identical `STAT_FOOD` / `CMBT_POT` / `FLASK` scorers into a shared factory in `Ranker.lua`.
