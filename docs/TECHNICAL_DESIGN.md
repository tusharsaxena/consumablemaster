# Ka0s Consumable Master — Technical Design

Companion to [REQUIREMENTS.md](./REQUIREMENTS.md). Where requirements answer *what*, this doc answers *how*.

---

## 1. High-Level Architecture

```
                             ┌─────────────────────────────────────────┐
   WoW Events                │                   Core                  │
   ─────────────────────────►│ (AceAddon, AceEvent — single dispatch)  │
   PLAYER_ENTERING_WORLD     │                                         │
   BAG_UPDATE_DELAYED        │   Pipeline.Recompute()  ◄──── /kcm resync
   PLAYER_SPEC_CHANGED       │                                         │
   PLAYER_REGEN_ENABLED      └────┬─────────┬─────────┬────────┬───────┘
                                  │         │         │        │
                          ┌───────▼──┐  ┌───▼────┐ ┌──▼─────┐ ┌▼────────┐
                          │ Spec     │  │  Bag   │ │Tooltip │ │ Macro   │
                          │ Helper   │  │Scanner │ │ Cache  │ │ Manager │
                          └────┬─────┘  └───┬────┘ └────┬───┘ └────▲────┘
                               │            │           │          │
                          ┌────▼────────────▼───────────▼──┐       │
                          │           Selector             │───────┘
                          │  (uses Ranker + Classifier     │   best itemID
                          │   to build effective list,     │   per category
                          │   picks first owned item)      │
                          └────┬───────────────────────────┘
                               │
                ┌──────────────┴────────────┐
                │                           │
        ┌───────▼────────┐         ┌────────▼────────┐
        │   Ranker       │         │   Classifier    │
        │ score(item) by │         │ does item match │
        │ ilvl, quality, │         │ category? (used │
        │ tooltip data,  │         │ by auto-discov) │
        │ spec priority  │         └─────────────────┘
        └────────────────┘

   ┌─────────────────────────────────────────────────────────────────┐
   │  AceDB (ConsumableMasterDB)                                 │
   │  └── profile = single-account-wide                              │
   │       ├── debug                                                 │
   │       ├── categories.<CAT>.{added,blocked,pins,discovered}      │
   │       ├── categories.<SPEC_AWARE>.bySpec[classID_specID].{...}  │
   │       ├── categories.<SPEC_AWARE>.statPriority[classID_specID]  │
   │       └── macroState.<KCM_NAME>.{lastItemID, lastBody}          │
   └─────────────────────────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────────────────────────┐
   │  AceConfig + AceConfigDialog                                    │
   │  └── option-table generated from category metadata,             │
   │       registered into Blizzard Settings via                     │
   │       Settings.RegisterAddOnCategory()                          │
   └─────────────────────────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────────────────────────┐
   │  AceConsole — /kcm slash handler                                │
   └─────────────────────────────────────────────────────────────────┘
```

The pipeline is **pull-based**: an event triggers `Pipeline.Recompute()`, which for every category calls `Selector.GetBestForCategory(cat)` and hands the result to `MacroManager.SetMacro(cat.macroName, itemID)`.

---

## 2. File Layout (final)

Repo root is the addon folder — the `.toc` and `.lua` files sit directly
under the repo (no inner `ConsumableMaster/` subfolder). Design docs live in
`docs/`.

```
./
├── ConsumableMaster.toc          # ## Interface: 120000, deps, file order
├── embeds.xml                        # XML include for Ace3 libs
├── libs/                             # vendored Ace3 + LibStub
│   ├── LibStub/LibStub.lua
│   ├── CallbackHandler-1.0/...
│   ├── AceAddon-3.0/...
│   ├── AceEvent-3.0/...
│   ├── AceDB-3.0/...
│   ├── AceConsole-3.0/...
│   ├── AceConfig-3.0/...
│   ├── AceConfigCmd-3.0/...
│   ├── AceConfigDialog-3.0/...
│   ├── AceConfigRegistry-3.0/...
│   └── AceGUI-3.0/...                # transitive dep of AceConfigDialog
├── Core.lua                          # AceAddon entry + Pipeline.Recompute
├── MacroManager.lua                  # Adopt/create/edit by name; combat deferral
├── Selector.lua                      # Effective list + first-owned picker
├── Ranker.lua                        # Per-category scoring functions
├── Classifier.lua                    # Auto-discovery match rules
├── BagScanner.lua                    # Bag iteration, ownership cache
├── TooltipCache.lua                  # Lazy tooltip parsing + cache
├── SpecHelper.lua                    # (classID, specID) resolver, watcher
├── Options.lua                       # AceConfig option-table builder
├── SlashCommands.lua                 # /kcm dispatch (via AceConsole)
├── Debug.lua                         # KCM:Debug() print wrapper
└── defaults/
    ├── Categories.lua                # Master metadata table (see §3)
    ├── Defaults_StatPriority.lua     # (classID, specID) → stat priority
    ├── Defaults_Food.lua             # candidate set
    ├── Defaults_Drink.lua
    ├── Defaults_StatFood.lua         # per-spec candidate sets
    ├── Defaults_HPPot.lua
    ├── Defaults_MPPot.lua
    ├── Defaults_Healthstone.lua
    ├── Defaults_CombatPot.lua        # per-spec
    ├── Defaults_Flask.lua            # per-spec
    └── README.md                     # source attribution + last-updated
```

