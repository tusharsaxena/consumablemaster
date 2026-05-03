# Ka0s Consumable Master

![wow](https://img.shields.io/badge/WoW-Midnight_12.0.5-orange)
![CurseForge Version](https://img.shields.io/curseforge/v/1522944)
![license](https://img.shields.io/badge/license-MIT-green)

![alt text](https://media.forgecdn.net/attachments/1646/103/consumemaster-logo-jpg.jpg)

An auto-managed consumable-macro addon for **World of Warcraft: Midnight**. Keeps a fixed set of account-wide global macros pointed at the single best consumable currently in your bags, across eight categories plus two combat-conditional combo macros — so you never rebuild a food / flask / potion macro again.

Every time you loot a better food, swap spec, reload, or leave combat, Ka0s Consumable Master rewrites each macro to point at the best current pick — `/use item:<id>` for items or `/cast <spell>` for spell entries (class abilities like Recuperate). The macros live in the **account-wide** pool (identified by name — the addon never hardcodes a slot), so they're shared across every character, survive slot reordering, and coexist with every other macro in your list.

| #  |Category                                                     |Macro         |Spec-aware? |
| -- |------------------------------------------------------------ |------------- |----------- |
| 1  |Basic / conjured food                                        |<code>KCM_FOOD</code> |No          |
| 2  |Drink (mana regen)                                           |<code>KCM_DRINK</code> |No          |
| 3  |Healing potion                                               |<code>KCM_HP_POT</code> |No          |
| 4  |Mana potion                                                  |<code>KCM_MP_POT</code> |No          |
| 5  |Warlock healthstone                                          |<code>KCM_HS</code> |No          |
| 6  |Flask                                                        |<code>KCM_FLASK</code> |<strong>Yes</strong> |
| 7  |Combat potion (throughput)                                   |<code>KCM_CMBT_POT</code> |<strong>Yes</strong> |
| 8  |Stat food                                                    |<code>KCM_STAT_FOOD</code> |<strong>Yes</strong> |
| 9  |All-in-one health (combat: HS → HP pot, out of combat: food) |<code>KCM_HP_AIO</code> |No          |
| 10 |All-in-one mana (combat: MP pot, out of combat: drink)       |<code>KCM_MP_AIO</code> |No          |

Macro writes that would land during combat are queued and applied when you leave combat — the addon never calls a protected macro API in combat.

## Screenshots

**_Settings Panel_**

![alt text](https://media.forgecdn.net/attachments/1646/104/kcm-01-general-png.png)

**_Stat Priority Selector (Per Spec)_**

![alt text](https://media.forgecdn.net/attachments/1646/105/kcm-02-statpriority-png.png)

**_Food Category Priority Selector_**

![alt text](https://media.forgecdn.net/attachments/1646/106/kcm-03-food-png.png)

**_Ranking Explainer_**

![alt text](https://media.forgecdn.net/attachments/1646/107/kcm-03-ranking-png.png)

## Usage

Install the addon with the Addon Manager of your choice (or drop the folder into `Interface/AddOns`) and log in. The addon initializes on `PLAYER_ENTERING_WORLD` — bags are scanned, owned items are discovered, and all `KCM_*` macros are written. Drag any of the macros onto your action bars from the macro UI, or use the draggable icon at the top of each category page in the settings panel.

### Slash commands

`/cm` is the short form; `/consumablemaster` is a long-form alias that accepts the same subcommands. Every chat line the addon emits — slash output, in-combat notices, the empty-state stub fired when a macro has no usable pick — is prefixed with a cyan `[CM]` tag for easy filtering.

| Command | What it does |
|---------|--------------|
| `/cm` | Show help. |
| `/cm config` | Open the settings panel (priority lists, spec selector, add-by-ID). |
| `/cm resync` | Force a full rescan: re-discover, recompute picks, rewrite macros where the pick changed. |
| `/cm rewritemacros` | Force an unconditional rewrite of every KCM macro body + icon. Use when an action-bar icon looks stale. |
| `/cm reset` | Confirm-and-reset every priority list and stat override to defaults. |
| `/cm debug` | Toggle verbose logging. |
| `/cm version` | Print the addon version. |
| `/cm list` | List every schema-driven setting and its current value, grouped by panel. |
| `/cm get <path>` | Print one setting's value (e.g. `/cm get debug`). |
| `/cm set <path> <value>` | Set a setting; flows through the same path the panel widget uses. |
| `/cm priority <cat> list\|add\|remove\|up\|down\|reset [<id>]` | Per-category priority-list editor. `<id>` accepts `12345` (item) or `s:5512` (spell). Composite categories use `/cm aio` instead. |
| `/cm stat list\|primary\|secondary\|reset [<specKey>]` | Per-spec stat-priority editor. `<specKey>` is `<classID>_<specID>` or `CLASS:SPEC` (e.g. `SHAMAN:ENHANCEMENT`); defaults to current spec. |
| `/cm aio <key> list\|toggle\|up\|down\|reset` | Composite-category editor for `HP_AIO` / `MP_AIO`. Sub-categories are locked to their section, so `up` / `down` infer the section from where the ref appears. |
| `/cm dump <target>` | Inspect internal state. Targets: `categories`, `statpriority`, `bags`, `item <id>`, `pick <catKey>`. |

### Settings panel

Settings live at **Escape → Options → AddOns → Consumable Master** (or `/cm config`). One parent category ("Ka0s Consumable Master") with sub-pages for every panel below.

**General**

Two sections, top to bottom.

*General*

*   **Enable** — master toggle. When off, the recompute pipeline is a no-op: macros keep their last-written body and stop updating with bag / spec / combat events. Toggle back on and macros refresh against current state immediately. Persists in saved variables.
*   **Debug mode** — toggle verbose chat logging. Equivalent to `/cm debug`.

*Maintenance*

*   **Force resync** — invalidate the tooltip cache, re-run auto-discovery against your bags, and recompute every category's pick. Macros are re-issued only when the pick or body actually changes. Equivalent to `/cm resync`. Blocked in combat.
*   **Force rewrite macros** — unconditionally re-issue every `KCM_*` macro (body + stored icon), bypassing the "unchanged" cache. Use when an action-bar icon looks stale (e.g. ElvUI held the previous static texture across an upgrade). Equivalent to `/cm rewritemacros`. Blocked in combat. A `/reload` afterwards guarantees the action-bar framework re-queries every button.
*   **Reset all priorities** — with confirmation, wipe every added / blocked / pinned entry and every stat-priority override. Seed defaults are restored.

**Stat Priority**

One shared page that drives the three spec-aware categories (Stat Food, Combat Potion, Flask).

*   **Viewing spec** — selects which spec's stat priority you're editing. Also controls which spec's list shows on the three spec-aware category pages. Specs render with their class icon and human-readable name (e.g. "Shaman — Enhancement"), not raw class/spec IDs.
*   **Primary stat** — the dominant stat for the spec. Primary-stat consumables always beat secondary-stat ones regardless of magnitude.
*   **Secondary stat #1 … #4** — ordered preference for secondary stats (Crit / Haste / Mastery / Versatility). Position 1 weighs most. Leave slots as `(none)` to truncate the list — a truncated list ranks unlisted secondaries at 0.
*   **Reset stat priority** — drop the user override for the viewed spec; falls back to the seed default for that spec.

**Per-category pages**

Each of the eight single-category macros has its own page. Spec-aware pages show the viewed spec at the top.

*   **Draggable macro icon** — the small icon below the title. Drag it onto an action bar to place the `KCM_*` macro.
*   **Add item or spell by ID** — pick **Item** or **Spell**, paste the ID, press Enter. Invalid IDs are rejected with a chat error; the typed text persists so you can fix the typo without re-entering it.
*   **Priority list** — one row per candidate, ordered by effective rank:
    *   Status glyphs: green check (owned in bags / spell known), red (not owned), yellow star (currently picked by the macro).
    *   **Blue info button** — hover for the per-item score breakdown.
    *   **↑ / ↓** — reorder. Pinning an item overrides the automatic ranking for that row.
    *   **×** — remove the entry. Also blocks it so auto-discovery won't re-add it.
*   **Reset category** — clears this category's added / blocked / pinned entries (the viewed spec's bucket only, for spec-aware categories). Auto-discovered items are preserved.

**AIO Health / AIO Mana**

Two composite pages (after Stat Food) that combine other categories' picks under combat conditionals — `KCM_HP_AIO` runs Healthstone → Healing Potion in combat and the Food pick out of combat; `KCM_MP_AIO` runs Mana Potion in combat and Drink out of combat. Each page has *In Combat* and *Out of Combat* sections; sub-categories are locked to their section but can be toggled on/off and reordered within it. Each row shows the current pick preview on the left and the toggle + reorder controls on the right. Ranking lives on each individual category's page, not here.

## How picking & ranking works

Each macro is rebuilt by a four-step pipeline:

1.  **Build the candidate set** — the union of the shipped seed list, items / spells you've manually added, and items auto-discovered from your bags, minus anything you've blocked with **×**.
2.  **Score every candidate** — a per-category scorer reads the tooltip and produces a number; higher is better:
    *   **Food / Drink** — heal or mana value, with bonuses for conjured items and %-based restores (so Midnight %-based food outranks flat tiers).
    *   **HP / MP potions** — raw heal or mana value. **Immediate restores beat heal-over-time pots unless the HOT's total exceeds the best immediate by more than 20%**, so a slightly-bigger HOT doesn't win over an instant heal in an emergency.
    *   **Stat Food / Combat Potion / Flask** — weighted match against the active spec's stat priority. Primary-stat consumables always beat secondary-stat ones; within secondary, earlier positions weigh more.
    *   **Healthstone** — small preference table (modern auto-leveling stones beat legacy ones).
    *   **Spell entries** — a fixed score that ranks above every item, so a class ability (e.g. Recuperate as a Food entry) sits at the top of its category by default. You can pin items above it if you prefer.
3.  **Apply pins** — when you reorder rows with ↑ / ↓, those positions override the score for those rows.
4.  **Walk the list** — pick the first entry you actually own (item in bags, or spell known on your character). If you own none, the macro prints a friendly cyan `[CM] no <category>` stub when clicked.

Hovering the **blue info button** on any row shows the per-item score breakdown, so you can see exactly why an entry landed where it did.

## FAQ

| Question | Answer |
|----------|--------|
| Will this delete or overwrite my existing macros? | No. The `KCM_*` macros are identified by **name**, never by slot, and the addon only ever touches macros it owns. Your custom macros — including anything already in the account-wide pool — are never read, moved, or deleted. If you delete a `KCM_*` macro by hand, the next pipeline run recreates it. |
| Do the macros work across all my characters? | Yes — they're written to the **account-wide** macro pool (slots 1–120). One set of macros is shared across every character on the account. Priority lists, added/blocked entries, and stat-priority overrides also persist account-wide with a single profile by default. |
| Why are some categories per-spec and others aren't? | Flask, Combat Potion, and Stat Food are **spec-aware** because their value depends on your stat priority. Food, Drink, HP Potion, MP Potion, and Healthstone rank the same regardless of spec, so they share one priority list. |
| How do I add an item or spell the addon doesn't know about? | Open the category's page, use **Add item or spell by ID** at the top. Pick **Item** or **Spell**, paste the ID, press Enter. Invalid IDs are rejected with a chat error and you keep your typed text so you can fix typos without re-entering. |
| How do I force a specific item to always win? | Use the **↑ / ↓** buttons on its row to move it to the position you want. Pinned positions override the automatic ranking. |
| How do I permanently remove an item? | Use the **×** button on its row. That blocks the item so auto-discovery won't re-add it. **Reset category** (or **Reset all priorities** in General) clears the blocklist again. |
| Does it work with ElvUI / Bartender / other action-bar addons? | Yes — the `KCM_*` macros are plain Blizzard macros. If the picked item's icon doesn't show on the bar, see the Troubleshooting entry below; a one-time **Force rewrite macros** + `/reload` is occasionally needed on upgrade. |
| Can I use this in a non-English client? | No — **English only**. Item subtype matching and tooltip parsing both rely on English strings; localization is explicitly out of scope. |
| Will new patch flasks / potions work automatically? | Usually yes — auto-discovery scans your bags and classifies anything matching by type and tooltip, so a freshly-looted new-tier flask joins the candidate set on the next bag update. If a patch renames a subtype or reformats tooltip numbers, please file an issue. |
| Why does a smaller-instant HP potion beat a bigger heal-over-time potion? | By design. Immediate restores outrank HOT pots unless the HOT's total is **more than 20% larger** than the best immediate. Immediate value is usually what you want in an emergency. You can override by pinning the HOT above the immediate. |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Action bar shows the cooking-pot icon instead of the picked item's icon. | Run **Settings → General → Force rewrite macros** (or `/cm rewritemacros`) then `/reload`. Some action-bar frameworks cache textures until the button re-renders. |
| Macro shows the cooking pot but I _do_ own the item. | Run `/cm dump pick <catKey>` (e.g. `/cm dump pick FLASK`). The output lists every candidate with its score, owned status, and pick marker. If the item isn't listed, it's blocked or its tooltip hasn't loaded yet — `/cm dump item <id>` shows the parse status. |
| I just looted a better food / flask but the macro didn't update. | Give it a frame — bag updates are debounced. If still nothing, `/cm resync` forces a full rescan. If the change happened in combat, the macro write defers until you leave combat (a hard restriction of the protected macro API). |
| My macro body changed but my action bar didn't. | `/reload`. Some action-bar frameworks cache action-button textures and don't re-query on every macro update. A reload forces a full re-draw. |
| Swapped specs but `KCM_FLASK` / `KCM_CMBT_POT` / `KCM_STAT_FOOD` didn't update. | Run `/cm resync`. Verify the viewed spec on the **Stat Priority** page matches your current spec. |
| `/cm dump item <id>` shows a subType the addon doesn't classify. | Most likely a patch renamed the subtype string. Please file an issue with the `subType` from the dump output. |
| Chat prints "macro body exceeds 255 bytes" once on login. | Blizzard caps macro bodies at 255 characters. The addon falls back to the empty-state stub for that category rather than write a corrupted truncated body. Please report this with the category key. |
| "gave up on `KCM_X` after 3 failed writes". | The macro write is being rejected three times across combat flushes — almost always a Blizzard bug or another addon tainting the macro APIs. Run `/cm debug`, reproduce, and file an issue with the debug log. |
| `/cm reset` or "Reset all priorities" says it didn't work. | Saved variables haven't initialized — reload and try again. Only happens during a failed initial load. |
| I want to restore a seed list (after manually removing items). | **Reset category** on the category's page wipes that category's added / blocked / pinned entries; **Reset all priorities** (General page) wipes everything across all categories. |

## Issues and feature requests

All bugs, feature requests, and outstanding work are tracked at [https://github.com/tusharsaxena/consumablemaster/issues](https://github.com/tusharsaxena/consumablemaster/issues). Please file new reports there rather than as comments — the issue tracker is the single source of truth for the project's backlog.

If you're contributing or validating a build, the manual smoke-test playbook lives at [docs/smoke-tests.md](./docs/smoke-tests.md).

## Version History

| Version | Date | Highlights |
|---------|------|------------|
| 1.4.0 | 2026-05-03 | Settings UI migrated to a KickCD-style canvas with Blizzard sub-categories, breadcrumb chevron, and About landing page; slash UX rebranded to `/cm` with cyan `[CM]` chat prefix; schema-driven `/cm list/get/set` CLI; master enable toggle; Stat Priority auto-tracks the active spec; combat-time panel opens blocked at OnShow; secondary-stat dedupe; comprehensive smoke-test playbook in `docs/smoke-tests.md`. |
| 1.3.0 | 2026-04-25 | Composite macros `KCM_HP_AIO` and `KCM_MP_AIO` that switch sub-category picks by combat state; AIO Health / AIO Mana settings pages with per-side toggle and reorder; empty-side fallback chat notice; `/cm dump pick hp_aio`/`mp_aio`. |
| 1.2.1 | 2026-04-25 | Fixed login Lua error by replacing the removed `LEARNED_SPELL_IN_TAB` event with its modern equivalent. |
| 1.2.0 | 2026-04-24 | Action-bar icons now render on ElvUI, Bartender, and other action-bar addons; new `/cm rewritemacros` command (also Settings → General → Force rewrite macros) for unconditional rewrites; category drag-icon widget shows the picked item/spell texture. |
| 1.1.0 | 2026-04-24 | Correctness pass from PE review: locked items no longer flap macros, scorers are isolated, oversized macro bodies fall back gracefully, combat-deferral retries are bounded; per-recompute score cache; 30-day discovery GC; spell-name hydration without reload; category tab reorder; empty-state fallback icon. |
| 1.0.0 | 2026-04-24 | Initial release: ten account-wide auto-rewriting macros across eight single-pick categories, spell entries in priority lists, item/spell kind selector, custom AceGUI priority rows, per-row score tooltip, consolidated `/cm dump pick` and `dump item`, debounced refreshes with non-bag recompute skip, memoized options tree, ClearTarget taint fix. |