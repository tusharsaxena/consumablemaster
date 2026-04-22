# ConsumableMaster Research Document

Comprehensive research into the WoW "ConsumableMacro" addon concept, WoW API functions,
Midnight (12.x) API changes, consumable items, and macro system details.

---

## 1. ConsumableMacro Addon -- Conceptual Overview

**Source**: [ConsumableMacro on CurseForge](https://www.curseforge.com/wow/addons/consumablemacro)

The ConsumableMacro addon automatically creates and manages in-game macros for
consumable items (flasks and combat potions) based on what the player currently
has in their bags.

### Core Concept
- The addon maintains **priority lists** for different consumable categories
  (e.g., flasks, combat potions).
- When the player's bag contents change, the addon **automatically rewrites**
  the macro body to reference whichever highest-priority consumable the player
  actually possesses.
- This saves the player from manually editing macros every time they acquire
  different consumables.

### Key Features
- **Separate priority lists** for flasks and combat potions, fully customizable.
- **Manual item addition** by Item ID (IDs found on wowhead.com URLs).
- **Drag-and-drop ordering** with +/- buttons; remove items with X.
- **Visual indicators**: green bar = item in bags, red bar = item missing.
- **Automatic macro updates** on bag content changes (can be toggled off).
- **Combat lockout**: addon disables macro editing during combat (required by
  Blizzard's secure action restrictions / taint protection).
- **Localized** in German and English.
- Last updated: April 12, 2026.

### How It Works Conceptually
1. Player configures a priority list of consumable item IDs for each category.
2. Addon listens for bag update events (BAG_UPDATE_DELAYED).
3. When bags change, addon scans bags for items matching the priority list.
4. Addon finds the highest-priority item the player actually has.
5. Addon calls EditMacro() to rewrite the macro body with `/use item:XXXXX`
   pointing to the best available consumable.
6. All of this is blocked during combat via InCombatLockdown() checks.

---

## 2. Relevant WoW API Functions

### 2.1 Macro Management API

#### CreateMacro
```
macroId = CreateMacro(name, iconFileID [, body, perCharacter])
```
- **name** (string): Macro display name. UI imposes 16-character limit.
- **iconFileID** (number|string): FileID or texture path for the icon.
- **body** (string, optional): Macro commands. **Truncated at 255 characters**.
- **perCharacter** (boolean, optional): true = character-specific; nil = account-wide.
- **Returns**: macroId (number) -- 1-based index of the new macro.
- **Restriction**: Cannot be called in combat (protected since patch 2.0.1).
- **Limits**: Max 120 account-wide macros, max 18 per-character macros.
- Duplicate names allowed but cause undefined behavior in name-based lookups.

#### EditMacro
```
macroID = EditMacro(macroInfo [, name, icon, body])
```
- **macroInfo** (number|string): Index (1-120 account, 121-138 character) or name.
- **name** (string?): New name, or nil to keep existing.
- **icon** (number|string?): New icon FileID, or nil to keep existing.
- **body** (string?): New macro text. **First 255 characters saved only**.
- **Returns**: macroID (number) -- may differ from input if name changes (alphabetical sort).
- **Restriction**: Cannot be called in combat (#nocombat).
- **Note**: If called from within the macro being edited, the rest of that macro
  execution uses the NEW body text.

#### DeleteMacro
```
DeleteMacro(indexOrName)
```
- **indexOrName** (number|string): Index (1-120 account, 121-138 character) or name.
- **Restriction**: Cannot be called in combat.

#### GetMacroInfo
```
name, icon, body = GetMacroInfo(macro)
```
- **macro** (number|string): Slot index (1-120 general, 121-138 per-character) or name.
- **Returns**: name (string), icon (fileID), body (string).

#### GetNumMacros
```
global, perChar = GetNumMacros()
```
- **Returns**: global (number) = count of account-wide macros,
  perChar (number) = count of character-specific macros.

#### Macro Slot Constants
- **MAX_ACCOUNT_MACROS** = 120 (increased from 36 in Patch 6.0.3)
- **MAX_CHARACTER_MACROS** = 18
- Total possible: 138 macros per character (120 shared + 18 character-specific)
- Account-wide slots: indices 1-120
- Per-character slots: indices 121-138 (some docs say up to 150; EditMacro docs say 121-150)

---

### 2.2 Bag/Inventory Events and API

#### Events

**BAG_UPDATE**
- Fires whenever a bag's inventory changes.
- **Payload**: bagID (number) -- the ID of the affected bag.
- Fires multiple times when moving items (once per source/destination bag).
- **Warning**: API calls during this event may return unreliable data.
  `C_Item.GetItemCount()` may not reflect the change that triggered the event.
- Added: Patch 1.0.0.

**BAG_UPDATE_DELAYED**
- Fires AFTER all applicable BAG_UPDATE events for a single action have completed.
- **Payload**: None.
- **This is the recommended event** for addons that need reliable post-change data.
- Added: Patch 5.0.4.
- Available in: Midnight, Classic, etc.

**UNIT_INVENTORY_CHANGED**
- Alternative event for inventory change detection.

#### Container Functions

**C_Container.GetContainerItemInfo**
```
containerInfo = C_Container.GetContainerItemInfo(containerIndex, slotIndex)
```
- Returns nil if slot is empty.
- **containerInfo table fields**:
  - iconFileID (number)
  - stackCount (number)
  - isLocked (boolean)
  - quality (Enum.ItemQuality?)
  - isReadable (boolean)
  - hasLoot (boolean)
  - hyperlink (string)
  - isFiltered (boolean)
  - hasNoValue (boolean)
  - itemID (number)
  - isBound (boolean)
- Namespaced from GetContainerItemInfo in Patch 10.0.2.

**C_Container.GetContainerNumSlots**
```
numSlots = C_Container.GetContainerNumSlots(containerIndex)
```
- Returns number of slots in the specified bag.
- Bag indices: 0 = backpack, 1-4 = equipped bags.

**Bag Scanning Pattern**:
```
for bag = 0, 4 do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then
            -- info.itemID, info.stackCount, etc.
        end
    end
end
```

---

### 2.3 Item Information API

#### C_Item.GetItemInfo (Modern -- Patch 10.2.6+)
```
itemName, itemLink, itemQuality, itemLevel, itemMinLevel, itemType,
itemSubType, itemStackCount, itemEquipLoc, itemTexture, sellPrice,
classID, subclassID, bindType, expansionID, setID, isCraftingReagent,
itemDescription = C_Item.GetItemInfo(itemInfo)
```
- **itemInfo** (number|string): Item ID, link, or localized name.
- Returns 18 values (itemDescription added in Patch 12.0.0).
- **Replaces deprecated** `GetItemInfo()` (deprecated in Patch 10.2.6).

#### C_Item.GetItemCount (Modern -- Patch 10.2.6+)
```
count = C_Item.GetItemCount(itemInfo [, includeBank, includeUses, includeReagentBank, includeAccountBank])
```
- **itemInfo** (number|string): Item ID, link, or name.
- **includeBank** (boolean?): Include bank contents.
- **includeUses** (boolean?): Count charges instead of stacks.
- **includeReagentBank** (boolean?): Include reagent bank.
- **includeAccountBank** (boolean?): Include warband/account bank (added Patch 11.0.0).
- **Returns**: count (number).
- **Replaces deprecated** `GetItemCount()`.

#### Legacy Functions (Still functional but deprecated)
- `GetItemInfo(itemInfo)` -- deprecated 10.2.6, unclear removal timeline.
- `GetItemCount(itemInfo, ...)` -- deprecated 10.2.6.

---

### 2.4 Tooltip Scanning

#### Modern Approach: C_TooltipInfo (Patch 10.0.2+)
```
data = C_TooltipInfo.GetHyperlink(hyperlink [, optionalArg1, optionalArg2, hideVendorPrice])
```
- Returns a **TooltipData** table:
  - type (Enum.TooltipDataType): 0=Item, 1=Spell, 2=Unit, etc.
  - id (number)
  - dataInstanceID (number)
  - lines (array of TooltipDataLine):
    - type (Enum.TooltipDataLineType)
    - leftText (string)
    - leftColor (ColorMixin)
    - rightText (string, optional)
    - rightColor (ColorMixin, optional)
  - Item-specific: hyperlink, guid, hasDynamicData, etc.

#### Legacy Approach: Hidden GameTooltip Scanning
- Create a hidden GameTooltip frame with ANCHOR_NONE.
- Call methods like:
  - `tooltip:SetBagItem(bag, slot)`
  - `tooltip:SetHyperlink(itemLink)`
- Read text lines via `_G[tooltipName.."TextLeft"..i]:GetText()`.
- **Deprecated pattern** -- C_TooltipInfo is the modern replacement.

#### Other C_TooltipInfo Functions
- `C_TooltipInfo.GetBagItem(containerIndex, slotIndex)`
- `C_TooltipInfo.GetItemByID(itemID)`
- `C_TooltipInfo.GetInventoryItem(unit, slot)`

---

### 2.5 Settings/Options Panel API

#### Modern Settings API (Patch 10.0.0+, breaking changes in 11.0.2)

**Creating a settings category**:
```
-- Method 1: Canvas layout (custom frame)
local category = Settings.RegisterCanvasLayoutCategory(frame, "AddonName")

-- Method 2: Vertical layout (auto-arranged controls)
local category = Settings.RegisterVerticalLayoutCategory("AddonName")

-- Method 3: Simple category
local category = Settings.CreateCategory("AddonName")
```

**Registering the category**:
```
Settings.RegisterAddOnCategory(category)
```

**Registering individual settings (Patch 11.0.2 signature)**:
```
Settings.RegisterAddOnSetting(
    categoryTbl,    -- the category object
    variable,       -- unique setting ID string
    variableKey,    -- key in the variableTbl (NEW in 11.0.2)
    variableTbl,    -- table for direct read/write, typically SavedVariables (NEW in 11.0.2)
    variableType,   -- Settings.VarType enum
    name,           -- display name
    defaultValue    -- default value
)
```

**Proxy settings (custom getter/setter)**:
```
Settings.RegisterProxySetting(
    categoryTbl, variable, variableType, name, defaultValue,
    getValue,    -- function() return currentValue end
    setValue     -- function(value) save(value) end
)
```
- Callable from insecure code as of Patch 11.0.2.

**Opening settings**:
```
Settings.OpenToCategory(categoryID)
```
- Supports opening directly to subcategories (Patch 11.0.2+).

**Change callbacks**:
```
setting:SetValueChangedCallback(function(setting, value)
    -- react to setting change
end)
```

#### Legacy (removed)
- `InterfaceOptions_AddCategory(frame)` -- removed in Patch 10.0.0.
- `InterfaceOptionsFrame_OpenToCategory(name)` -- removed in Patch 10.0.0.

---

## 3. WoW Midnight (12.x) API Changes

Source: [Patch 12.0.0 Planned API Changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/Planned_API_changes)

### 3.1 Major Paradigm Shift: Secret Values

Patch 12.0.0 introduces a "Secret Values" system that fundamentally changes how
addons interact with combat data:
- Tainted (insecure) code receives values in opaque "black boxes" that cannot be
  inspected, compared, or manipulated.
- Untainted (secure) code retains full access.
- Purpose: prevent addons from making optimal combat decisions automatically.

### 3.2 Macro API Changes
- **Macrotext limited to 255 characters** (matching real macros; confirmed in 11.0.2).
- **Macro chaining removed**: One macro can no longer `/click` a button that
  executes another macro. This is a significant restriction.
- No new macro management functions added in 12.0.0.
- CreateMacro/EditMacro/DeleteMacro remain functional with same signatures.

### 3.3 Bag/Inventory API
- **No specific breaking changes** documented for C_Container functions in 12.0.0.
- BAG_UPDATE and BAG_UPDATE_DELAYED events remain unchanged.
- C_Container.GetContainerItemInfo continues to work with the same table structure.

### 3.4 Settings API
- No additional breaking changes beyond those in 11.0.2.
- The 11.0.2 changes (RegisterAddOnSetting signature, RegisterProxySetting from
  insecure code) remain the current API.

### 3.5 Item Info API
- `C_Item.GetItemInfo` gains an 18th return value: **itemDescription** (string)
  in Patch 12.0.0.
- C_Item.GetItemCount unchanged.
- Old global GetItemInfo/GetItemCount remain deprecated but functional.

### 3.6 Spell/Action API Changes (relevant context)
- New C_Spell namespace functions for cooldowns and display counts.
- Many unit/spell/aura APIs now return "secret" values in combat/instances.
- Combat Log Events **removed** from addon access entirely.

### 3.7 Interface Version
- **Forced matching**: Addons without `## Interface: 120000` or higher will NOT
  load in 12.0.0+ builds. No player override available.

### 3.8 String/Formatting
- `string.format()`, `string.concat()`, `string.join()` now work with secret values.
- New `C_StringUtil` functions for conditional formatting.

---

## 4. WoW Midnight Consumable Items

Sources:
- [Method.gg Midnight Consumables Guide](https://www.method.gg/guides/list-of-all-midnight-consumables-enchants-and-gems)
- [BoostRoom Midnight Consumables](https://boostroom.com/blog/best-consumables-in-wow-midnight-flasks-food-runes-potions)

### 4.1 Food -- Stat Food (Main Stat)

| Item Name                      | Item ID |
|-------------------------------|---------|
| Royal Roast                    | 242275  |
| Impossibly Royal Roast         | 255847  |
| Twilight Angler's Medley       | 242288  |
| Spellfire Filet                | 242289  |
| Mana-Infused Stew              | 242303  |
| Bloom Skewers                  | 242302  |

### 4.2 Food -- Secondary Stat Food

| Item Name                      | Item ID | Stat           |
|-------------------------------|---------|----------------|
| Warped Wise Wings              | 242285  | Mastery        |
| Void-Kissed Fish Rolls         | 242284  | Versatility    |
| Sun-Seared Lumifin             | 242283  | Critical Strike|
| Null And Void Plate            | 242282  | Haste          |
| Glitter Skewers                | 242281  | Mastery        |
| Fel-Kissed Filet               | 242286  | Haste          |
| Buttered Root Crab             | 242280  | Versatility    |
| Arcano Cutlets                 | 242287  | Critical Strike|
| Tasty Smoked Tetra             | 242278  | Critical Strike|
| Crimson Calamari               | 242277  | Haste          |
| Braised Blood Hunter           | 242276  | Versatility    |

### 4.3 Food -- Combination Stat Food (Two Secondary Stats)

| Item Name                        | Item ID | Stats                      |
|---------------------------------|---------|----------------------------|
| Sunwell Delight                  | 242293  | Versatility & Haste        |
| Hearthflame Supper               | 242295  | Critical Strike & Haste    |
| Fried Bloomtail                  | 242291  | Mastery & Versatility      |
| Felberry Figs                    | 242294  | Versatility                |
| Eversong Pudding                 | 242292  | Mastery & Critical Strike  |
| Bloodthistle-Wrapped Cutlets     | 242296  | Mastery & Haste            |
| Wise Tails                       | 242290  | Critical Strike & Versatility|
| Spiced Biscuits                  | 242304  | Critical Strike & Versatility|
| Silvermoon Standard              | 242305  | Mastery & Versatility      |
| Quick Sandwich                   | 242307  | Versatility & Haste        |
| Portable Snack                   | 242308  | Critical Strike & Haste    |
| Forager's Medley                 | 242306  | Mastery & Critical Strike  |
| Farstrider Rations               | 242309  | Mastery & Haste            |

### 4.4 Food -- Feasts (Multi-player / Best-stat)

| Item Name                | Item ID |
|-------------------------|---------|
| Silvermoon Parade        | 255845  |
| Harandar Celebration     | 255846  |
| Quel'dorei Medley        | 242272  |
| Blooming Feast           | 242273  |
| Flora Frenzy             | 255848  |
| Champion's Bento         | 242274  |

### 4.5 Flasks (Long-Duration Stat Buffs)

| Item Name                          | Item ID | Stat           |
|-----------------------------------|---------|----------------|
| Flask Of Thalassian Resistance     | 241321  | Versatility    |
| Flask Of The Blood Knights         | 241324  | Haste          |
| Flask Of The Magisters             | 241322  | Mastery        |
| Flask Of The Shattered Sun         | 241326  | Critical Strike|
| Vicious Thalassian Flask Of Honor  | 241334  | PvP Honor      |

### 4.6 Phials (Profession/Crafting Stat Buffs)

| Item Name                        | Item ID |
|---------------------------------|---------|
| Haranir Phial Of Perception      | 241316  |
| Haranir Phial Of Ingenuity       | 241312  |
| Haranir Phial Of Finesse         | 241310  |

### 4.7 Combat Potions (Short-Duration, Used in Combat)

| Item Name                   | Item ID | Effect                          |
|----------------------------|---------|----------------------------------|
| Light's Potential           | 241308  | Primary Stat boost               |
| Potion Of Recklessness      | 241292  | Secondary Stat adjustment        |
| Potion Of Zealotry          | 241296  | Holy damage effect               |
| Draught Of Rampant Abandon  | 241292  | Primary Stat + void zone effect  |

### 4.8 Healing Potions

| Item Name                | Item ID |
|-------------------------|---------|
| Silvermoon Health Potion | 241304  |
| Amani Extract            | 241298  |

### 4.9 Mana Potions

| Item Name                  | Item ID |
|---------------------------|---------|
| Lightfused Mana Potion     | 241300  |
| Potion Of Devoured Dreams  | 241294  |
| Refreshing Serum           | 241306  |

### 4.10 Utility Potions

| Item Name                | Item ID | Effect                 |
|-------------------------|---------|------------------------|
| Light's Preservation     | 241286  | Damage absorption      |
| Void-Shrouded Tincture   | 241302  | Invisibility           |
| Enlightenment Tonic      | 241338  | Fall speed reduction   |

### 4.11 Warlock Healthstones

| Item Name             | Item ID | Notes                           |
|----------------------|---------|----------------------------------|
| Healthstone           | 5512    | Standard, unchanged since classic|
| Demonic Healthstone   | 224464  | Added in The War Within          |

### 4.12 Cauldrons (Raid-Wide Consumable Distribution)

| Item Name                    | Item ID |
|-----------------------------|---------|
| Voidlight Potion Cauldron    | 241285  |
| Cauldron Of Sin'dorei Flasks | 241318  |

### 4.13 Weapon Enhancements

| Item Name                    | Item ID | Type            |
|-----------------------------|---------|-----------------|
| Refulgent Weightstone        | 237369  | Blacksmithing   |
| Refulgent Whetstone          | 237371  | Blacksmithing   |
| Refulgent Razorstone         | 237373  | Blacksmithing   |
| Thalassian Phoenix Oil       | 243734  | Enchanting      |
| Smuggler's Enchanted Edge    | 243738  | Enchanting      |
| Oil Of Dawn                  | 243736  | Enchanting      |

### 4.14 Augment Runes

- **Void-Touched Augment Rune** -- Primary stat boost, 1 hour duration,
  non-persistent through death.

### 4.15 Bandages

First Aid was removed as a profession in Battle for Azeroth (Patch 8.0).
Bandages still exist in the game but are now crafted via **Tailoring**.
No new Midnight-specific bandages have been prominently documented.
Bandages are rarely used in current endgame content.

### 4.16 Basic Food and Drink (Non-Stat, Regen Only)

Basic food and water (for out-of-combat health/mana regeneration) are
available from vendors and are not expansion-specific. Players typically
use conjured food (Mage) or vendor food. These do not provide stat buffs.

---

## 5. Macro Character Limit

- **Maximum macro body length: 255 characters**.
- Implemented since Patch 3.0.2 when macro storage moved server-side.
- Both CreateMacro and EditMacro silently truncate bodies exceeding 255 characters.
- This limit applies to ALL macros: real macros AND macrotext-based secure buttons
  (confirmed in Patch 11.0.2).
- The macro NAME has a separate 16-character limit imposed by the UI.
- The 255-character limit is a hard constraint that addon developers must work within.

### Implications for Consumable Macros
- Using `item:XXXXX` syntax (5-6 digit IDs) is more compact than full item names.
- A typical `/use item:241308` line is ~18 characters.
- With `#showtooltip\n` (14 chars) overhead, roughly 241 chars remain for /use lines.
- Multiple fallback items in a single macro line: `/use item:A; /use item:B` does
  NOT work -- semicolons separate conditional clauses, not sequential commands.
- Each `/use` command must be on its own line, consuming ~19 chars each.
- Practical limit: approximately 12-13 fallback items per macro.

---

## 6. Macro Conditional System

### 6.1 Basic Structure

```
/command [conditions] spell/item; [conditions] spell/item
```

- Conditions in `[]` brackets are evaluated **left to right**.
- **First matching** condition triggers; remaining clauses are skipped.
- Semicolons (`;`) separate alternative clauses (like else-if).
- Commas within brackets act as **logical AND**.

### 6.2 #showtooltip Directive

```
#showtooltip
#showtooltip Pyroblast
#showtooltip [modifier:shift] Conjure Food; Conjure Water
```

- Controls the macro button's tooltip and icon feedback.
- Must be lowercase.
- If no argument given, shows whichever spell/item WoW would select for feedback.
- Cannot coexist with `#show` in the same macro.
- Supports the full conditional syntax.

### 6.3 /use and /cast Commands

`/use` is identical to `/cast`. Both accept:
- Spell/item names: `/use Hearthstone`
- Item IDs: `/use item:6948`
- Inventory slots: `/use 13` (top trinket slot)
- Bag+slot: `/use 0 1` (backpack slot 1)

### 6.4 Using Items by Item ID

```
/use item:241308
#showtooltip item:241308
```

- Format: `item:XXXXX` where XXXXX is the numeric item ID.
- Works with `/use`, `/cast`, `#showtooltip`, and `#show`.
- Preferred for programmatic macro generation because:
  - IDs are locale-independent (work in all languages).
  - IDs are typically shorter than localized item names.
  - IDs are unambiguous (no name collisions).

### 6.5 Common Conditionals

**Targeting**:
- `[help]` -- target is friendly
- `[harm]` -- target is hostile
- `[exists]` -- a valid target exists
- `[@unit]` -- specifies target (e.g., `[@focus]`, `[@player]`, `[@mouseover]`)
- `[dead]` / `[nodead]` -- target dead/alive

**Keyboard Modifiers**:
- `[mod:shift]`, `[mod:ctrl]`, `[mod:alt]`
- `[nomod]` -- no modifier pressed
- Multiple: `[mod:shift,mod:ctrl]` = Shift AND Ctrl

**Combat State**:
- `[combat]` -- player is in combat
- `[nocombat]` -- player is out of combat

**Stance/Form**:
- `[stance:1]`, `[stance:2/3]` (slash = OR within stance)

**Negation**:
- Prefix any condition with `no`: `[nohelp]`, `[nodead]`, `[nocombat]`
- `[nohelp]` differs from `[harm]`: nohelp matches absent targets too.

### 6.6 Conditional Evaluation Example

```
#showtooltip
/use [nocombat] item:241321; [combat] item:241308
```

This macro:
- Out of combat: uses Flask Of Thalassian Resistance (241321)
- In combat: uses Light's Potential potion (241308)

### 6.7 Secure vs. Insecure Commands

Only **secure** commands support conditionals:
`/cast`, `/use`, `/castrandom`, `/castsequence`, `/equip`, `/equipslot`,
`/target`, `/focus`, `/petattack`, `/startattack`, etc.

Insecure commands (chat, emotes) do NOT support conditionals.

### 6.8 Multi-Line Fallback Pattern

For consumable macros, the typical pattern is sequential `/use` lines:
```
#showtooltip
/use item:241308
/use item:241292
/use item:5512
```

WoW executes line-by-line. The first `/use` that succeeds (item exists and
is usable) takes effect; subsequent lines are skipped for that keypress.
This creates a natural priority/fallback system:
- Try the best potion first.
- Fall back to the next best.
- Fall back to healthstone as last resort.

---

## 7. Key Technical Considerations for Addon Development

### 7.1 Combat Lockdown
- `InCombatLockdown()` returns true when the player is in combat.
- CreateMacro, EditMacro, DeleteMacro all fail during combat.
- Addon must queue changes and apply them when combat ends.
- Register for `PLAYER_REGEN_ENABLED` event (fires when leaving combat).
- Register for `PLAYER_REGEN_DISABLED` event (fires when entering combat).

### 7.2 Event-Driven Updates
Recommended event flow:
1. Listen for `BAG_UPDATE_DELAYED` (reliable, fires after all bag changes).
2. Check `InCombatLockdown()` -- if true, set a "pending update" flag.
3. If not in combat, scan bags and update macros immediately.
4. If pending update exists, listen for `PLAYER_REGEN_ENABLED` to apply.

### 7.3 Item Data Availability
- `C_Item.GetItemInfo()` may return nil if the item data is not cached.
- Listen for `ITEM_DATA_LOAD_RESULT` or `GET_ITEM_INFO_RECEIVED` events
  after requesting uncached item data.
- For items in bags, data is typically already cached.

### 7.4 Interface Version for Midnight
```toc
## Interface: 120000
```
Addons MUST specify this or higher to load in WoW 12.0.0+.

### 7.5 Taint Considerations
- Macro editing functions are "restricted" -- they must be called from
  trusted (untainted) code paths.
- Avoid calling these functions from within callbacks that might be tainted.
- The addon's main event handler frame is typically untainted.

---

## 8. Summary of Sources

- [ConsumableMacro on CurseForge](https://www.curseforge.com/wow/addons/consumablemacro)
- [WoW API: CreateMacro](https://warcraft.wiki.gg/wiki/API_CreateMacro)
- [WoW API: EditMacro](https://warcraft.wiki.gg/wiki/API_EditMacro)
- [WoW API: DeleteMacro](https://warcraft.wiki.gg/wiki/API_DeleteMacro)
- [WoW API: GetMacroInfo](https://warcraft.wiki.gg/wiki/API_GetMacroInfo)
- [WoW API: GetNumMacros](https://warcraft.wiki.gg/wiki/API_GetNumMacros)
- [WoW API: GetItemInfo](https://warcraft.wiki.gg/wiki/API_GetItemInfo)
- [WoW API: C_Item.GetItemInfo](https://warcraft.wiki.gg/wiki/API_C_Item.GetItemInfo)
- [WoW API: C_Item.GetItemCount](https://warcraft.wiki.gg/wiki/API_C_Item.GetItemCount)
- [WoW API: C_Container.GetContainerItemInfo](https://warcraft.wiki.gg/wiki/API_C_Container.GetContainerItemInfo)
- [WoW API: C_TooltipInfo.GetHyperlink](https://warcraft.wiki.gg/wiki/API_C_TooltipInfo.GetHyperlink)
- [WoW API: BAG_UPDATE_DELAYED](https://warcraft.wiki.gg/wiki/BAG_UPDATE_DELAYED)
- [WoW API: BAG_UPDATE](https://warcraft.wiki.gg/wiki/BAG_UPDATE)
- [WoW Settings API](https://warcraft.wiki.gg/wiki/Settings_API)
- [Patch 12.0.0 API Changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/Planned_API_changes)
- [Patch 11.0.2 API Changes](https://warcraft.wiki.gg/wiki/Patch_11.0.2/API_changes)
- [Making a Macro Guide](https://warcraft.wiki.gg/wiki/Making_a_macro)
- [Method.gg Midnight Consumables](https://www.method.gg/guides/list-of-all-midnight-consumables-enchants-and-gems)
- [BoostRoom Midnight Consumables](https://boostroom.com/blog/best-consumables-in-wow-midnight-flasks-food-runes-potions)
- [Wowhead: Healthstone](https://www.wowhead.com/item=5512/healthstone)
- [Wowhead: Demonic Healthstone](https://www.wowhead.com/item=224464/demonic-healthstone)
- [Warcraft Wiki: First Aid](https://warcraft.wiki.gg/wiki/First_Aid)
- [Blizzard Forums: API Changes with Midnight](https://us.forums.blizzard.com/en/wow/t/is-there-a-place-to-get-a-list-of-api-changes-with-midnight/2200149)
- [Wowhead: Addon Changes for Midnight](https://www.wowhead.com/news/addon-changes-for-midnight-launch-ending-soon-with-release-candidate-coming-380133)