---

## 3. Category Metadata Table

`defaults/Categories.lua` is the *single source of truth* about the 8 categories. Every other module iterates over it. Schema:

```lua
KCM.CATEGORIES = {
    {
        key         = "FOOD",
        macroName   = "KCM_FOOD",
        displayName = "Basic / Conjured Food",
        specAware   = false,
        rankerKey   = "food",        -- which Ranker function to use
        classifier  = "food",        -- which Classifier function to use
        emptyText   = "No food in bags.",
    },
    { key="DRINK",     macroName="KCM_DRINK",     displayName="Drink",                specAware=false, rankerKey="drink",     classifier="drink"     },
    { key="STAT_FOOD", macroName="KCM_STAT_FOOD", displayName="Stat Food",            specAware=true,  rankerKey="statfood",  classifier="statfood"  },
    { key="HP_POT",    macroName="KCM_HP_POT",    displayName="Health Potion",        specAware=false, rankerKey="hppot",     classifier="hppot"     },
    { key="MP_POT",    macroName="KCM_MP_POT",    displayName="Mana Potion",          specAware=false, rankerKey="mppot",     classifier="mppot"     },
    { key="HS",        macroName="KCM_HS",        displayName="Healthstone",          specAware=false, rankerKey="hs",        classifier="hs"        },
    { key="CMBT_POT",  macroName="KCM_CMBT_POT",  displayName="Combat Potion",        specAware=true,  rankerKey="cmbtpot",   classifier="cmbtpot"   },
    { key="FLASK",     macroName="KCM_FLASK",     displayName="Flask",                specAware=true,  rankerKey="flask",     classifier="flask"     },
}
```

Adding a new category in the future = append a row + write defaults file + add Ranker/Classifier functions. No other files change.

---

## 4. Saved Variables Schema (AceDB)

`ConsumableMasterDB`, single profile (per user req §11.7):

```lua
KCM.dbDefaults = {
    profile = {
        schemaVersion = 1,
        debug = false,
        categories = {
            -- non-spec-aware (one per category)
            FOOD     = { added = {}, blocked = {}, pins = {}, discovered = {} },
            DRINK    = { added = {}, blocked = {}, pins = {}, discovered = {} },
            HP_POT   = { added = {}, blocked = {}, pins = {}, discovered = {} },
            MP_POT   = { added = {}, blocked = {}, pins = {}, discovered = {} },
            HS       = { added = {}, blocked = {}, pins = {}, discovered = {} },
            -- spec-aware
            STAT_FOOD = {
                bySpec = {
                    -- ["<classID>_<specID>"] = { added={}, blocked={}, pins={}, discovered={} }
                },
            },
            CMBT_POT = { bySpec = {} },
            FLASK    = { bySpec = {} },
        },
        -- Stat priority lives once at the profile level (not per category) — it's a property
        -- of the spec itself, shared by STAT_FOOD / CMBT_POT / FLASK ranking.
        statPriority = {
            -- ["<classID>_<specID>"] = { primary="AGI", secondary={"MASTERY","HASTE","CRIT","VERSATILITY"} }
        },
        macroState = {
            -- ["KCM_FOOD"] = { lastItemID = 12345, lastBody = "..." }
        },
    },
}
```

