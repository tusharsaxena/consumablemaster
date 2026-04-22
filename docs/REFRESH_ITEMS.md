# Refreshing the seed item lists

The `defaults/Defaults_*.lua` files seed KCM's per-category priority lists
with known item IDs. Auto-discovery picks up anything else the player
actually carries, but a good seed keeps the default priority ordering
coherent on a fresh install and gives the Ranker something to score
before the first bag scan runs.

This document is the playbook for re-running the refresh when Blizzard
adds new consumables, bumps a patch, or renames subtype strings. Re-run
at the start of each content patch and any time a user reports that
an expected item isn't showing up.

## Sources (in order of preference)

1. **Method.gg — "List of all Midnight Consumables, Enchants and Gems"**
   `https://www.method.gg/guides/list-of-all-midnight-consumables-enchants-and-gems`
   Single page covering combat potions, healing/mana potions, utility
   potions, flasks/phials, stat food, and feasts with itemIDs and stat
   tags. Easiest to ingest — most of the seed data comes from here.

2. **Warcraft Wiki — profession recipe pages**
   `https://warcraft.wiki.gg/wiki/Midnight_alchemy_recipes`
   `https://warcraft.wiki.gg/wiki/Midnight_cooking_recipes`
   Recipe-result names and categorization. Useful to cross-check what
   Method.gg lists and to catch items Method.gg omits.

3. **Wowhead item list pages** (403s on direct fetch — see below)
   `https://www.wowhead.com/items/consumables/potions?filter=166:128;12:3;0:0`
   `https://www.wowhead.com/items/consumables/flasks?filter=166:128;12:3;0:0`
   `https://www.wowhead.com/items/consumables/food-and-drinks?filter=166:128;12:3;0:0`
   Filter is Midnight (patch 12.0.x) with quality ≥ rare. Wowhead blocks
   automated fetches — open these in a browser and copy the list.

4. **In-game verification**
   Roll or vendor an item, load it into a bag, `/reload`, and run
   `/kcm dump item <itemID>`. The output prints `type`, `subType`,
   `classID`, `subClassID`, the `classified:` category, and the parsed
   TooltipCache entry — everything needed to confirm the seed guess.

## Procedure

1. **Collect candidate item IDs** from Method.gg and the Wiki into one
   working list, grouped by seed file (HP_POT, MP_POT, CMBT_POT, FLASK,
   STAT_FOOD, FOOD, DRINK). Exclude HS — healthstone IDs are a fixed
   two-entry whitelist in `Defaults_Healthstone.lua`.

2. **Disambiguate dual-purpose items.** Some potions do more than one
   thing:
   - Refreshing Serum (241306) restores both HP and mana — seed it in
     both `HP_POT` and `MP_POT`.
   - Potion of Devoured Dreams (241294) restores mana but also has a
     combat effect — Method.gg lists it under mana potions, wiki under
     void combat potions. We seed it as `MP_POT` because that's the
     primary effect; the Classifier may also match it as `CMBT_POT`.
   - Void-Shrouded Tincture (241302) is invisibility — classifier-wise
     a short-duration potion, but not a throughput buff. Do NOT seed
     in `CMBT_POT`.

3. **Verify subType strings.** If Blizzard renames a subtype (as they
   did from `"Potion"` → `"Potions"` and merged `"Flask"` + `"Phial"`
   into `"Flasks & Phials"` in Midnight), update the constants at the
   top of `Classifier.lua`:
   ```lua
   local ST_POTION      = "Potions"
   local ST_FOOD        = "Food & Drink"
   local ST_FLASK_PHIAL = "Flasks & Phials"
   ```
   Confirm with `/kcm dump item <id>` — the `instant:` line shows the
   live subType string for any bag item.

4. **Check for new stat-buff phrasings.** The TooltipCache parser matches
   specific stat names ("Critical Strike", "Haste", etc.) AND the
   wildcard phrasing `"<amount> of your highest secondary stat"`. If a
   new potion reads differently (e.g. `"of your primary stat"` or
   `"of a random secondary stat"`), extend `parseStatBuffs` in
   `TooltipCache.lua` and the corresponding special case in
   `Ranker.statWeight`.

5. **Quality tier variants.** Midnight consumables come in multiple
   quality tiers — e.g. the Method.gg-listed ID is often the base
   quality and users may carry a `+1`/`+2` variant (different itemID,
   same name, different stat amount). The Classifier matches all tiers
   because they share subType; auto-discovery picks them up. You do NOT
   need to seed every tier — seed the base ID only.

6. **Update the seed files.** One file per category; see
   `defaults/Defaults_HPPot.lua` for the template. Keep the header
   comment's `Source:` and `Last refresh:` lines accurate.

7. **Smoke-test in game.** For each updated category run:
   ```
   /kcm dump rank <catKey>
   /kcm dump pick <catKey>
   ```
   `rank` shows the seed list with scores; confirm the order matches
   expectations for the current spec. `pick` validates the owned-item
   walk.

## Common pitfalls

- **"Name fabrication" trap.** Do NOT guess item names from itemIDs.
  The prior seed had ~30 invented stat-food names ("Sizzling Steak
  Sandwich", etc.) that didn't match any real item. Always cross-check
  the name against Method.gg or `/kcm dump item` output.

- **Filter URL blocking.** Wowhead's `/items/consumables/*` list URLs
  return HTTP 403 to most automated fetchers. The Method.gg list is a
  rendered HTML page and fetches reliably.

- **Spec-aware seed is a flat list.** `CMBT_POT`, `FLASK`, and
  `STAT_FOOD` are spec-aware at runtime via `bySpec[specKey]`, but
  their seed arrays are FLAT (no per-spec buckets). The Ranker picks
  the best fit for the active spec via stat priority. Don't attempt to
  split the seed by spec.

- **Phial pollution in FLASK.** Haranir profession phials share the
  `"Flasks & Phials"` subType. They classify as FLASK on auto-discovery
  but NOT in the seed. Keep them out of `Defaults_Flask.lua` so the
  default priority list stays combat-focused.
