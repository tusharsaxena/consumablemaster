# defaults/ — seed item IDs and stat priorities

Everything in this folder is **seed data**, not persistent user state. Files here are evaluated at addon load and written into `KCM.SEED.*` constants. The runtime candidate set for each category is computed as:

```
candidates = SEED ∪ db.added ∪ db.discovered − db.blocked
```

That means **updating a defaults file is a free upgrade for every user** — when they next log in, the new seed IDs are picked up without any migration step. User-local changes (added, blocked, pins) live in SavedVariables and are preserved independently.

## Files

| File                          | Populates            | Purpose                                                      |
| ----------------------------- | -------------------- | ------------------------------------------------------------ |
| `Categories.lua`              | `KCM.Categories`     | Metadata (macro name, spec-awareness, ranker/classifier key); composite rows for HP_AIO / MP_AIO |
| `Defaults_StatPriority.lua`   | `KCM.SEED.STAT_PRIORITY` | Primary + ordered secondary stats per `<classID>_<specID>` |
| `Defaults_Food.lua`           | `KCM.SEED.FOOD`      | Basic Well Fed food (non-stat); may include spell sentinels (e.g. Recuperate) |
| `Defaults_Drink.lua`          | `KCM.SEED.DRINK`     | Mana-recovery drinks                                         |
| `Defaults_StatFood.lua`       | `KCM.SEED.STAT_FOOD` | Cooked stat meals (feasts excluded)                          |
| `Defaults_HPPot.lua`          | `KCM.SEED.HP_POT`    | Direct-heal potions (no absorb/shield)                       |
| `Defaults_MPPot.lua`          | `KCM.SEED.MP_POT`    | Mana-restoration potions                                     |
| `Defaults_Healthstone.lua`    | `KCM.SEED.HS`        | Warlock Healthstones                                         |
| `Defaults_CombatPot.lua`      | `KCM.SEED.CMBT_POT`  | Offensive combat potions (utility potions excluded)          |
| `Defaults_Flask.lua`          | `KCM.SEED.FLASK`     | Flasks / Alchemist's Concoctions                             |

Composite categories (`HP_AIO`, `MP_AIO`) have **no seed file** — they compose other categories' picks at recompute time.

## Category scope decisions

- **No feasts.** Personal feasts and raid feasts are deliberately excluded from `STAT_FOOD`. Users wanting a feast macro can add the item ID manually.
- **No bandages.** Bandage category was considered and cut; first aid is a separate workflow.
- **No utility potions** in `CMBT_POT` (invisibility, slow fall, swiftness, absorb potions are not throughput).
- **Healthstones** are always listed; on non-warlock characters the bag scan simply returns zero count and the macro falls back to its `emptyText`.

---

# Refresh procedure

The playbook for re-running the seed refresh when Blizzard adds new consumables, bumps a patch, or renames subtype strings. Re-run at the start of each content patch and any time a user reports that an expected item isn't showing up.

## Sources (in order of preference)