**Field semantics:**
- `added[itemID] = true` → user-added item (acts like a manual seed entry).
- `blocked[itemID] = true` → user-blocked item; never appears in candidate set.
- `pins` → array of `{ itemID = X, position = N }`. Pin positions are honored top-to-bottom; non-pinned items fill the gaps in auto-rank order.
- `discovered[itemID] = true` → auto-discovered item (badge in UI). Persists once written.
- `statPriority[<spec>]` is *optional* — if missing, the addon falls back to the shipped default from `Defaults_StatPriority.lua` for that spec.

**Effective candidate set** (computed at recompute time):
```
candidates = (seed[category] ∪ added[category] ∪ discovered[category]) − blocked[category]
```

**Migrations**: `schemaVersion` checked at `OnInitialize`. v1→v2 etc. handled by a small `Migrations.lua` shim added when needed; v1 is the launch version.

---

## 5. Module Interfaces

Every module exposes a small surface on the addon namespace `KCM` (returned from `LibStub("AceAddon-3.0"):NewAddon(...)`).

### 5.1 Core
```lua
KCM:OnInitialize()      -- AceAddon callback: AceDB setup, options registration, slash registration
KCM:OnEnable()          -- Event subscriptions, run initial Pipeline.Recompute
KCM:OnDisable()         -- (probably never used)
KCM.Pipeline.Recompute(reason)  -- recompute all categories
KCM.Pipeline.RecomputeOne(catKey, reason)  -- recompute a single category
```

### 5.2 MacroManager
```lua
KCM.MacroManager.SetMacro(macroName, itemID)
    -- itemID = nil → write empty-state stub
    -- combat-locked → enqueue for after PLAYER_REGEN_ENABLED
KCM.MacroManager.FlushPending()  -- called on PLAYER_REGEN_ENABLED
KCM.MacroManager.IsAdopted(macroName) -> boolean
```

Internal flow per call:
```
SetMacro(name, itemID):
    body = (itemID and BuildBody(itemID)) or BuildEmptyBody(category)
    if KCM.db.profile.macroState[name].lastBody == body: return  -- no-op skip
    if InCombatLockdown():
        pendingUpdates[name] = body
        return
    idx = GetMacroIndexByName(name)
    if idx == 0:
        CreateMacro(name, "INV_MISC_QUESTIONMARK", body, false)  -- false = account-wide
    else:
        EditMacro(name, nil, nil, body)
    KCM.db.profile.macroState[name] = { lastItemID = itemID, lastBody = body }
```

`BuildBody(itemID)`:
```
return "#showtooltip\n/use item:" .. itemID
```

`BuildEmptyBody(catKey)`:
```
return "#showtooltip\n/run print(\"|cffff8800[KCM]|r " .. cat.emptyText .. "\")"
```

Both fit comfortably under 255 chars.

### 5.3 Selector
```lua
KCM.Selector.GetEffectivePriority(catKey) -> array of itemIDs
    -- builds candidate set (seed ∪ added ∪ discovered − blocked)
    -- runs Ranker to score each candidate
    -- merges user pins on top
    -- returns ordered list
KCM.Selector.PickBestForCategory(catKey) -> itemID | nil
    -- gets effective priority list, walks it, returns first owned item
```

Pin merge algorithm:
```
Given pins = [{id=A, pos=1}, {id=C, pos=3}], autoRanked = [B, D, E, F, A, C, G]
1. Remove pinned IDs from autoRanked → [B, D, E, F, G]
2. Sort pins by pos ascending → [{A,1},{C,3}]
3. Build result by inserting pinned at pos and filling gaps from autoRanked
   pos=1: [A]
   pos=2: [A, B] (next from autoRanked)
   pos=3: [A, B, C]
   pos=4: [A, B, C, D]
   ...
4. Result: [A, B, C, D, E, F, G]
```

If a pin position exceeds the candidate count, it's clamped to end. Pins for items not in the candidate set are silently ignored (so removing a pinned item doesn't break ranking).

### 5.4 Ranker
```lua
KCM.Ranker.Score(catKey, itemID, ctx) -> number
    -- ctx provides: { specPriority = {primary=...,secondary={...}} } when relevant
KCM.Ranker.SortCandidates(catKey, itemIDs) -> sorted itemIDs
```

Per-category scoring formulas (all numeric, "higher is better"):

