# Ka0s Consumable Master

![version](https://img.shields.io/badge/version-1.3.0-blue)
![wow](https://img.shields.io/badge/WoW-Midnight_12.0.5-orange)
![license](https://img.shields.io/badge/license-MIT-green)

![alt text](https://media.forgecdn.net/attachments/1646/103/consumemaster-logo-jpg.jpg)

An auto-managed consumable-macro addon for **World of Warcraft: Midnight**. Keeps a fixed set of account-wide global macros pointed at the single best consumable currently in your bags, for eight categories — so you never rebuild a food / flask / potion macro again.

**Slash prefix:** `/cm` (alias: `/consumablemaster`) **Framework:** Ace3 (AceAddon, AceEvent, AceDB, AceConsole, AceConfig) **Version:** 1.3.0 **Locale:** English only

## What it does

Every time you loot a better food, swap spec, reload, or leave combat, Ka0s Consumable Master re-runs its pipeline and rewrites each macro's body — either `#showtooltip / /use item:<best>` for items or `#showtooltip / /cast <spell>` for spell entries (class abilities like Recuperate). The macros live in the **account-wide** pool (identified by name — the addon never hardcodes a slot), so they're shared across every character, survive slot reordering, and coexist with every other macro in your list.

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

Macro writes that would land during combat are queued and flushed on `PLAYER_REGEN_ENABLED` — the addon never calls a protected macro API in combat.

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

1.  Install the addon using the Addon Manager of choice, or manually
2.  Launch the game. The addon initializes on login — first `PLAYER_ENTERING_WORLD` scans bags, discovers known items, and writes all eight macros.
3.  Drag the new `KCM_*` macros onto your action bars from the macro UI (or use the draggable icon at the top of each category page in the settings panel).

All settings live at **Escape → Options → AddOns → Consumable Master** (or `/cm config`).

## Slash commands

`/cm` is the short form; `/consumablemaster` is a long-form alias that accepts the same subcommands. Every chat line the addon emits — slash output, in-combat notices, the empty-state stub fired when a macro has no usable pick — is prefixed with a cyan `[CM]` tag for easy filtering.

| Command            |What it does                                                                                                                 |
| ------------------ |---------------------------------------------------------------------------------------------------------------------------- |
| <code>/cm</code>  |Show help.                                                                                                                   |
| <code>/cm config</code> |Open the settings panel (priority lists, spec selector, add-by-ID).                                                          |
| <code>/cm resync</code> |Force a full rescan: invalidate tooltip cache, re-discover, recompute picks (macros are re-issued only if the pick changes). |
| <code>/cm rewritemacros</code> |Force an unconditional rewrite of every KCM macro body + stored icon. Use when an action-bar icon looks stale.               |
| <code>/cm reset</code> |Confirm-and-reset every priority list and stat override to defaults.                                                         |
| <code>/cm debug</code> |Toggle verbose logging.                                                                                                      |
| <code>/cm version</code> |Print the addon version.                                                                                                     |
| <code>/cm dump &lt;target&gt;</code> |Inspect internal state. Targets: <code>categories</code>, <code>statpriority</code>, <code>bags</code>, <code>item &lt;id&gt;</code>, <code>pick &lt;catKey&gt;</code>. |

### General

*   **Debug mode** — toggle verbose chat logging. Equivalent to `/cm debug`.
*   **Force resync** — invalidate the tooltip cache, re-run auto-discovery against your bags, and recompute every category's pick. Macros are re-issued only when the pick or body actually changes. Equivalent to `/cm resync`. Blocked in combat.
*   **Force rewrite macros** — unconditionally re-issue every `KCM_*` macro (body + stored icon), bypassing the "unchanged" cache. Use when an action-bar icon looks stale (e.g. ElvUI held the previous static texture across an upgrade). Equivalent to `/cm rewritemacros`. Blocked in combat. A `/reload` afterwards guarantees the action-bar framework re-queries every button.
*   **Reset all priorities** — with confirmation, wipe every added / blocked / pinned entry and every stat-priority override. Seed defaults are restored.

### Stat Priority

One shared page that drives the three spec-aware categories (Stat Food, Combat Potion, Flask).

*   **Viewing spec** — selects which spec's stat priority you're editing. Also controls which spec's list shows on the three spec-aware category pages. Specs render with their class icon and human-readable name (e.g. "Shaman — Enhancement"), not raw class/spec IDs.
*   **Primary stat** — the dominant stat for the spec. Primary-stat consumables always beat secondary-stat ones regardless of magnitude.
*   **Secondary stat #1 … #4** — ordered preference for secondary stats (Crit / Haste / Mastery / Versatility). Position 1 weighs most. Leave slots as `(none)` to truncate the list — a truncated list ranks unlisted secondaries at 0.
*   **Reset stat priority** — drop the user override for the viewed spec. Ranker falls back to the seed default (`defaults/Defaults_StatPriority.lua`) or, if none exists, the class-primary fallback.

### Per-category pages

Each of the eight categories has its own page in the tab list. Spec-aware pages also show the viewed spec at the top.

*   **Draggable macro icon** — the small icon below the title. Drag it onto an action bar to place the `KCM_*` macro.
*   **Add item or spell by ID**
    *   **Type** dropdown — choose `Item` or `Spell`.
    *   **ID** input — validates against `C_Item.GetItemInfoInstant` (items) or `C_Spell.GetSpellName` (spells). On submit a confirmation dialog shows the resolved name before committing.
*   **Priority list** — one row per candidate, ordered by effective rank:
    *   Status glyphs: ready-check green (owned in bags / spell known), red (not owned), yellow star (currently picked by the macro).
    *   **Blue info button** — hover for the per-item score breakdown.
    *   **↑ / ↓** — reorder (writes a pin, overrides the Ranker score).
    *   **×** — remove the entry. Also blocks it so auto-discovery won't re-add it.
*   **Reset category** — with confirmation, clears this category's added / blocked / pinned entries (the viewed spec's bucket only, for spec-aware categories). Discovered items (from bag scans) are preserved.

## How picking & ranking works

Every recompute runs this pipeline per category:

1.  **Build the candidate set.** Union of three sources, minus the blocklist:
    *   `seed` — the shipped `defaults/Defaults_<CAT>.lua` list. Most entries are itemIDs, but a seed can also include spell entries (Recuperate is top-ranked in Food by default).
    *   `added` — items or spells you manually added via the settings panel.
    *   `discovered` — items auto-scanned from your bags that match the category's classifier rules (bag discovery is item-only; spells are never auto-discovered).
    *   `blocked` — entries you've removed with the × button. Subtracted from the union; auto-discovery won't re-add a blocked item.
2.  **Score every candidate.** A per-category scorer (`Ranker.lua`) reads the parsed tooltip and returns a number; higher is better. Signals per category:
    *   **Food / Drink:** flat heal/mana value + %-based restore (amplified so Midnight %-based food outranks flat tiers) + conjured bonus + ilvl + quality tiebreak.
    *   **HP potion / MP potion:** raw heal/mana value. **Immediate restores always outrank heal-over-time (HOT) pots, unless the HOT's amount beats the best immediate in the set by more than 20%.** Prevents a slightly-bigger HOT from winning over a smaller immediate (e.g. Amani Extract's 265,420 over 20 sec vs Silvermoon Health Potion's 241,303 instant — Silvermoon wins because the HOT isn't 20% bigger).
    *   **Stat Food / Combat Potion / Flask:** weighted sum of the tooltip's stat buffs against the active spec's stat priority. Primary-stat consumables always beat any secondary-stat ones; within secondary, earlier positions weigh more. Wildcard "highest secondary stat" buffs resolve against the spec's top secondary at rank time.
    *   **Healthstone:** hard-coded preference table (modern auto-leveling Healthstone > legacy fallback), + ilvl tiebreak.
    *   **Spell entries:** a fixed score that outranks every item. Spells never compete with items on value — so Recuperate sits above every food by default. You can pin items above a spell if you prefer.
3.  **Merge pins.** When you reorder rows with ↑ / ↓ in the settings panel, the addon writes pins of `{itemID, position}`. Pins override the Ranker order — pinned entries land at their requested position and non-pinned items fill the gaps in score order.
4.  **Walk the final list** for the first entry you actually own. Items check bag counts; spells check `IsPlayerSpell` (class / spec / talent-granted). That first-owned entry becomes the macro body. If you own none, the macro prints a friendly cyan `[CM] no <category>` stub so the slot stays valid.

Hovering the **blue info button** on any row shows the full per-item score breakdown (each contributing signal and a one-line summary of the scoring rule), so you can see exactly why an entry landed where it did.

## FAQ

**Will this delete or overwrite my existing macros?**

No. The eight `KCM_*` macros are identified by **name**, never by slot, and the addon only ever touches macros it owns. Your custom macros — including anything already sitting in slots 1–120 of the account-wide pool — are never read, moved, or deleted. If you delete a `KCM_*` macro by hand, the next pipeline run recreates it (as long as there's a free account-wide slot).

**Do the macros work across all my characters?**

Yes — they're written to the **account-wide** macro pool (slots 1–120), not the per-character pool. One set of eight macros is shared across every character on the account. Priority lists, added/blocked entries, and stat-priority overrides live in `SavedVariables` (`ConsumableMasterDB`) with a single profile by default, so every character sees the same settings.

**Why are some categories per-spec and others aren't?**

Flask, Combat Potion, and Stat Food are **spec-aware** because their value depends on your stat priority (primary stat + secondary order). Food, Drink, HP Potion, MP Potion, and Healthstone rank the same regardless of spec, so they share one priority list across all specs of a character.

**How do I add an item or spell the addon doesn't already know about?**

Open the category's page in **Settings → AddOns → Consumable Master**, use the **Add item or spell by ID** input at the top. Items validate against `C_Item.GetItemInfoInstant`; spells validate against `C_Spell.GetSpellName`. A confirmation dialog shows the resolved name before it commits.

**How do I force a specific item to always win over the Ranker?**

On that category's page, use the **↑ / ↓** buttons to move it to the position you want. The addon stores that as a **pin** — pinned entries override the Ranker's score and land at their chosen position; everything else fills the gaps in natural order.

**How do I permanently remove an item?**

Use the **×** button on its row. That blocks the item, so auto-discovery won't re-add it even if you loot another copy. Use **Reset category** (or **Reset all priorities** in General) to clear the blocklist again.

**Does it work with ElvUI / Bartender / other action-bar addons?**

Yes. The `KCM_*` macros are plain Blizzard macros and can be dragged onto any action bar. If the picked item's icon doesn't show on the bar (you see the cooking-pot fallback instead), see the Troubleshooting entry below — the v1.2.0 fix addresses this, but a one-time **Force rewrite macros** + `/reload` is sometimes needed on upgrade.

**Can I use this in a non-English client?**

No — **English only**. Classifier compares item subtypes against literal English strings (`"Potions"`, `"Flasks & Phials"`, etc.) and tooltip parsing uses English patterns. Localization is explicitly out of scope.

**Will new patch flasks / potions work automatically?**

Usually yes — auto-discovery scans your bags and classifies anything that matches by type / subType / tooltip patterns, so a freshly-looted new-tier flask joins the candidate set on the next bag update. If a patch **renames** a subtype string or reformats tooltip numbers, pattern updates in `Classifier.lua` / `TooltipCache.lua` may be needed — please file an issue.

**Why does a smaller-instant HP potion beat a bigger heal-over-time potion?**

By design. Immediate restores always outrank HOT pots unless the HOT's total is **more than 20% larger** than the best immediate in the same candidate set. Immediate value is usually what you want in an emergency; a small HOT edge isn't worth giving up the burst. You can override this by pinning the HOT above the immediate.

## Troubleshooting

**My action bar shows the cooking-pot icon instead of the picked item's icon.**

Run **Settings → General → Force rewrite macros** (or `/cm rewritemacros`) and then `/reload`. If you're upgrading from v1.1.0, the first pipeline run auto-migrates each macro's stored icon to the `?` sentinel, but some action-bar frameworks (notably ElvUI and Bartender) cache the texture until the button is re-rendered — `/reload` forces a refresh.

**The macro shows the cooking pot but I _do_ own the item.**

Run `/cm dump pick <catKey>` (e.g. `/cm dump pick FLASK`). The output lists every candidate with its score, an `[owned]` tag if it's in your bags, and the `<-- pick` marker on the winner. If the item doesn't appear in the list at all, it's either blocked (remove it with × from another category, or Reset category) or its tooltip hasn't hydrated yet (`/cm dump item <itemID>` shows the parsed fields — if `pending: tooltip data not yet loaded` appears, wait a second and retry).

**I just looted a better food / flask but the macro didn't update.**

The pipeline is debounced on `BAG_UPDATE_DELAYED`; give it a frame. If still nothing, `/cm resync` forces a full rescan. If the pick was made in combat, the macro write is deferred until you leave combat (`PLAYER_REGEN_ENABLED`) — that's a hard restriction of the protected macro API, not a bug.

**My macro body changed but my action bar didn't.**

`/reload`. Some action-bar frameworks (ElvUI, Bartender) cache `GetActionTexture` results and don't re-query on every `UPDATE_MACROS`. A reload is the simplest way to force a full re-draw.

**I swapped specs but `KCM_FLASK` / `KCM_CMBT_POT` / `KCM_STAT_FOOD` didn't update.**

Spec-aware categories recompute on `PLAYER_SPECIALIZATION_CHANGED`. If that event didn't fire (rare — typically a Blizzard bug), `/cm resync` will pick up the new spec's stat priority. Verify the viewed spec on the **Stat Priority** page matches your current spec.

**`/cm dump item <id>` shows a subType the addon doesn't classify.**

Most likely Midnight renamed the subtype string. The matcher strings live in `Classifier.lua` (`ST_*` constants). Please file an issue with the `subType` from the dump output.

**Chat prints "macro body exceeds 255 bytes" once on login.**

Blizzard caps every macro body at 255 characters. The addon falls back to the empty-state stub for that category rather than write a truncated body (which would corrupt the `/use` line). Please report this with the category key — an oversized active body usually means a spell name is unexpectedly long, or a seed composition is wrong.

**I hit "gave up on `KCM_X` after 3 failed writes".**

The macro's `EditMacro` call is being rejected three times across combat flushes. This is almost always a Blizzard bug or another addon tainting the macro APIs. Run `/cm debug`, reproduce, and file an issue with the debug log — the raw `EditMacro` return value is captured there.

**`/cm reset` or "Reset all priorities" says it didn't work.**

Both paths route through `KCM.ResetAllToDefaults` in `Core.lua`. If the function returns false, `KCM.db` / `KCM.db.profile` isn't ready — reload and try again. This should only happen during a failed initial load.

**I want to restore a seed list that a patch shipped (after removing items manually).**

"Reset category" on that category's page wipes your added / blocked / pinned entries for that category. "Reset all priorities" (General page) wipes everything and restores every seed, including stat priorities and spec overrides.

## Bug Reports

Please report any issues in the [Issues](https://github.com/tusharsaxena/consumablemaster/issues) tab, not as a comment!

## Version History

**1.3.0**

*   Two new "all-in-one" macros: `KCM_HP_AIO` and `KCM_MP_AIO`. `KCM_HP_AIO` runs `/castsequence reset=combat` over Healthstone then Healing Potion in combat and fires the Food pick out of combat — driven by `[combat]` / `[nocombat]` macro conditionals so one button covers the full heal rotation. `KCM_MP_AIO` does the equivalent for Mana Potion / Drink. Picks come from the existing single-category pipeline; whatever the standalone `KCM_FOOD` macro is currently picking is what the AIO uses out of combat.
*   New **AIO Health** and **AIO Mana** settings panels (after Stat Food). Each panel has _In Combat_ and _Out of Combat_ sections; sub-categories are locked to their section but can be toggled on/off and reordered within it. Each row is a single line — `KCMItemRow` preview on the left, `Enabled` toggle and ↑/↓ reorder on the right. When a sub-category has no current pick the row falls back to the sub-category's display name (so a row stays identifiable even when the underlying macro is empty). The page sub-header explicitly notes that ranking lives on each individual category's panel, not here.
*   Sub-category steps with no current pick (e.g. no Healthstone in bags) drop out of the macro body so `/castsequence` doesn't jam on an unusable step. If one combat-state side ends up entirely empty (e.g. all out-of-combat sub-categories disabled) but the other still has picks, the macro emits a Lua-conditional `/run` line that prints `[CM] no AIO Health option out of combat` (or the equivalent in-combat variant) when clicked from the empty side — same chat-print behaviour the single-category macros use as their empty-state stub. If both sides end up empty, the macro falls back to the regular empty-state body and the cooking-pot icon.
*   `/cm dump pick hp_aio` / `/cm dump pick mp_aio` print the configured order, per-sub-cat pick, and the resulting macro body (including the per-section fallback line when present).

**1.2.1**

*   Fix Lua error on login: the `LEARNED_SPELL_IN_TAB` event was removed in retail and registering it threw `Attempt to register unknown event` from AceEvent. Switched to its modern replacement `LEARNED_SPELL_IN_SKILL_LINE`; spell-name hydration on level-up still works without a reload.

**1.2.0**

*   Action-bar icon fix: active macros now store the `?` sentinel icon (fileID `134400`) so `#showtooltip` can drive the action-bar button — the picked flask / potion / food icon finally renders on ElvUI, Bartender, and any other `GetActionTexture`\-based bar. Empty-state macros continue to store the cooking-pot fallback (no `#showtooltip` in the body). Existing installs migrate automatically on the first pipeline run after upgrade: the new `lastIcon` field in `macroState` mismatches, which triggers one `EditMacro` per category. If a bar still shows a stale icon, `/reload` or use the new Force rewrite macros button.
*   New command **`/cm rewritemacros`** (also available as **Settings → General → Force rewrite macros**) — clears the cached body/icon fingerprints in `macroState` plus the combat-deferral queue, then re-runs the pipeline so every macro is re-issued unconditionally. Use this when the "Force resync" path skips a write because the body hasn't changed but you still want a fresh `EditMacro` call.
*   Options-panel drag widget: the small icon above each category page now renders the picked item's / spell's texture directly (via `C_Item.GetItemIconByID` / `C_Spell.GetSpellTexture`), since the stored macro icon is now the meaningless `?` sentinel for active macros. Empty-state categories still show the cooking pot.
*   Force resync tooltip clarified — it invalidates the tooltip cache, re-runs auto-discovery, and recomputes picks, but re-issues macros only when the body or pick changes. For an unconditional rewrite, use Force rewrite macros.

**1.1.0**

*   Correctness: locked items (stack-split, mail) no longer trigger a macro flap; one bad category scorer can no longer break the other seven (per-category `pcall` in Recompute); oversized macro bodies fall back to the empty-state stub with a one-shot chat error instead of silently truncating; combat deferrals retry up to three times before giving up, with a chat notice.
*   Performance: a per-Recompute score cache memoizes `GetItemInfo`, tooltip parses, and per-category Ranker scores so a flurry of bag events doesn't re-score the same candidate set eight times over.
*   Discovery GC: `discovered` entries are stamped with a unix timestamp; a PEW-time sweep deletes items not seen in bags for 30 days so the set can't grow unbounded across account-lifetime play.
*   Spell hydration: `LEARNED_SPELL_IN_SKILL_LINE` now triggers a recompute so a just-learned spell entry (e.g. Recuperate on level-up) adopts its macro body without a reload.
*   UX: category tabs reordered to Food → Drink → Healing Potion → Mana Potion → Healthstone → Flask → Combat Potion → Stat Food. Empty-state macros now show a cooking-pot fallback icon instead of the question mark.

**1.0.0**

*   Initial Release … yay!