1. **In-game vendors and dump commands.** Primary source for Midnight seed lists. Walk the relevant vendor (e.g. the Silvermoon innkeeper for FOOD/DRINK), note the item IDs, and run `/cm dump item <id>` to confirm subType / classID / classified bucket. The Silvermoon innkeeper is the canonical source for `FOOD` and `DRINK` in Midnight (vendor IDs 260254–260264). For batch name lookups paste the `/run` snippet under [In-game name dump](#in-game-name-dump) below.

2. **Method.gg — "List of all Midnight Consumables, Enchants and Gems"**
   [https://www.method.gg/guides/list-of-all-midnight-consumables-enchants-and-gems](https://www.method.gg/guides/list-of-all-midnight-consumables-enchants-and-gems)
   Single page covering combat potions, healing/mana potions, utility potions, flasks/phials, stat food, and feasts with itemIDs and stat tags. Useful as a starting list to seed the working set, then verify in-game. Fetches reliably via WebFetch.

3. **Warcraft Wiki — profession recipe pages**
   [https://warcraft.wiki.gg/wiki/Midnight_alchemy_recipes](https://warcraft.wiki.gg/wiki/Midnight_alchemy_recipes)
   [https://warcraft.wiki.gg/wiki/Midnight_cooking_recipes](https://warcraft.wiki.gg/wiki/Midnight_cooking_recipes)
   Recipe-result names and categorization. Useful to cross-check what Method.gg lists and to catch items Method.gg omits.

4. **archon.gg** — used for `Defaults_StatPriority.lua` (Mythic+ "this week" ranking). See the comment header inside that file for the exact URL pattern and refresh procedure.

5. **Wowhead / wowdb — manual browser only.** Both sites front their pages with Cloudflare and return HTTP 403 to WebFetch / curl. Open in a real browser if you need the item DB; do NOT waste time scripting against them.

   Useful URLs (for browser):
   - [https://www.wowhead.com/items/consumables/potions?filter=166:128;12:3;0:0](https://www.wowhead.com/items/consumables/potions?filter=166:128;12:3;0:0)
   - [https://www.wowhead.com/items/consumables/flasks?filter=166:128;12:3;0:0](https://www.wowhead.com/items/consumables/flasks?filter=166:128;12:3;0:0)
   - [https://www.wowhead.com/items/consumables/food-and-drinks?filter=166:128;12:3;0:0](https://www.wowhead.com/items/consumables/food-and-drinks?filter=166:128;12:3;0:0)

   Filter is Midnight (patch 12.0.x) with quality ≥ rare.

## In-game name dump

Paste this single `/run` line in chat with whatever IDs you need. It preloads each item, then opens a copyable edit box:

```
/run StaticPopupDialogs.KCMDUMP={text="Copy:",button1="OK",hasEditBox=true,editBoxWidth=400,OnShow=function(s)s.editBox:SetText(_G.KCM_DUMP)s.editBox:HighlightText()end,timeout=0,whileDead=true,hideOnEscape=true} local ids={260254,260255,260256,260257,260258,260259,260260,260261,260262,260263,260264} local t={} for _,id in ipairs(ids) do C_Item.RequestLoadItemDataByID(id) table.insert(t,id.."="..(C_Item.GetItemNameByID(id) or "?")) end _G.KCM_DUMP=table.concat(t,"; ") StaticPopup_Show("KCMDUMP")
```

Replace the `ids = { ... }` list with whatever IDs you need to label. If a line comes back as `<id>=?` the item wasn't cached yet — run the command a second time and the entries will fill in.

## Procedure

1. **Collect candidate item IDs.** For FOOD and DRINK, walk the Silvermoon innkeeper in-game and grab their stock. For everything else, start from Method.gg and the Wiki and verify in-game. Group the working list by seed file (`HP_POT`, `MP_POT`, `CMBT_POT`, `FLASK`, `STAT_FOOD`, `FOOD`, `DRINK`). Exclude `HS` — healthstone IDs are a fixed two-entry whitelist in `Defaults_Healthstone.lua`.

2. **Disambiguate dual-purpose items.** Some potions do more than one thing:
   - Refreshing Serum (241306) restores both HP and mana — seed it in both `HP_POT` and `MP_POT`.
   - Potion of Devoured Dreams (241294) restores mana but also has a combat effect — Method.gg lists it under mana potions, wiki under void combat potions. We seed it as `MP_POT` because that's the primary effect; the Classifier may also match it as `CMBT_POT`.
   - Void-Shrouded Tincture (241302) is invisibility — classifier-wise a short-duration potion, but not a throughput buff. Do NOT seed in `CMBT_POT`.

3. **Verify subType strings.** If Blizzard renames a subtype (as they did from `"Potion"` → `"Potions"` and merged `"Flask"` + `"Phial"` into `"Flasks & Phials"` in Midnight), update the constants at the top of `Classifier.lua`:
   ```lua
   local ST_POTION      = "Potions"
   local ST_FOOD        = "Food & Drink"
   local ST_FLASK_PHIAL = "Flasks & Phials"
   ```
   Confirm with `/cm dump item <id>` — the `instant:` line shows the live subType string for any bag item.

4. **Check for new stat-buff phrasings.** The TooltipCache parser matches specific stat names ("Critical Strike", "Haste", etc.) AND the wildcard phrasing `"<amount> of your highest secondary stat"`. If a new potion reads differently (e.g. `"of your primary stat"` or `"of a random secondary stat"`), extend `parseStatBuffs` in `TooltipCache.lua` and the corresponding special case in `Ranker.statWeight`.

5. **Quality tier variants.** Midnight consumables come in multiple quality tiers — e.g. the Method.gg-listed ID is often the base quality and users may carry a `+1` / `+2` variant (different itemID, same name, different stat amount). The Classifier matches all tiers because they share subType; auto-discovery picks them up. You do NOT need to seed every tier — seed the base ID only.

6. **Update the seed files.** One file per category; see `Defaults_HPPot.lua` for the template. Keep the header comment's `Source:` and `Last refresh:` lines accurate.

7. **Smoke-test in game.** For each updated category run:
   ```
   /cm dump pick <catKey>
   ```
   The `pick` dump prints the effective priority list with per-entry Ranker scores AND the owned-item walk result, so you can confirm the seed ordering and the actual pick in one shot. `<catKey>` is the lower- or upper-case category key (e.g. `flask`, `HP_POT`, `hp_aio`).

## Common pitfalls

- **"Name fabrication" trap.** Do NOT guess item names from itemIDs. The prior seed had ~30 invented stat-food names ("Sizzling Steak Sandwich", etc.) that didn't match any real item. Always cross-check with the in-game name dump snippet, `/cm dump item`, or Method.gg.

- **Cloudflare blocking on item DBs.** Both Wowhead and wowdb sit behind Cloudflare and return HTTP 403 to WebFetch / curl — open them in a real browser if needed. Method.gg renders server-side and fetches reliably.

- **Spec-aware seed is a flat list.** `CMBT_POT`, `FLASK`, and `STAT_FOOD` are spec-aware at runtime via `bySpec[specKey]`, but their seed arrays are FLAT (no per-spec buckets). The Ranker picks the best fit for the active spec via stat priority. Don't attempt to split the seed by spec.

- **Phial pollution in FLASK.** Haranir profession phials share the `"Flasks & Phials"` subType. They classify as FLASK on auto-discovery but NOT in the seed. Keep them out of `Defaults_Flask.lua` so the default priority list stays combat-focused.

All IDs should be treated as data, not code — corrections welcome.