```lua
-- Common signals
local function commonSignals(itemID)
    local _, _, quality, ilvl, _, _, subType = C_Item.GetItemInfo(itemID)
    local tt = TooltipCache.Get(itemID)
    return quality or 0, ilvl or 0, subType or "", tt
end

-- food/drink: parsed restore amount dominates; conjured bonus; ilvl tiebreak
food.score = (tt.healValue or 0) + (tt.isConjured and 1e6 or 0)
             + ilvl + quality * 100

drink.score = (tt.manaValue or 0) + (tt.isConjured and 1e6 or 0)
              + ilvl + quality * 100

-- hp_pot / mp_pot: parsed average value; ilvl tiebreak
hppot.score = (tt.healValueAvg or 0) + ilvl + quality * 100
mppot.score = (tt.manaValueAvg or 0) + ilvl + quality * 100

-- healthstone: hardcoded preference + ilvl
hs.score = (HEALTHSTONE_PREFERENCE[itemID] or 0) + ilvl
-- HEALTHSTONE_PREFERENCE = { [224464] = 1000, [5512] = 100 }

-- statfood: spec stat-priority match × parsed stat amount
statfood.score = computeStatFoodScore(tt, ctx.specPriority)
-- Walks tt.statBuffs (array of {stat, amount}); for each, multiplies amount
-- by a weight derived from stat's position in ctx.specPriority.secondary
-- (4 - index). Primary-stat food gets a flat large weight.

-- cmbt_pot: similar to statfood but pot-typed
cmbtpot.score = computeCmbtPotScore(tt, ctx.specPriority)
-- Two flavors: primary-stat pots (Light's Potential, Draught of Rampant Abandon)
-- and secondary-stat pots (Potion of Recklessness). Spec stat priority decides
-- which flavor wins; within flavor, ilvl breaks ties.

-- flask: stat name in tooltip × spec priority
flask.score = computeFlaskScore(tt, ctx.specPriority)
-- Parse "Increases your <stat> by N for 2 hours". Match <stat> against
-- ctx.specPriority.secondary; weight by 4-index.
```

All scoring functions are pure — same inputs → same output, no side effects. This makes them easy to unit-test (manually) by setting up fake TooltipCache entries.

### 5.5 Classifier
```lua
KCM.Classifier.Match(catKey, itemID) -> boolean
KCM.Classifier.MatchAny(itemID) -> array of catKeys
    -- For auto-discovery: scan bags, find which categories each item could belong to.
```

Per-category match predicates (in pseudo-code):
```
food:     subType == "Food & Drink" AND tt.healValue > 0 AND not tt.hasStatBuff
drink:    subType == "Food & Drink" AND tt.manaValue > 0 AND not tt.hasStatBuff
statfood: subType == "Food & Drink" AND tt.hasStatBuff AND not tt.isFeast
hppot:    subType == "Potion" AND tt.healValueAvg > 0 AND not tt.hasStatBuff
mppot:    subType == "Potion" AND tt.manaValueAvg > 0 AND not tt.hasStatBuff
hs:       itemID ∈ HEALTHSTONE_IDS  -- {5512, 224464}
cmbtpot:  subType == "Potion" AND tt.hasStatBuff AND tt.buffDurationSec ≤ 60
flask:    subType == "Flask" OR subType == "Phial"
```

`tt.isFeast` is set by TooltipCache when the tooltip contains "Feast", "Set out a", or otherwise indicates a multi-serve / placeable item — this enforces REQ §11.1.

### 5.6 BagScanner
```lua
KCM.BagScanner.Scan() -> { [itemID] = count }
KCM.BagScanner.HasItem(itemID) -> boolean
KCM.BagScanner.GetAllItemIDs() -> array of itemIDs (unique)
```

Implementation iterates bags 0..NUM_TOTAL_EQUIPPED_BAG_SLOTS using `C_Container.GetContainerNumSlots` + `C_Container.GetContainerItemInfo`. Result is cached for the duration of one Pipeline.Recompute call (single scan, multiple consumers).

### 5.7 TooltipCache
```lua
KCM.TooltipCache.Get(itemID) -> {
    healValue, healValueAvg,
    manaValue, manaValueAvg,
    isConjured, hasStatBuff, isFeast,
    buffDurationSec,
    statBuffs = { {stat="MASTERY", amount=935}, ... },
}
KCM.TooltipCache.Invalidate(itemID)
KCM.TooltipCache.InvalidateAll()  -- called by /kcm resync
```

