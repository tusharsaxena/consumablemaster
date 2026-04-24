# Ka0s Consumable Master

![alt text](https://media.forgecdn.net/attachments/1646/103/consumemaster-logo-jpg.jpg)

An auto-managed consumable-macro addon for **World of Warcraft: Midnight**. Keeps a fixed set of account-wide global macros pointed at the single best consumable currently in your bags, for eight categories — so you never rebuild a food / flask / potion macro again.

**Slash prefix:** `/kcm`
**Framework:** Ace3 (AceAddon, AceEvent, AceDB, AceConsole, AceConfig)
**Version:** 1.1.0
**Locale:** English only

## What it does

Every time you loot a better food, swap spec, reload, or leave combat, Ka0s Consumable Master re-runs its pipeline and rewrites each macro's body — either `#showtooltip / /use item:<best>` for items or `#showtooltip / /cast <spell>` for spell entries (class abilities like Recuperate). The macros live in the **account-wide** pool (identified by name — the addon never hardcodes a slot), so they're shared across every character, survive slot reordering, and coexist with every other macro in your list.

| # | Category                  | Macro           | Spec-aware? |
|---|---------------------------|-----------------|-------------|
| 1 | Basic / conjured food     | `KCM_FOOD`      | No          |
| 2 | Drink (mana regen)        | `KCM_DRINK`     | No          |
| 3 | Healing potion            | `KCM_HP_POT`    | No          |
| 4 | Mana potion               | `KCM_MP_POT`    | No          |
| 5 | Warlock healthstone       | `KCM_HS`        | No          |
| 6 | Flask                     | `KCM_FLASK`     | **Yes**     |
| 7 | Combat potion (throughput)| `KCM_CMBT_POT`  | **Yes**     |
| 8 | Stat food                 | `KCM_STAT_FOOD` | **Yes**     |

Macro writes that would land during combat are queued and flushed on `PLAYER_REGEN_ENABLED` — the addon never calls a protected macro API in combat.

## Screenshots

***Settings Panel***

![alt text](https://media.forgecdn.net/attachments/1646/104/kcm-01-general-png.png)

***Stat Priority Selector (Per Spec)***

![alt text](https://media.forgecdn.net/attachments/1646/105/kcm-02-statpriority-png.png)

***Food Category Priority Selector***

![alt text](https://media.forgecdn.net/attachments/1646/106/kcm-03-food-png.png)

***Ranking Explainer***

![alt text](https://media.forgecdn.net/attachments/1646/107/kcm-03-ranking-png.png)

## Usage

1. Install the addon using the Addon Manager of choice, or manually
2. Launch the game. The addon initializes on login — first `PLAYER_ENTERING_WORLD` scans bags, discovers known items, and writes all eight macros.
3. Drag the new `KCM_*` macros onto your action bars from the macro UI (or use the draggable icon at the top of each category page in the settings panel).

All settings live at **Escape → Options → AddOns → Consumable Master** (or `/kcm config`).

## Slash commands

| Command              | What it does                                                           |
|----------------------|------------------------------------------------------------------------|
| `/kcm`               | Show help.                                                             |
| `/kcm config`        | Open the settings panel (priority lists, spec selector, add-by-ID).    |
| `/kcm resync`        | Force a full rescan: invalidate tooltip cache, re-discover, recompute. |
| `/kcm reset`         | Confirm-and-reset every priority list and stat override to defaults.   |
| `/kcm debug`         | Toggle verbose logging.                                                |
| `/kcm version`       | Print the addon version.                                               |
| `/kcm dump <target>` | Inspect internal state. Targets: `categories`, `statpriority`, `bags`, `item <id>`, `pick <catKey>`. |

### General

- **Debug mode** — toggle verbose chat logging. Equivalent to `/kcm debug`.
- **Force resync** — invalidate the tooltip cache, rescan bags, rewrite every macro. Equivalent to `/kcm resync`. Blocked in combat.
- **Reset all priorities** — with confirmation, wipe every added / blocked / pinned entry and every stat-priority override. Seed defaults are restored.

### Stat Priority

One shared page that drives the three spec-aware categories (Stat Food, Combat Potion, Flask).

- **Viewing spec** — selects which spec's stat priority you're editing. Also controls which spec's list shows on the three spec-aware category pages. Specs render with their class icon and human-readable name (e.g. "Shaman — Enhancement"), not raw class/spec IDs.
- **Primary stat** — the dominant stat for the spec. Primary-stat consumables always beat secondary-stat ones regardless of magnitude.
- **Secondary stat #1 … #4** — ordered preference for secondary stats (Crit / Haste / Mastery / Versatility). Position 1 weighs most. Leave slots as `(none)` to truncate the list — a truncated list ranks unlisted secondaries at 0.
- **Reset stat priority** — drop the user override for the viewed spec. Ranker falls back to the seed default (`defaults/Defaults_StatPriority.lua`) or, if none exists, the class-primary fallback.

### Per-category pages

Each of the eight categories has its own page in the tab list. Spec-aware pages also show the viewed spec at the top.

- **Draggable macro icon** — the small icon below the title. Drag it onto an action bar to place the `KCM_*` macro.
- **Add item or spell by ID**
  - **Type** dropdown — choose `Item` or `Spell`.
  - **ID** input — validates against `C_Item.GetItemInfoInstant` (items) or `C_Spell.GetSpellName` (spells). On submit a confirmation dialog shows the resolved name before committing.
- **Priority list** — one row per candidate, ordered by effective rank:
  - Status glyphs: ready-check green (owned in bags / spell known), red (not owned), yellow star (currently picked by the macro).
  - **Blue info button** — hover for the per-item score breakdown.
  - **↑ / ↓** — reorder (writes a pin, overrides the Ranker score).
  - **×** — remove the entry. Also blocks it so auto-discovery won't re-add it.
- **Reset category** — with confirmation, clears this category's added / blocked / pinned entries (the viewed spec's bucket only, for spec-aware categories). Discovered items (from bag scans) are preserved.

## How picking & ranking works

Every recompute runs this pipeline per category:

1. **Build the candidate set.** Union of three sources, minus the blocklist:
   - `seed` — the shipped `defaults/Defaults_<CAT>.lua` list. Most entries are itemIDs, but a seed can also include spell entries (Recuperate is top-ranked in Food by default).
   - `added` — items or spells you manually added via the settings panel.
   - `discovered` — items auto-scanned from your bags that match the category's classifier rules (bag discovery is item-only; spells are never auto-discovered).
   - `blocked` — entries you've removed with the × button. Subtracted from the union; auto-discovery won't re-add a blocked item.
2. **Score every candidate.** A per-category scorer (`Ranker.lua`) reads the parsed tooltip and returns a number; higher is better. Signals per category:
   - **Food / Drink:** flat heal/mana value + %-based restore (amplified so Midnight %-based food outranks flat tiers) + conjured bonus + ilvl + quality tiebreak.
   - **HP potion / MP potion:** raw heal/mana value. **Immediate restores always outrank heal-over-time (HOT) pots, unless the HOT's amount beats the best immediate in the set by more than 20%.** Prevents a slightly-bigger HOT from winning over a smaller immediate (e.g. Amani Extract's 265,420 over 20 sec vs Silvermoon Health Potion's 241,303 instant — Silvermoon wins because the HOT isn't 20% bigger).
   - **Stat Food / Combat Potion / Flask:** weighted sum of the tooltip's stat buffs against the active spec's stat priority. Primary-stat consumables always beat any secondary-stat ones; within secondary, earlier positions weigh more. Wildcard "highest secondary stat" buffs resolve against the spec's top secondary at rank time.
   - **Healthstone:** hard-coded preference table (modern auto-leveling Healthstone > legacy fallback), + ilvl tiebreak.
   - **Spell entries:** a fixed score that outranks every item. Spells never compete with items on value — so Recuperate sits above every food by default. You can pin items above a spell if you prefer.
3. **Merge pins.** When you reorder rows with ↑ / ↓ in the settings panel, the addon writes pins of `{itemID, position}`. Pins override the Ranker order — pinned entries land at their requested position and non-pinned items fill the gaps in score order.
4. **Walk the final list** for the first entry you actually own. Items check bag counts; spells check `IsPlayerSpell` (class / spec / talent-granted). That first-owned entry becomes the macro body. If you own none, the macro prints a friendly `KCM: no <category>` stub so the slot stays valid.

Hovering the **blue info button** on any row shows the full per-item score breakdown (each contributing signal and a one-line summary of the scoring rule), so you can see exactly why an entry landed where it did.

## Bug Reports

Please report any issues in the [Issues](https://github.com/tusharsaxena/consumablemaster/issues) tab, not as a comment!


## Version History

**v1.1.0**

*   Correctness: locked items (stack-split, mail) no longer trigger a macro flap; one bad category scorer can no longer break the other seven (per-category `pcall` in Recompute); oversized macro bodies fall back to the empty-state stub with a one-shot chat error instead of silently truncating; combat deferrals retry up to three times before giving up, with a chat notice.
*   Performance: a per-Recompute score cache memoizes `GetItemInfo`, tooltip parses, and per-category Ranker scores so a flurry of bag events doesn't re-score the same candidate set eight times over.
*   Discovery GC: `discovered` entries are stamped with a unix timestamp; a PEW-time sweep deletes items not seen in bags for 30 days so the set can't grow unbounded across account-lifetime play.
*   Spell hydration: `LEARNED_SPELL_IN_TAB` now triggers a recompute so a just-learned spell entry (e.g. Recuperate on level-up) adopts its macro body without a reload.
*   UX: category tabs reordered to Food → Drink → Healing Potion → Mana Potion → Healthstone → Flask → Combat Potion → Stat Food. Empty-state macros now show a cooking-pot fallback icon instead of the question mark.

**v1.0.0**

*   Initial Release … yay!
