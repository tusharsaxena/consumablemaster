# Ka0s Consumable Master — Requirements

**Addon name:** Ka0s Consumable Master (`ConsumableMaster`)
**Slash prefix:** `/kcm`
**Target client:** World of Warcraft *Midnight* (Retail, Interface 120000+), English locale only.
**Framework:** Ace3 (AceAddon-3.0, AceEvent-3.0, AceDB-3.0, AceConsole-3.0, AceConfig-3.0, AceConfigDialog-3.0, AceConfigRegistry-3.0).
**Inspiration only (no code reuse):** [ConsumableMacro on CurseForge](https://www.curseforge.com/wow/addons/consumablemacro).

---

## 1. Purpose

Maintain a fixed set of **account-wide global macros** whose body is automatically rewritten to point at the *single best* consumable the player currently has in their bags, for each consumable category. A user-facing settings panel (integrated into Blizzard's built-in AddOns settings) allows viewing and editing the per-category priority lists.

This frees the player from rebuilding macros each time they restock, change spec, or progress to better consumables.

---

## 2. Macro Categories

Eight global, account-wide macros are managed by the addon. All names must fit within Blizzard's 16-character macro name limit.

| # | Category              | Macro name      | Spec-aware? | Notes |
|---|-----------------------|-----------------|-------------|-------|
| 1 | Basic / conjured food | `KCM_FOOD`      | No          | Conjured (Mage) and vendor food, ranked dynamically by parsed heal value with a conjured bonus. **No stat food.** |
| 2 | Drink (mana regen)    | `KCM_DRINK`     | No          | Conjured (Mage) and vendor water, ranked dynamically by parsed mana value. |
| 3 | Stat food             | `KCM_STAT_FOOD` | **Yes**     | Best stat food for the active spec. **Excludes feasts** (both personal and ground). |
| 4 | Health potion         | `KCM_HP_POT`    | No          | Standard out-of-combat healing potions (e.g. Silvermoon Health Potion, Amani Extract). Excludes shield/absorb potions. |
| 5 | Mana potion           | `KCM_MP_POT`    | No          | Standard mana-restoration potions (e.g. Lightfused Mana Potion, Refreshing Serum). |
| 6 | Warlock healthstone   | `KCM_HS`        | No          | All healthstone variants (5512, 224464). |
| 7 | Combat potion         | `KCM_CMBT_POT`  | **Yes**     | Best DPS/throughput potion for the active spec. **No utility potions** (no invis, no absorb, no slowfall). |
| 8 | Flask                 | `KCM_FLASK`     | **Yes**     | Best long-duration flask for the active spec. |

**Macro storage:** All eight macros live in the **account-wide** macro pool (Blizzard exposes that pool as indices 1–120, but the addon never hardcodes a slot number). Macros are always identified by their unique `KCM_*` name:
- On every event, the addon resolves a macro by name via `GetMacroIndexByName(name)`.
- If the macro doesn't exist, the addon calls `CreateMacro(name, icon, body, false)` (last arg = `false` → account-wide). WoW assigns whatever free slot is available.
- If the macro exists, the addon calls `EditMacro(name, ...)` to rewrite it in place.
- The addon never deletes a `KCM_*` macro and never reads/writes by slot index. This means user-driven slot reordering, manual placement on action bars, and other addons claiming slots all coexist safely.

**Macro body strategy:** *Single best item.* Each macro body is:
```
#showtooltip
/use item:<itemID>
```
The icon updates automatically because of `#showtooltip`.

**Empty state:** When the player has *zero* matching items for a category, the addon writes a stub body:
```
#showtooltip
/run print("|cffff8800[KCM]|r No <category> in bags.")
```
The macro is never deleted — it always occupies its slot — so other UI bindings keyed to it stay valid.

---

## 3. Update Triggers

The addon recomputes and rewrites all eight macro bodies whenever any of the following events fire:

| Event                       | When |
|-----------------------------|------|
| `PLAYER_ENTERING_WORLD`     | Login, reload, zone-in. Used to seed initial state. |
| `BAG_UPDATE_DELAYED`        | Any bag content change (single coalesced fire after a sequence of `BAG_UPDATE` events). |
| `PLAYER_SPECIALIZATION_CHANGED` | Spec change. Triggers re-evaluation of the three spec-aware categories. |
| `PLAYER_REGEN_ENABLED`      | Combat ended. Flushes any updates that were deferred because the player was in combat. |

**Combat lockdown:** `CreateMacro` / `EditMacro` / `DeleteMacro` are protected and may taint or fail if called during combat. The addon must:
- Check `InCombatLockdown()` before any macro mutation.
- If true, set a "pending update" flag and defer all writes until `PLAYER_REGEN_ENABLED` fires.
- Never mutate macros from within a tainted code path.

---

## 4. Priority / Selection Logic

The selection pipeline has three layers: **(a) candidate set** → **(b) automatic ranking** → **(c) optional user pins**. The ordered list shown in the settings UI and used at selection time is the output of these three layers combined.

### 4.1 Candidate set
Each category has a **candidate set** — the universe of item IDs the addon considers. The candidate set is the union of:
1. The shipped seed list for that category (and spec, where applicable) — see §4.3.
2. Items the user has explicitly added via the settings UI.
3. **Auto-discovered items**: any item currently in the player's bags whose properties match the category's classifier (see §4.5). Auto-discovered items are added to the candidate set automatically, persisted across sessions, and surfaced in the settings UI so the user can confirm/remove them.

Items the user has explicitly removed are kept on a per-category blocklist and never re-added by auto-discovery.

### 4.2 Automatic ranking
For each item in the candidate set, the addon computes a numeric **score** using a category-specific ranking function. The candidate set sorted by score (descending) is the **auto-priority list**. Inputs to every ranking function:

| Signal | Source | Notes |
|--------|--------|-------|
| Item level | `C_Item.GetItemInfo` field 4 | Higher ilvl ≈ newer / stronger consumable. |
| Item quality | `C_Item.GetItemInfo` field 3 | `Enum.ItemQuality.Epic` (4) > Rare (3) > Uncommon (2) > Common (1). |
| Item subType | `C_Item.GetItemInfo` field 7 | Classifies pot/flask/food. |
| Tooltip lines | `C_TooltipInfo.GetItemByID` | Numeric values (heal amount, stat amount, duration), stat names ("Mastery", "Critical Strike"), keywords ("Conjured Item"). |
| Conjured flag | tooltip contains "Conjured Item" | Conjured consumables get a small bonus (always free, infinite supply). |

Per-category ranking rules:

| Category | Primary score | Tie-breakers |
|----------|--------------|--------------|
| `KCM_FOOD` | tooltip "Restores X health" → X | conjured bonus, ilvl, quality |
| `KCM_DRINK` | tooltip "Restores X mana" → X | conjured bonus, ilvl, quality |
| `KCM_STAT_FOOD` | spec stat-priority match (see §4.4) × stat amount parsed from tooltip | ilvl, quality |
| `KCM_HP_POT` | parsed avg heal value (tooltip "Heals X to Y") | ilvl, quality |
| `KCM_MP_POT` | parsed avg mana value | ilvl, quality |
| `KCM_HS` | tooltip parsed heal % | hardcoded: Demonic Healthstone > Healthstone, then ilvl |
| `KCM_CMBT_POT` | spec match (primary-stat pot vs secondary-stat pot, see §4.4) | ilvl, quality |
| `KCM_FLASK` | spec match (parsed stat from tooltip vs spec stat priority) | ilvl, quality, duration |

Caching: tooltip parses are expensive, so each item's parsed properties are cached the first time it's seen and re-parsed only on `GET_ITEM_INFO_RECEIVED` or when the user manually triggers `/kcm resync`.

### 4.3 Spec-aware categories and seed defaults
For `KCM_STAT_FOOD`, `KCM_CMBT_POT`, and `KCM_FLASK`, the candidate set, blocklist, and pin list are stored **per spec** keyed by `(classID, specID)` (numeric, locale-independent). On `PLAYER_SPECIALIZATION_CHANGED` the addon swaps active state to that spec's data.

Defaults are pre-populated on first install for every category and every spec, sourced from public Midnight (12.0) consumable guides. The seed list is intentionally a *set* (unordered) — the auto-ranker computes the order. See `defaults/README.md` for source attribution and last-updated dates.

**Sources used to seed defaults:**
- [Method.gg — List of all Midnight Consumables](https://www.method.gg/guides/list-of-all-midnight-consumables-enchants-and-gems)
- [Method.gg — per-spec stats/consumables guides](https://www.method.gg/guides) (one per spec)
- [Icy Veins — Midnight DPS/Healer/Tank guides](https://www.icy-veins.com/wow/)
- [Wowhead — item pages for ID verification](https://www.wowhead.com/)

### 4.4 Spec stat priority
For spec-aware categories, the addon needs to know each spec's stat preference. A static **stat-priority table** is shipped (see `defaults/Defaults_StatPriority.lua`) keyed by `(classID, specID)`, mapping each spec to:
- A primary stat (`STR` / `AGI` / `INT`) — used to score primary-stat flasks/pots/food.
- An ordered list of secondary stats (`CRIT`, `HASTE`, `MASTERY`, `VERSATILITY`) — used to score secondary-stat consumables. Earlier in the list = higher score multiplier.

The ranking function uses this to pick (e.g.) a Mastery flask over a Versatility flask for a Devourer DH whose priority is `MASTERY > HASTE > CRIT > VERS`. Users can override the stat priority per spec in the settings UI.

### 4.5 User pins (manual override)
The user can **pin** any item in the priority list to a specific position via the settings UI's up/down arrows. Pinned items are placed at their pinned positions first; remaining (unpinned) items fill the rest of the list in auto-ranked order. This lets the user say "I always want item X first regardless of ilvl" without abandoning auto-ranking for everything else. A "Reset to auto" button per category clears all pins.

### 4.6 At selection time
Once the effective priority list (pins + auto-ranked) is built for a category, the selector walks it top-to-bottom and picks the **first item the player has ≥1 of in their bags** (`C_Item.GetItemCount(itemID, false, false, false, false)` — bags only). That item ID is written into the macro body.

### 4.7 Auto-discovery classifier
For each category, a classifier function decides whether a bag item belongs in the candidate set:
- `KCM_FOOD`: subType is "Consumable → Food & Drink" + tooltip "Restores X health" + NOT a stat food (no "Well Fed" / no "Mastery|Crit|Haste|Vers" stat lines).
- `KCM_DRINK`: same but "Restores X mana".
- `KCM_STAT_FOOD`: Food & Drink subType + tooltip contains "Well Fed" or stat keyword.
- `KCM_HP_POT`: subType "Potion" + tooltip "Heals" or "Restores X health".
- `KCM_MP_POT`: subType "Potion" + tooltip "Restores X mana".
- `KCM_HS`: itemID ∈ {5512, 224464, …} (small hardcoded set; healthstones have no reliable tooltip signature).
- `KCM_CMBT_POT`: subType "Potion" + tooltip "for 25 sec" or "for 30 sec" stat-buff pattern.
- `KCM_FLASK`: subType "Flask" or "Phial".

Items that match a classifier but not a hand-curated seed entry are added to the candidate set with a `discovered = true` flag, displayed with a "(auto)" badge in the settings UI so the user can verify or remove them.

---

## 5. Settings Panel

### 5.1 Integration
Registered into Blizzard's built-in **Settings** panel via `AceConfigDialog-3.0` → `Settings.RegisterAddOnCategory`. Accessible under *Game Menu → Options → AddOns → Ka0s Consumable Master*, or via `/kcm config`.

### 5.2 Layout
- **Top-level page**: addon overview, debug toggle, "force resync now" button, version info.
- **One sub-page per category** (8 sub-pages):
  - Heading: category name + current macro body preview + currently-selected item.
  - **Priority list table**: rows in effective priority order (pins first, then auto-ranked). Columns:
    - Position (with up/down arrows — clicking either pins the row at that new index).
    - Pinned indicator (📌 if the user has manually positioned the row, blank otherwise).
    - Item icon.
    - Item name (linkable).
    - Item ID.
    - Auto-rank score (numeric, for transparency into the ranking function).
    - "(auto)" badge if the item was added by auto-discovery.
    - **In-bags indicator**: green dot if present in bags, red dot if absent.
    - Remove button (X) — moves the item to the per-category blocklist.
  - Buttons: **Add item by ID**, **Reset pins to auto**, **Reset blocklist** (re-allows auto-discovered items).
  - For spec-aware categories: a **spec selector dropdown** at the top so the user can view/edit the list for any spec, not just the current one. A second sub-section exposes the spec's stat-priority (primary stat + ordered secondary stats) with override controls.

### 5.3 Persistence
All priority lists, the debug flag, and any user overrides are saved to `ConsumableMasterDB` via AceDB (account-wide profile by default, single profile only — no profile management UI in v1).

---

## 6. Slash Commands

Handled via AceConsole-3.0:

| Command          | Effect |
|------------------|--------|
| `/kcm`           | Prints help text listing all subcommands. |
| `/kcm config`    | Opens the Settings panel to the addon's category. |
| `/kcm debug`     | Toggles debug mode. When on, the addon prints to chat every time it scans bags, picks an item, or rewrites a macro. |
| `/kcm resync`    | Force a re-scan and rewrite of all macros (no-op if in combat — prints a warning). |
| `/kcm reset`     | Reset all priority lists to defaults (asks for confirmation via popup). |

---

## 7. Technical Constraints

- **Interface version**: `120000` (WoW Midnight 12.0+) only. No Classic, no MoP Remix.
- **Locale**: English (`enUS`/`enGB`) only. No localization framework needed.
- **Taint avoidance**:
  - Never mutate macros during combat.
  - Never call macro APIs from within a secure-call callback.
  - All event handling routed through Ace3's untainted dispatch.
- **Macro slots**: 8 account-wide slots consumed (out of 120). On first run, if any of the eight names already exist (created by user manually), the addon adopts those slots; if not, it creates new ones.
- **Macro body length**: Each body is well under 255 chars (single-best strategy).
- **API usage**: Modern namespaced APIs only — `C_Item.*`, `C_Container.*`, `C_TooltipInfo.*`, `Settings.*`. No deprecated globals.

---

## 8. Out of Scope (v1)

- Localization to other languages.
- Per-character macros (everything is account-wide).
- Macro priority per encounter / boss.
- Auto-buying consumables from vendors.
- Cauldron / phial / weapon-oil / augment-rune categories.
- Profile import/export.
- LDB / minimap icon.
- Drag-and-drop reordering (use up/down arrows instead — simpler with AceConfig).
- Shopping list / restock reminder.

---

## 9. File Layout (preview)

Repo root is the addon folder. Design docs live in `docs/`.

```
./
├── ConsumableMaster.toc
├── embeds.xml
├── libs/                         # Ace3 + LibStub, vendored
│   ├── LibStub/
│   ├── AceAddon-3.0/
│   ├── AceEvent-3.0/
│   ├── AceDB-3.0/
│   ├── AceConsole-3.0/
│   ├── AceConfig-3.0/
│   ├── AceConfigDialog-3.0/
│   └── AceConfigRegistry-3.0/
├── Core.lua                      # AceAddon entry, event wiring
├── MacroManager.lua              # Adopts/creates/edits the 9 macros
├── Selector.lua                  # Picks best item from bags given a priority list
├── BagScanner.lua                # Inventory queries
├── SpecHelper.lua                # Class/spec key resolver, spec-change handling
├── Options.lua                   # AceConfig table + Settings registration
├── SlashCommands.lua             # /kcm handler
├── Debug.lua                     # Debug print helpers
├── Ranker.lua                    # Per-category ranking functions
├── Classifier.lua                # Auto-discovery: does this bag item match a category?
├── TooltipCache.lua              # Cached tooltip parses (heal value, stat name, etc.)
└── defaults/
    ├── Categories.lua            # Master list of categories + macro names
    ├── Defaults_StatPriority.lua # (classID, specID) → primary stat + secondary stat order
    ├── Defaults_Food.lua         # Basic/conjured food candidate set
    ├── Defaults_Drink.lua
    ├── Defaults_StatFood.lua     # Candidate set (unordered; ranker orders per spec)
    ├── Defaults_HPPot.lua
    ├── Defaults_MPPot.lua
    ├── Defaults_Healthstone.lua
    ├── Defaults_CombatPot.lua    # Candidate set (unordered)
    ├── Defaults_Flask.lua        # Candidate set (unordered)
    └── README.md                 # Source attribution + last-updated date
```

---

## 10. Acceptance Criteria

The v1 addon is considered complete when:
1. Logging into a fresh character with the addon installed creates the eight `KCM_*` macros in account-wide slots.
2. Each macro body points to a sensible item from the player's bags (or to the empty-state stub).
3. Looting / disenchanting / vendoring / using a consumable triggers a re-scan within ~1 sec of `BAG_UPDATE_DELAYED`.
4. Switching spec swaps the body of `KCM_STAT_FOOD`, `KCM_CMBT_POT`, `KCM_FLASK` to the spec's preferred items if available.
5. Combat-time bag changes are deferred and applied when combat ends; nothing crashes or taints.
6. `/kcm config` opens the Settings panel; all four user actions (add/remove/reorder, spec switch) work and persist across `/reload`.
7. `/kcm debug` toggles verbose logging.
8. The defaults files cite their sources in `defaults/README.md`.

---

## 11. Resolved Decisions

The following were resolved during requirements review:

1. **Feasts**: *Excluded entirely* — neither `KCM_FOOD` (basic) nor `KCM_STAT_FOOD` will include feasts (personal or multi-player). Only single-serving food items.
2. **Conjured / vendor food**: No static "small seed list" approach. The candidate set is built dynamically via the §4.7 classifier (subType + tooltip scan) and ordered by the §4.2 ranker (parsed heal/mana value, ilvl, quality, with a conjured-item bonus). Defaults ship a known-good seed set; auto-discovery handles new items.
3. **`/kcm reset` confirmation**: Blizzard `StaticPopupDialogs` yes/no popup.
4. **Macro adoption**: If a `KCM_*`-named macro pre-exists, the addon adopts it (rewrites body on next event). No renaming of user macros.
5. **Bandages**: *Excluded entirely* — `KCM_BANDAGE` removed from the category list. Bandages are not relevant to current Midnight endgame play.
6. **Spec-aware key**: `(classID, specID)` numeric pair. UI displays human-readable names.
7. **AceDB profile model**: Single account-wide profile in v1. No profile switcher.

All other open items from the original draft are closed. Ready to proceed to TECHNICAL_DESIGN.md.