On miss: calls `C_TooltipInfo.GetItemByID(itemID)` (fires off ITEM_DATA_LOAD if needed), parses lines using a fixed set of Lua patterns:

```lua
local PATTERNS = {
    healRange = "Restores ([%d,]+) to ([%d,]+) health",
    healFlat  = "Restores ([%d,]+) health",
    manaRange = "Restores ([%d,]+) to ([%d,]+) mana",
    manaFlat  = "Restores ([%d,]+) mana",
    conjured  = "^Conjured Item$",
    statBuff  = "(Mastery|Critical Strike|Haste|Versatility|Strength|Agility|Intellect)[^%d]+([%d,]+)",
    duration  = "for ([%d]+) sec",
    feast     = "Feast",  -- substring search
}
```

If `C_TooltipInfo.GetItemByID(itemID)` returns nil (data not yet loaded), the cache stores a `pending = true` placeholder, registers the itemID for `GET_ITEM_INFO_RECEIVED`, and Core triggers a re-compute when the event arrives.

### 5.8 SpecHelper
```lua
KCM.SpecHelper.GetCurrent() -> { classID, specID, key="<classID>_<specID>", displayName }
KCM.SpecHelper.AllSpecs() -> array of { classID, specID, key, className, specName }
KCM.SpecHelper.GetStatPriority(specKey) -> { primary="AGI", secondary={...} }
    -- returns user override from db if set, else shipped default
```

`AllSpecs()` is used by the settings panel's "view this spec" dropdown (so users can edit any spec's list, not just the active one). It enumerates classes 1..13 and `GetNumSpecializationsForClassID` for each.

### 5.9 Options
```lua
KCM.Options.Build() -> AceConfig option table
KCM.Options.Register()  -- one-time: AceConfig:RegisterOptionsTable + AceConfigDialog:AddToBlizOptions
KCM.Options.Refresh()  -- LibStub("AceConfigRegistry-3.0"):NotifyChange("ConsumableMaster")
```

The option table is *generated dynamically* every time `Refresh()` is called, because the priority list rows change as bag contents change. Sketch:

```lua
function KCM.Options.Build()
  local opts = {
    type = "group", name = "Ka0s Consumable Master",
    childGroups = "tab",  -- tabbed sub-pages
    args = { general = generalGroup() }
  }
  for _, cat in ipairs(KCM.CATEGORIES) do
    opts.args[cat.key:lower()] = categoryGroup(cat)
  end
  return opts
end
```

`categoryGroup(cat)` builds a group with:
- (if specAware) a `select` of all specs, default = current.
- A `description` widget showing the current macro body and selected item.
- For each item in the effective priority list: a row of widgets — `description` (icon + name), `execute` for "Up", `execute` for "Down", `execute` for "Remove". (AceConfig doesn't render true tables; we lay rows out by giving each control a unique sortable order index.)
- An `input` for "Add item by ID" with a validator that calls `C_Item.GetItemInfo` and rejects unknown IDs.
- An `execute` "Reset pins to auto".
- An `execute` "Reset blocklist".
- (if specAware) a sub-group for stat-priority overrides: 1 select for primary, 4 selects for secondary order.

### 5.10 SlashCommands
Registered via AceConsole-3.0:
```lua
KCM:RegisterChatCommand("kcm", "OnSlashCommand")
function KCM:OnSlashCommand(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    if cmd == "" then          KCM.SlashCommands.PrintHelp()
    elseif cmd == "config" then KCM.Options.Open()
    elseif cmd == "debug" then  KCM.Debug.Toggle()
    elseif cmd == "resync" then KCM.SlashCommands.Resync()
    elseif cmd == "reset" then  KCM.SlashCommands.Reset()  -- pops StaticPopup
    else                        KCM.SlashCommands.PrintHelp()
    end
end
```

`KCM.Options.Open()` calls `Settings.OpenToCategory(KCM._settingsCategoryID)` (Patch 11.0.2+ API).

### 5.11 Debug
```lua
KCM.Debug.IsOn() -> boolean
KCM.Debug.Toggle()
KCM.Debug.Print(format, ...)  -- prints prefixed colored text only if IsOn()
```

Used liberally in BagScanner / TooltipCache / Selector / MacroManager — cheap branch when off.

---

## 6. Event Handling and Combat Deferral

### 6.1 Subscriptions (in `Core:OnEnable`)
```lua
self:RegisterEvent("PLAYER_ENTERING_WORLD",       "OnPlayerEnteringWorld")
self:RegisterEvent("BAG_UPDATE_DELAYED",          "OnBagUpdateDelayed")
self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", "OnSpecChanged")
self:RegisterEvent("PLAYER_REGEN_ENABLED",        "OnRegenEnabled")
self:RegisterEvent("PLAYER_REGEN_DISABLED",       "OnRegenDisabled")
self:RegisterEvent("GET_ITEM_INFO_RECEIVED",      "OnItemInfoReceived")
```

### 6.2 Coalescing
Multiple recompute requests within the same frame are collapsed. Implementation:
```lua
function KCM.Pipeline.RequestRecompute(reason)
    KCM._recomputePending = true
    KCM._recomputeReason = reason
    C_Timer.After(0, function()
        if KCM._recomputePending then
            KCM._recomputePending = false
            KCM.Pipeline.Recompute(KCM._recomputeReason)
        end
    end)
end
```
Every event handler calls `RequestRecompute` instead of calling `Recompute` directly. This means a flurry of `BAG_UPDATE_DELAYED` (rare but possible during loot) collapses to one scan.

### 6.3 Combat lockdown sequence
```
PLAYER_REGEN_DISABLED (combat starts):
    set KCM._inCombat = true

BAG_UPDATE_DELAYED while in combat:
    RequestRecompute("bag_update_combat")
    → Pipeline.Recompute runs as normal:
       Selector picks the best item per category (no taint risk)
       MacroManager.SetMacro:
         - InCombatLockdown() returns true
         - body is queued in pendingUpdates[macroName] = body
         - no API call to CreateMacro/EditMacro

PLAYER_REGEN_ENABLED (combat ends):
    set KCM._inCombat = false
    MacroManager.FlushPending():
      for name, body in pairs(pendingUpdates):
        EditMacro(name, nil, nil, body)
        update macroState
      pendingUpdates = {}
```

We never call macro APIs during combat; we never make any decision based on tainted code paths. Selector and Ranker have no protected-API calls — only MacroManager touches macros.

### 6.4 Spec change
`PLAYER_SPECIALIZATION_CHANGED` triggers a recompute of *all* categories (not just spec-aware). Cost is negligible and avoids stale state if bag also changed.

---

## 7. First-Run / Defaults Seeding

`Core:OnInitialize`:
1. `self.db = LibStub("AceDB-3.0"):New("ConsumableMasterDB", KCM.dbDefaults, true)`.
2. Check `self.db.profile.schemaVersion`. If nil → fresh install, set to 1.
3. Defaults files are *not* copied into SavedVariables. They live in Lua-side constants (`KCM.SEED.FOOD = {12345, 67890, ...}`) and the Selector merges seed ∪ added ∪ discovered ∪ blocked at recompute time. This means:
   - User cannot accidentally shadow a default by removing it from `added` (defaults are permanent unless explicitly blocklisted).
   - Updating the defaults file = automatic upgrade for all users.
4. Stat-priority defaults follow the same model: `KCM.SEED.STAT_PRIORITY[<spec>]`; only user overrides go into SavedVariables.

---

## 8. Tooltip Parsing Details

### 8.1 Why parse tooltips
`C_Item.GetItemInfo` gives ilvl, quality, subType — but not heal value, mana value, stat buffs, or duration. Those live only in the tooltip text.

### 8.2 Parser flow
```lua
function TooltipCache.parse(itemID)
    local data = C_TooltipInfo.GetItemByID(itemID)
    if not data or not data.lines then return { pending = true } end

    local result = { statBuffs = {} }
    for _, line in ipairs(data.lines) do
        local txt = line.leftText or ""
        local lo, hi = txt:match(PATTERNS.healRange)
        if lo then result.healValueAvg = (tonumber(lo:gsub(",","")) + tonumber(hi:gsub(",",""))) / 2
        else
            local v = txt:match(PATTERNS.healFlat)
            if v then result.healValue = tonumber(v:gsub(",","")) end
        end
        -- ... mana similar ...
        if txt == "Conjured Item" then result.isConjured = true end
        if txt:find("Feast") then result.isFeast = true end
        local dur = txt:match(PATTERNS.duration)
        if dur then result.buffDurationSec = tonumber(dur) end
        -- statBuff pattern is Lua-pattern-friendly:
        -- "Mastery increased by 935 for 30 sec" → captures "Mastery", "935"
        for stat, amt in txt:gmatch(PATTERNS.statBuff) do
            table.insert(result.statBuffs, { stat = NORMALIZE_STAT[stat], amount = tonumber(amt:gsub(",","")) })
            result.hasStatBuff = true
        end
    end
    return result
end
```

### 8.3 Item-data not yet loaded
If `C_TooltipInfo.GetItemByID(itemID)` returns `nil` or empty `lines`, that item's slot in the cache is marked `pending=true`. We record the itemID in a "pending" set. When `GET_ITEM_INFO_RECEIVED` fires with that itemID, we invalidate the cache entry and `RequestRecompute("item_data_loaded")`.

### 8.4 Cache lifecycle
- Session-scoped (not persisted).
- Invalidated only by `/kcm resync` or `GET_ITEM_INFO_RECEIVED` for a known-pending item.
- Worst case: a fresh cache miss on every itemID at login. With ~50 candidate items across all categories, parse cost is negligible (~1 ms total).

---

## 9. Settings UI Construction

### 9.1 AceConfigDialog vs custom AceGUI
We use **AceConfigDialog** (the option-table-driven path) because:
- One-shot integration with Blizzard's Settings panel via `AceConfigDialog:AddToBlizOptions`.
- Free re-render on `NotifyChange`.
- Pre-built widgets for select/input/toggle/execute.

The downside is no native "table" or "drag reorder" widget. We work around this by representing each priority-list row as a horizontal cluster of widgets sharing an `order` index.

### 9.2 Row representation
Each row in the priority list = 4 sequential controls in the option table:
```lua
[("row_" .. i .. "_label")] = {
    type="description", order=baseOrder + 0.0,
    name = function() return rowLabel(itemID) end,  -- returns "[icon] Item Name (id:NNN) [pin?] [auto?] [bags?]"
    width = 1.5,
    image = function() return GetItemIcon(itemID) end, imageWidth=18, imageHeight=18,
},
[("row_" .. i .. "_up")] = {
    type="execute", order=baseOrder + 0.1, name="↑", width=0.3,
    func = function() KCM.Selector.MoveUp(catKey, itemID); KCM.Options.Refresh() end,
    disabled = function() return i == 1 end,
},
[("row_" .. i .. "_down")] = {
    type="execute", order=baseOrder + 0.2, name="↓", width=0.3,
    func = function() KCM.Selector.MoveDown(catKey, itemID); KCM.Options.Refresh() end,
    disabled = function() return i == listLen end,
},
[("row_" .. i .. "_remove")] = {
    type="execute", order=baseOrder + 0.3, name="X", width=0.3,
    func = function() KCM.Selector.Block(catKey, itemID); KCM.Options.Refresh() end,
},
```

`MoveUp`/`MoveDown` mutate the `pins` array such that the moved item ends up pinned at its new position. Items below it shift down naturally because of the pin-merge algorithm in §5.3.

### 9.3 "Add by ID" input
```lua
addInput = {
    type = "input", order = 100, name = "Add item by ID", width = 1.0,
    validate = function(_, val)
        local id = tonumber(val)
        if not id then return "Must be a number" end
        if not C_Item.GetItemInfo(id) then return "Unknown item ID" end
        return true
    end,
    set = function(_, val)
        local id = tonumber(val)
        KCM.Selector.AddItem(catKey, id)
        KCM.Options.Refresh()
    end,
}
```

### 9.4 Spec selector (spec-aware categories)
```lua
specSelect = {
    type = "select", order = 1, name = "Spec",
    values = function() return KCM.SpecHelper.AllSpecsAsOptions() end,
    get = function() return _viewedSpec[catKey] or KCM.SpecHelper.GetCurrent().key end,
    set = function(_, val) _viewedSpec[catKey] = val; KCM.Options.Refresh() end,
}
```

`_viewedSpec` is a transient module-level table — not persisted. The "viewed spec" defaults to current spec each session.

### 9.5 Stat-priority sub-section
For spec-aware categories, an embedded inline group:
```lua
statPriorityGroup = {
    type = "group", inline = true, name = "Stat Priority for this spec",
    args = {
        primary = { type="select", values={STR=...,AGI=...,INT=...}, get=..., set=..., order=1 },
        sec1 = { type="select", values={CRIT=...,HASTE=...,MASTERY=...,VERSATILITY=...}, name="Secondary #1", order=2, get/set... },
        sec2 = { ... order=3 ... },
        sec3 = { ... order=4 ... },
        sec4 = { ... order=5 ... },
        reset = { type="execute", name="Reset to default", func=..., order=6 },
    }
}
```

---

## 10. Edge Cases and Error Handling

| Edge case | Handling |
|-----------|----------|
| Macro pool full (120 account-wide macros already exist) | `CreateMacro` returns `nil`; MacroManager prints a one-time warning to chat and skips. Existing `KCM_*` macros (already adopted) continue to work. |
| `EditMacro` returns 0 (failure) | Log via Debug.Print; macroState NOT updated so next event retries. |
| User adds a non-existent itemID | `validate` callback rejects in the input widget. |
| User adds an item that doesn't match any classifier | Allowed — user knows best. Item appears in candidate set with no auto-rank score (sorted last). |
| Spec ID returned by `GetSpecializationInfo` is not in our defaults | SpecHelper falls back to a sensible neutral priority (`MASTERY > HASTE > CRIT > VERSATILITY` for DPS; `INT` primary for caster classes via classID lookup). |
| Player has no spec selected (rare, low-level) | Spec-aware categories use a `_NEUTRAL_` key with neutral defaults; macros still get written. |
| Tooltip parse failure (item data never loads) | Item is treated as score=0; sorted last. Logged via Debug.Print. |
| Bag scan returns same set across recomputes | `MacroManager.SetMacro` early-returns when `lastBody == newBody` — no API call, no taint risk. |
| User renames a `KCM_*` macro out of band | Next recompute can't find it by name; addon creates a new one. Old renamed macro is left alone (no destructive action). |
| `/kcm resync` during combat | Prints "Cannot resync during combat" and bails. |

---

## 11. Performance Budget

A full `Pipeline.Recompute` does:
1. One bag scan (~5 bags × ~30 slots = 150 `GetContainerItemInfo` calls). ~1ms.
2. One `Selector.GetEffectivePriority` per category × 8 categories. Each is ~50 candidates max → ~50 cached tooltip lookups. ~1ms total.
3. One `MacroManager.SetMacro` per category × 8. Most early-return (no body change). When body changes, 1 `EditMacro` call. ~0.1ms each.

Total: ~3 ms per recompute. Recomputes coalesced to 1/frame. Well within budget.

---

## 12. Testing Strategy

WoW addons can't be unit-tested in the usual sense, but the design admits manual verification:

- **Pure functions** (Ranker, Selector pin-merge, TooltipCache parsing) can be sanity-checked by `/kcm dump <category>` (debug-mode-only command added later if needed) which prints the effective priority list with scores.
- **In-game smoke test checklist** (will be the EXECUTION_PLAN.md milestone gates):
  1. Fresh install → 8 macros appear in account-wide pool with correct names.
  2. Loot a flask → `KCM_FLASK` icon updates to that flask within 1 second.
  3. Switch spec → `KCM_FLASK` / `KCM_CMBT_POT` / `KCM_STAT_FOOD` icons change to spec's preference.
  4. Enter combat, loot a better flask, leave combat → macro updates on regen.
  5. Add an item via UI → appears in priority list, ranks correctly.
  6. Pin an item to position 1 → moves to top, persists across `/reload`.
  7. Block an item → removed from list, persists.
  8. Open a spec-aware page, switch viewed spec → list changes to that spec's data.

---

## 13. Sign-Off Checklist

Reading this doc, please confirm:

1. **Module split** is sensible (Core/MacroManager/Selector/Ranker/Classifier/BagScanner/TooltipCache/SpecHelper/Options/SlashCommands/Debug).
2. **AceDB schema** fits — single profile, candidate set computed at runtime as `seed ∪ added ∪ discovered − blocked`, pins as `[{id, pos}]`.
3. **Pin-merge algorithm** behaves as you'd expect (§5.3).
4. **Combat deferral** model (queue body in MacroManager, flush on `PLAYER_REGEN_ENABLED`) is acceptable.
5. **Settings UI** built via AceConfig with row-as-cluster-of-widgets (no drag-reorder; arrows only) is acceptable.
6. **Tooltip patterns** are reasonable for English-only.
7. **Score formulas in §5.4** look right at a glance — happy to tune any specific numbers.

Once confirmed, I'll write EXECUTION_PLAN.md.
