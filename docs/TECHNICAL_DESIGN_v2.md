# Ka0s Consumable Master — Technical Design v2

Companion to [REQUIREMENTS.md](./REQUIREMENTS.md). Where requirements answer *what*, this doc answers *how*.

**Supersedes** [TECHNICAL_DESIGN.md](./TECHNICAL_DESIGN.md) (the pre-1.0 plan). This v2 describes the addon as it will ship in **v1.1.0** — i.e. what actually shipped in v1.0.0 plus the post-launch hardening from PE review §§3–6 (critical bugs, high-priority issues, medium-priority issues, and performance items that survived the Q&A scoping). Items explicitly deferred live in [TODO.md](../TODO.md).

Read order if you only have ten minutes: §1 (arch) → §4 (schema) → §5 (opaque IDs) → §8 (pipeline) → §12 (discovered GC).

---

## 1. High-Level Architecture

```
                             ┌─────────────────────────────────────────┐
   WoW Events                │                   Core                  │
   ─────────────────────────►│ (AceAddon, AceEvent — single dispatch)  │
   PLAYER_ENTERING_WORLD     │                                         │
   BAG_UPDATE_DELAYED        │   Pipeline.Recompute()  ◄──── /kcm resync
   PLAYER_SPEC_CHANGED       │   (pcall per category, per-recompute    │
   PLAYER_REGEN_ENABLED      │    score cache, frame-coalesced)        │
   GET_ITEM_INFO_RECEIVED    └────┬─────────┬─────────┬────────┬───────┘
                                  │         │         │        │
                          ┌───────▼──┐  ┌───▼────┐ ┌──▼─────┐ ┌▼────────┐
                          │ Spec     │  │  Bag   │ │Tooltip │ │ Macro   │
                          │ Helper   │  │Scanner │ │ Cache  │ │ Manager │
                          └────┬─────┘  └───┬────┘ └────┬───┘ └────▲────┘
                               │            │           │          │
                          ┌────▼────────────▼───────────▼──┐       │
                          │           Selector             │───────┘
                          │  (uses Ranker + Classifier     │   best id
                          │   to build effective list,     │   per category
                          │   picks first owned entry)     │   (item or spell)
                          └────┬───────────────────────────┘
                               │
                ┌──────────────┴────────────┐
                │                           │
        ┌───────▼────────┐         ┌────────▼────────┐
        │   Ranker       │         │   Classifier    │
        │ score(id, ctx) │         │ does item match │
        │ by ilvl, qual, │         │ category? (used │
        │ tooltip data,  │         │ by auto-discov) │
        │ spec priority  │         └─────────────────┘
        │ + per-recompute│
        │   score cache  │
        └────────────────┘

   ┌─────────────────────────────────────────────────────────────────┐
   │  AceDB (ConsumableMasterDB)                                     │
   │  └── profile = single (account-wide by design)                  │
   │       ├── debug                                                 │
   │       ├── schemaVersion                                         │
   │       ├── categories.<CAT>.{added,blocked,pins,discovered}      │
   │       ├── categories.<SPEC_AWARE>.bySpec[classID_specID].{...}  │
   │       ├── statPriority[classID_specID]                          │
   │       └── macroState.<KCM_NAME>.{lastItemID, lastBody, lastCat} │
   └─────────────────────────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────────────────────────┐
   │  AceConfig + AceConfigDialog                                    │
   │  └── option-table generated from category metadata; custom      │
   │       AceGUI widgets render each priority-list row              │
   │       (KCMItemRow, KCMIconButton, KCMScoreButton, KCMHeading,   │
   │        KCMTitle, KCMMacroDragIcon).                             │
   └─────────────────────────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────────────────────────┐
   │  AceConsole — /kcm slash handler                                │
   └─────────────────────────────────────────────────────────────────┘
```

The pipeline is **pull-based**: an event triggers `Pipeline.RequestRecompute`; on the next frame, `Pipeline.Recompute` iterates categories and for each calls `Selector.PickBestForCategory(cat)` then `MacroManager.SetMacro(cat.macroName, pick, cat.key)`.

---

## 2. File Layout

Flat layout: `.toc` and `.lua` files sit at the repo root; design docs in `docs/`.

```
./
├── ConsumableMaster.toc          # Interface, deps, file order, SavedVariables
├── embeds.xml                    # XML include for Ace3 libs
├── libs/                         # vendored Ace3 + LibStub
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
│   └── AceGUI-3.0/...            # transitive dep of AceConfigDialog
├── Core.lua                      # AceAddon entry, Pipeline, events, KCM.ID, ResetAllToDefaults
├── Debug.lua                     # Conditional logger
├── SpecHelper.lua                # Spec identity + stat-priority resolution
├── TooltipCache.lua              # C_TooltipInfo parser + session cache
├── BagScanner.lua                # C_Container enumeration → {[itemID]=count}
├── Classifier.lua                # (itemID,tt,subType) → bool
├── Ranker.lua                    # Per-category scorers + Explain + SortCandidates + score cache
├── Selector.lua                  # Candidate set + pin merge + PickBestForCategory
├── MacroManager.lua              # The ONLY caller of CreateMacro/EditMacro
├── Options.lua                   # AceConfig panel
├── SlashCommands.lua             # /kcm dispatcher + StaticPopups
├── KCMItemRow.lua                # AceGUI row widget (icon + status + name + pick star)
├── KCMIconButton.lua             # AceGUI gold-hover icon button (↑/↓/×)
├── KCMScoreButton.lua            # AceGUI info-button (per-row score breakdown)
├── KCMHeading.lua                # AceGUI section heading
├── KCMTitle.lua                  # AceGUI page-title banner
├── KCMMacroDragIcon.lua          # AceGUI draggable macro icon
└── defaults/
    ├── Categories.lua            # KCM.Categories.LIST + BY_KEY
    ├── Defaults_StatPriority.lua # spec → {primary, secondary}
    ├── Defaults_Food.lua         # seed ids (incl. spell sentinels)
    ├── Defaults_Drink.lua
    ├── Defaults_StatFood.lua     # per-spec seeds
    ├── Defaults_HPPot.lua
    ├── Defaults_MPPot.lua
    ├── Defaults_Healthstone.lua
    ├── Defaults_CombatPot.lua
    ├── Defaults_Flask.lua
    └── README.md
```

`.toc` file order is dependency order, not alphabetical: `Core.lua` → `Debug.lua` → `defaults/Categories.lua` → other defaults → `SpecHelper.lua` → `TooltipCache.lua` → `BagScanner.lua` → `Classifier.lua` → `Ranker.lua` → `Selector.lua` → `MacroManager.lua` → `Options.lua` → `SlashCommands.lua` → KCM\* widgets.

---

## 3. Category Metadata Table

`defaults/Categories.lua` is the single source of truth for the 8 categories.

```lua
KCM.Categories.LIST = {
    { key="FOOD",      macroName="KCM_FOOD",      displayName="Basic / Conjured Food", specAware=false, rankerKey="food",     classifier="food"     },
    { key="DRINK",     macroName="KCM_DRINK",     displayName="Drink",                 specAware=false, rankerKey="drink",    classifier="drink"    },
    { key="STAT_FOOD", macroName="KCM_STAT_FOOD", displayName="Stat Food",             specAware=true,  rankerKey="statfood", classifier="statfood" },
    { key="HP_POT",    macroName="KCM_HP_POT",    displayName="Health Potion",         specAware=false, rankerKey="hppot",    classifier="hppot"    },
    { key="MP_POT",    macroName="KCM_MP_POT",    displayName="Mana Potion",           specAware=false, rankerKey="mppot",    classifier="mppot"    },
    { key="HS",        macroName="KCM_HS",        displayName="Healthstone",           specAware=false, rankerKey="hs",       classifier="hs"       },
    { key="CMBT_POT",  macroName="KCM_CMBT_POT",  displayName="Combat Potion",         specAware=true,  rankerKey="cmbtpot",  classifier="cmbtpot"  },
    { key="FLASK",     macroName="KCM_FLASK",     displayName="Flask",                 specAware=true,  rankerKey="flask",    classifier="flask"    },
}

KCM.Categories.BY_KEY = {}  -- built from LIST
```

Adding a category in the future = append a row, write a defaults file, add matcher/scorer/Explain entries, and seed the AceDB default. See `CLAUDE.md` "Add a new category" for the full recipe.

---

## 4. Saved Variables Schema (AceDB)

`ConsumableMasterDB`, single profile (per REQ §11.7):

```lua
KCM.dbDefaults = {
    profile = {
        schemaVersion = 1,     -- v1.1.0 keeps v1 (see §12 migration note)
        debug = false,
        categories = {
            FOOD     = { added = {}, blocked = {}, pins = {}, discovered = {} },
            DRINK    = { added = {}, blocked = {}, pins = {}, discovered = {} },
            HP_POT   = { added = {}, blocked = {}, pins = {}, discovered = {} },
            MP_POT   = { added = {}, blocked = {}, pins = {}, discovered = {} },
            HS       = { added = {}, blocked = {}, pins = {}, discovered = {} },
            STAT_FOOD = { bySpec = {} },
            CMBT_POT  = { bySpec = {} },
            FLASK     = { bySpec = {} },
        },
        statPriority = {
            -- ["<classID>_<specID>"] = { primary="AGI", secondary={"MASTERY","HASTE","CRIT","VERSATILITY"} }
        },
        macroState = {
            -- ["KCM_FOOD"] = { lastItemID = 12345, lastBody = "...", lastCat = "FOOD" }
        },
    },
}
```

**Field semantics:**

- `added[id] = true` → user-added id (item or spell sentinel; see §5).
- `blocked[id] = true` → user-blocked id; never appears in candidate set.
- `pins` → array of `{ id = X, position = N }`. Top-to-bottom ordering; non-pinned items fill the gaps in auto-rank order.
- `discovered[id] = <unixTimestamp>` → auto-discovered id, with last-sighting timestamp used by the GC sweep (see §12). **New in v1.1.0**: the value was `true` in v1.0.0; the v1.1.0 reader treats legacy `true` as a "never seen, eligible for sweep on next idle cycle" sentinel and overwrites with a real timestamp the first time the id is seen in bags. No explicit migration shim is needed — the schema is forward-compatible, so `schemaVersion` stays at 1.
- `statPriority[<spec>]` is optional — if missing, the addon falls back to the shipped default from `Defaults_StatPriority.lua`.
- `macroState.<name>.lastCat` lets `MacroManager` reason about the current category owning a slot (e.g. spell vs item tooltip fork in drag icon).

**Effective candidate set** (computed at recompute time, in `Selector.BuildCandidateSet`):

```
candidates = (seed[cat] ∪ added[cat] ∪ discovered[cat]) − blocked[cat]
```

Seeds live in `KCM.SEED.<CATKEY>` (Lua constants, not persisted). This is why updating a `defaults/Defaults_*.lua` is a zero-migration upgrade.

**Migrations.** `schemaVersion` is checked at `OnInitialize`. v1.1.0 does **not** bump it; the discovered-GC format change is backward-compatible via lazy coercion. A real migration shim lands in `Migrations.lua` only when an actually-incompatible change is introduced.

---

## 5. Opaque-Numeric ID Convention

The priority list does not just contain itemIDs — it contains **opaque numeric ids** that the pipeline treats uniformly. The sign encodes the kind:

- **Positive** → itemID.
- **Negative** → spell sentinel. The spell's ID is `math.abs(id)`.

Conversions and predicates live in `KCM.ID`:

```lua
KCM.ID.AsItem(itemID)    -- returns itemID
KCM.ID.AsSpell(spellID)  -- returns -spellID
KCM.ID.IsItem(id)        -- id > 0
KCM.ID.IsSpell(id)       -- id < 0
KCM.ID.ItemID(id)        -- id when item, else nil
KCM.ID.SpellID(id)       -- -id when spell, else nil
```

Seed files compose spell entries via `KCM.ID.AsSpell(spellID)`. The Selector, Ranker context, pins/added/blocked/discovered tables, and the rest of the pipeline treat these as opaque numeric keys. **Only three call sites fork on the sign:**

1. `MacroManager.SetMacro` → builds `/use item:N` or `/cast <spellname>`.
2. `Ranker.Score` → spell entries short-circuit to a rank-only score (no tooltip).
3. UI widgets (`KCMItemRow.RefreshDisplay`, `KCMMacroDragIcon.tooltip`) → choose `GameTooltip:SetItemByID` vs `SetSpellByID`.

`Selector.MarkDiscovered` rejects spells (bag discovery can't find them). `Selector.AddItem` accepts both (so the Options panel's Item/Spell picker can seed either).

---

## 6. Module Interfaces

### 6.1 Core

```lua
KCM:OnInitialize()              -- AceDB, KCM.ID, ResetAllToDefaults, options/slash registration
KCM:OnEnable()                  -- event subscriptions, initial Pipeline.RequestRecompute
KCM.Pipeline.RequestRecompute(reason)      -- frame-coalesced entry point
KCM.Pipeline.Recompute(reason)             -- iterates categories, with pcall + score cache
KCM.Pipeline.RecomputeOne(catKey, scoreCache, reason)  -- single category
KCM.ID.*                        -- sentinel helpers (see §5)
KCM.ResetAllToDefaults(reason)  -- centralized reset (used by slash + Options panel)
```

### 6.2 MacroManager (the only module allowed to call protected APIs)

```lua
KCM.MacroManager.SetMacro(macroName, id, catKey) -> "created" | "updated" | "unchanged" | "deferred" | "error"
    -- id = nil or ownership miss → writes empty-state stub
    -- positive → /use item:N
    -- negative → /cast <spellname>
    -- combat-locked → enqueues in pendingUpdates[macroName], returns "deferred"
    -- body > 255 bytes → falls back to empty-state body, prints one-shot error
    -- persists macroState on success; on failure, leaves macroState intact so next event retries
KCM.MacroManager.FlushPending()     -- called on PLAYER_REGEN_ENABLED; bounded retry (see below)
KCM.MacroManager.IsAdopted(macroName) -> boolean
KCM.MacroManager.BuildBody(id, catKey) -> string        -- pure helper, testable
```

Internal flow per call:

```
SetMacro(name, id, catKey):
    body = BuildBody(id, catKey)
    if #body > MACRO_BODY_LIMIT:
        body = empty-state stub; emit one-shot error to chat + Debug.Print
    if state.lastBody == body and pendingUpdates[name] is nil:
        return "unchanged"
    if pendingUpdates[name] and pendingUpdates[name].body == body:
        clear pendingUpdates[name]; return "unchanged"   -- M-5 dedupe
    if InCombatLockdown():
        pendingUpdates[name] = {body=body, id=id, catKey=catKey, attempts=0}
        return "deferred"
    idx = GetMacroIndexByName(name)
    if idx == 0: CreateMacro(name, icon, body, false)
    else:        EditMacro(name, nil, nil, body)
    persist macroState
    return "created"|"updated"
```

`FlushPending` (M-12):

```
FlushPending():
    for name, entry in pairs(pendingUpdates):
        ok, result = pcall(EditMacro, name, nil, nil, entry.body)
        if ok and result != 0:
            persist macroState[name]
            pendingUpdates[name] = nil
        else:
            entry.attempts += 1
            if entry.attempts >= MAX_FLUSH_ATTEMPTS:  -- e.g. 3
                print one-time chat error "KCM: giving up on <name>"
                pendingUpdates[name] = nil
```

### 6.3 Selector

```lua
KCM.Selector.GetBucket(catKey, specKey) -> { added, blocked, pins, discovered }
KCM.Selector.GetEffectivePriority(catKey, specKey) -> array of ids
KCM.Selector.PickBestForCategory(catKey, scoreCache) -> id | nil
    -- walks GetEffectivePriority, returns the first owned id (item in bags OR player spell)
KCM.Selector.AddItem(catKey, id, specKey)   -> changed:boolean    -- M-2: also returns true when unblocking
KCM.Selector.Block(catKey, id, specKey)     -> changed:boolean
KCM.Selector.Unblock(catKey, id, specKey)   -> changed:boolean
KCM.Selector.MoveUp / MoveDown              -> changed:boolean
KCM.Selector.MarkDiscovered(catKey, id, specKey, timestamp)   -- items only; stamps timestamp
KCM.Selector.SweepStaleDiscovered(catKey, specKey, nowUnix)   -- see §12
KCM.Selector.BuildCandidateSet(catKey, specKey) -> array of ids
```

`AddItem` (M-2 fix):

```lua
function S.AddItem(catKey, id, specKey)
    local bucket = S.GetBucket(catKey, specKey)
    if not bucket or not id then return false end
    local changed = false
    if bucket.blocked[id] then bucket.blocked[id] = nil; changed = true end
    if not bucket.added[id] then bucket.added[id] = true; changed = true end
    return changed
end
```

### 6.4 Ranker

```lua
KCM.Ranker.Score(catKey, id, ctx, scoreCache) -> number
KCM.Ranker.SortCandidates(catKey, ids, ctx, scoreCache) -> sorted ids
KCM.Ranker.Explain(catKey, id, ctx) -> { {label, value, note?}, ... }
KCM.Ranker.BuildContext(catKey, specKey) -> ctx    -- { specPriority = {...}, now = ... }
```

**H-4 score cache.** `scoreCache` is a `{ [id] = { fields=<itemFields>, score=<number> } }` table created once by `Pipeline.Recompute` and threaded through every `SortCandidates` / `PickBestForCategory` / `Score` call for that recompute. Before computing `itemFields(id)` or the scorer, `Score` checks the cache for a pre-existing entry and uses it if present. This collapses duplicate `TooltipCache.Get` + scorer work across the 8-category loop and across the single-call-per-category panel render.

Lifetime:

- Created at the top of `Pipeline.Recompute`.
- Passed into each `Pipeline.RecomputeOne` call.
- Passed into `Selector.PickBestForCategory`, which in turn hands it to `Ranker.SortCandidates` and `Ranker.Score`.
- Discarded when `Pipeline.Recompute` returns. A panel-only render (not from `Pipeline.Recompute`) passes `nil`; `Ranker` tolerates a nil cache and falls back to direct computation. Cache key is `id`; spec context is carried separately via `ctx`, and since one recompute processes one spec per category, there is no cross-spec key collision within a single cache lifetime.

Per-category scorers (unchanged from v1.0.0 except where noted) sum:

```
food/drink: (healValue or manaValue) + conjured-bonus + ilvl + quality*100
hppot/mppot: healValueAvg or manaValueAvg + ilvl + quality*100
hs: HEALTHSTONE_PREFERENCE[id] + ilvl
statfood / cmbtpot / flask: scoreByStatPriority(tt, ctx.specPriority) + ilvl + quality*QUALITY_WEIGHT
```

`PCT_WEIGHT = 1e4` for pct-based food (Midnight). Known open item: verify under current values — see §14.

### 6.5 Classifier

```lua
KCM.Classifier.Match(catKey, id, tt, subType) -> boolean
KCM.Classifier.MatchAny(id) -> array of catKeys       -- used by auto-discovery
```

Per-category predicates are English-text against `subType` + parsed `tt`. The Midnight subtype renames (`"Potion"` → `"Potions"`, `"Flask"`/`"Phial"` → `"Flasks & Phials"`) are absorbed here.

### 6.6 BagScanner

```lua
KCM.BagScanner.Scan() -> { [itemID] = count }         -- B-1: does NOT skip isLocked
KCM.BagScanner.HasItem(itemID) -> boolean, count      -- H-3: no full-Scan fallback
KCM.BagScanner.GetAllItemIDs() -> array of itemIDs
```

**B-1 fix.** `Scan()` iterates every slot and records items whose `info.itemID` is non-nil. It **does not** exclude `info.isLocked` — lock is transient (mailing, splitting, dragging) and unrelated to ownership.

**H-3 fix.** `HasItem` is:

```lua
function BS.HasItem(itemID)
    if not itemID then return false, 0 end
    local count = (C_Item and C_Item.GetItemCount)
        and C_Item.GetItemCount(itemID, false, false, true) or 0
    return count > 0, count
end
```

No full-bag-scan fallback. `C_Item.GetItemCount(id, false, false, true)` is trusted as the answer to "do I own this?". This fix also resolves the H-2 inconsistency between Selector's fallback path and `BagScanner.HasItem` by routing the Selector fallback through `BagScanner.HasItem` (single ownership predicate across the codebase).

### 6.7 TooltipCache

Unchanged parser interface from v1.0.0:

```lua
KCM.TooltipCache.Get(itemID) -> { healValue, healValueAvg, manaValue, manaValueAvg,
                                  isConjured, hasStatBuff, isFeast, buffDurationSec,
                                  statBuffs = { {stat, amount}, ... } }
KCM.TooltipCache.Invalidate(itemID)
KCM.TooltipCache.InvalidateAll()
KCM.TooltipCache.PendingIDs() -> array of ids
```

Parse details live in §10.

### 6.8 SpecHelper

```lua
KCM.SpecHelper.GetCurrent() -> { classID, specID, key, specName, className, classFile }
KCM.SpecHelper.AllSpecs() -> array
KCM.SpecHelper.GetStatPriority(specKey) -> { primary, secondary={...} }
```

### 6.9 Options

```lua
KCM.Options.Build() -> AceConfig option table
KCM.Options.Register()        -- one-time
KCM.Options.Refresh()         -- NotifyChange + cache invalidation
KCM.Options.RequestRefresh()  -- debounced variant
KCM.Options.Open()
```

The panel uses custom AceGUI widgets for row rendering; see §11.

### 6.10 SlashCommands

AceConsole-registered `/kcm` dispatcher. `DUMP_TARGETS` is the single source of truth for `/kcm dump <target>`. StaticPopup creation is defensive (never reassigns `StaticPopupDialogs`) to avoid the taint cascade.

### 6.11 Debug

```lua
KCM.Debug.IsOn() / Toggle() / Print(fmt, ...)
```

Conditional; early-returns when off. Safe to call unconditionally.

---

## 7. Event Handling and Combat Deferral

### 7.1 Subscriptions (in `Core:OnEnable`)

```
PLAYER_ENTERING_WORLD, BAG_UPDATE_DELAYED, PLAYER_SPECIALIZATION_CHANGED,
PLAYER_REGEN_ENABLED, PLAYER_REGEN_DISABLED, GET_ITEM_INFO_RECEIVED
```

### 7.2 Auto-discovery

`PLAYER_ENTERING_WORLD` and `BAG_UPDATE_DELAYED` both run `runAutoDiscovery()`:

```
scan = BagScanner.Scan()
for each itemID, count in scan:
    cats = Classifier.MatchAny(itemID)
    for cat in cats:
        Selector.MarkDiscovered(cat, itemID, specKey, timeNow)   -- bumps timestamp (§12)
Pipeline.RequestRecompute("bag_update" or "player_entering_world")
```

### 7.3 Combat lockdown

```
PLAYER_REGEN_DISABLED: KCM._inCombat = true
BAG_UPDATE_DELAYED in combat:
    Pipeline.RequestRecompute("bag_update_combat")
    → Recompute runs (pure modules only touch the work)
    → MacroManager.SetMacro: InCombatLockdown() true → enqueue
PLAYER_REGEN_ENABLED:
    KCM._inCombat = false
    MacroManager.FlushPending()   -- bounded retries (§6.2)
```

No protected API is called during combat. Selector, Ranker, Classifier, BagScanner, TooltipCache, SpecHelper are pure and combat-safe.

### 7.4 Spec change

`PLAYER_SPECIALIZATION_CHANGED` triggers a recompute of *all* categories.

---

## 8. Pipeline: Coalescing, Guarding, Score Cache

### 8.1 Coalescing

```lua
function P.RequestRecompute(reason)
    KCM._recomputePending = true
    KCM._recomputeReason  = reason or KCM._recomputeReason or "unknown"
    if KCM._recomputeScheduled then return end
    KCM._recomputeScheduled = true
    C_Timer.After(0, function()
        KCM._recomputeScheduled = false
        if not KCM._recomputePending then return end
        KCM._recomputePending = false
        P.Recompute(KCM._recomputeReason)
        KCM._recomputeReason = nil
    end)
end
```

Multiple events in the same frame collapse to a single `Recompute` call.

### 8.2 Guarded per-category recompute (H-1)

```lua
function P.Recompute(reason)
    local scoreCache = {}                 -- H-4: one cache per recompute
    for _, cat in ipairs(KCM.Categories.LIST) do
        local ok, err = pcall(P.RecomputeOne, cat.key, scoreCache, reason)
        if not ok then
            KCM.Debug.Print("Recompute %s failed: %s", cat.key, tostring(err))
        end
    end
    Options.RequestRefresh()              -- debounced panel refresh
end

function P.RecomputeOne(catKey, scoreCache)
    local pick = Selector.PickBestForCategory(catKey, scoreCache)
    MacroManager.SetMacro(cat.macroName, pick, catKey)
end
```

A bad scorer in one category can no longer break the other seven macros. The `pcall` cost is negligible (8 per recompute, recompute fires at most once per frame).

### 8.3 Score cache lifetime (H-4)

One plain Lua table, created in `Recompute`, passed into `RecomputeOne` → `PickBestForCategory` → `SortCandidates` → `Score`. Cache is `id`-keyed and tolerates the same `id` appearing across multiple categories: the cache stores `{ fields, score }` scoped by `(catKey, id)` (via a compound key) **or**, simpler, we make `scoreCache` a `{[catKey] = {[id] = {fields, score}}}` nested table. We use the nested-table form because Ranker scorers vary by category, and the same id would yield different scores per category. `itemFields` (the TooltipCache/ilvl/quality lookup) is shared across categories via a sibling `scoreCache.fields[id] = <itemFields>` subtable so TooltipCache lookups happen at most once per id per recompute.

Panel-only renders (not from `Recompute`) pass `nil` and fall back to direct computation. Ranker handles both paths.

Expected cost reduction: the PE review estimates ~5–10× cut on hot paths. Validated at M10's gate with before/after `GetTime()` instrumentation on `/kcm dump pick`.

---

## 9. First-Run / Defaults Seeding

`Core:OnInitialize`:

1. `self.db = LibStub("AceDB-3.0"):New("ConsumableMasterDB", KCM.dbDefaults, true)`.
2. `schemaVersion` is set to 1 on fresh install; v1.1.0 does not bump.
3. Defaults files are Lua constants (`KCM.SEED.FOOD = {12345, KCM.ID.AsSpell(1231411), ...}`), **not** copied into SavedVariables. Candidate set is computed at recompute time as `(seed ∪ added ∪ discovered) − blocked`.
4. Stat-priority defaults follow the same model: `KCM.SEED.STAT_PRIORITY[<spec>]`; only user overrides go into SavedVariables.
5. A first-run, discovery-driven recompute happens after `PLAYER_ENTERING_WORLD`.

---

## 10. Tooltip Parsing Details (Midnight gotchas)

### 10.1 Why parse

`C_Item.GetItemInfo` gives ilvl, quality, subType. Heal value, mana value, stat buffs, duration, conjured/feast flags live only in the tooltip text.

### 10.2 Known gotchas (do not regress)

- **Subtype renames.** `"Potion"` → `"Potions"`; `"Flask"`/`"Phial"` → `"Flasks & Phials"`. `Classifier.ST_*` constants absorb these.
- **`|4singular:plural;` grammar escapes.** `C_TooltipInfo.GetItemByID` returns raw template text. `TooltipCache.normalizeTooltipText` strips them.
- **Non-breaking spaces (U+00A0) between numbers and units.** Lua `%s` does not match NBSP; normalize first.
- **`GET_ITEM_INFO_RECEIVED` does not fire for cached items.** FLASK classification bypasses the tooltip gate (subType alone is sufficient) to avoid stalling on already-cached flasks.
- **Combat lockdown.** Only `MacroManager.SetMacro` can reach protected APIs. Keep it that way.
- **AceConfigDialog `AddToBlizOptions` returns `(frame, categoryID)`.** Always capture both; `Settings.OpenToCategory` needs the numeric ID.

### 10.3 Pending-state handling

If `C_TooltipInfo.GetItemByID` returns nil or empty, the cache marks the id `pending = true`. The first `GET_ITEM_INFO_RECEIVED` for that id invalidates the entry and triggers a recompute.

---

## 11. Settings UI

### 11.1 Why AceConfigDialog + custom widgets

AceConfigDialog gives us free Blizzard-Settings integration, NotifyChange re-render, and a declarative option table. What it lacks — rich rows with multiple labeled controls per line — we supply as custom AceGUI widgets.

### 11.2 Widget inventory

| Widget | Purpose |
|---|---|
| `KCMItemRow` | One priority-list row: status icon + item icon + name + pick star. Forks on `KCM.ID.IsSpell` for the tooltip (`SetSpellByID` vs `SetItemByID`). |
| `KCMIconButton` | Gold-hover icon button used for ↑, ↓, × and the Add-by-ID row. |
| `KCMScoreButton` | "i" info button. On hover, renders a per-item score breakdown from `Ranker.Explain`. |
| `KCMHeading` | Section heading, Blizzard-style. |
| `KCMTitle` | Page-title banner (22pt gold). `SetFontObject` intentionally no-ops AceConfigDialog's injected label styling — that's the hijack pattern. |
| `KCMMacroDragIcon` | Draggable macro icon. Places the `KCM_*` macro on an action bar. **B-2 fix**: the on-hover tooltip reads `macroState.lastItemID` and forks on `KCM.ID.IsSpell` to call `SetSpellByID(KCM.ID.SpellID(lastID))` vs `SetItemByID(lastID)`. Falls back to plain macro-name text when neither applies. |

### 11.3 Layout constants (M-10)

`KCMItemRow` offsets are derived from named constants (`OWNED_ICON_SIZE`, `ICON_GAP`, `ICON_SIZE`, `QUALITY_SIZE`, `QUALITY_GAP`, `PICK_SIZE`), not hardcoded numbers. Tweaking a constant propagates without silent desync.

### 11.4 Spec selector

A shared "Stat Priority" panel (with a single "Viewing spec" dropdown) replaces the per-category spec selector. Per-category pages render against the currently-viewed spec.

### 11.5 Refresh coalescing

`Options.RequestRefresh` debounces. `Options.Refresh` invalidates `O._cache` before calling `NotifyChange` so AceConfigDialog re-invokes `Build` on next read.

---

## 12. Discovered-Set Garbage Collection (new in v1.1.0)

### 12.1 Problem (PE M-1)

`discovered[id] = true` accumulated forever. One-shot consumables looted months ago stayed in the priority list as "not in bags" rows.

### 12.2 Format change

`discovered[id] = <unixTimestamp>` — last time the id was seen in the bag scanner's output. This is a semantic, not schema, change; `schemaVersion` stays at 1.

Lazy migration of legacy `true` values:

- Reader (`Selector.BuildCandidateSet`, GC sweep) treats `true` as "age unknown".
- `Selector.MarkDiscovered(cat, id, specKey, nowUnix)` is idempotent: if entry is missing OR `true` OR stale, writes `nowUnix`.
- Next bag scan that sees the id bumps the timestamp.
- Legacy `true` values that are NOT seen within the TTL get swept in the next sweep.

### 12.3 Sweep trigger

`PLAYER_ENTERING_WORLD`, after auto-discovery and before the first recompute.

Pseudo-code:

```
SweepStaleDiscovered():
    now = time()
    cutoff = now - 30 * 86400        -- 30-day TTL
    bagCounts = BagScanner.Scan()
    for each category:
        for each bucket (spec-aware: all specs; non-spec-aware: the flat bucket):
            for id, ts in pairs(bucket.discovered):
                inBags = bagCounts[id] and bagCounts[id] > 0
                if inBags:
                    bucket.discovered[id] = now       -- bump; never sweep owned items
                else:
                    staleTs = (ts == true) and 0 or ts
                    if staleTs < cutoff:
                        bucket.discovered[id] = nil   -- drop: stale
```

TTL is the only gate — a classifier re-check was considered but dropped to keep scope tight. If a subType rename later re-classifies an id under a different category, the stale entry still times out on its own within 30 days of bag absence.

The `added` and `blocked` sets are **never** swept (user-intentional data).

### 12.4 Manual trigger

Not required for v1.1.0. Users can force a full resync via `/kcm resync`, which does not include a GC sweep (explicit PEW-only policy). If demand emerges, a `/kcm gc` variant is trivial to add.

---

## 13. Edge Cases and Error Handling

| Edge case | Handling |
|---|---|
| Macro pool full (120 account-wide already exist) | `CreateMacro` returns nil/0; MacroManager logs one-time error. Existing `KCM_*` macros continue. |
| `EditMacro` returns 0 | Increments `pendingUpdates[name].attempts`; bounded retry (§6.2) to avoid infinite regen loops (M-12). |
| User adds a non-existent ID | `validate` callback rejects in the input widget (itemID or spellID). |
| Item classifies into no category | Allowed — user knows best. Enters candidate set with score=0; sorted last. |
| Spec-aware category without a current spec | `GetEffectivePriority` returns `{}`; `PickBestForCategory` returns nil; empty-state body written. No-op edge. |
| Tooltip never loads | `pending=true` entry; score treated as 0 until `GET_ITEM_INFO_RECEIVED`. |
| Body > 255 bytes (M-6) | Fall back to empty-state stub; emit one-shot chat + Debug.Print error naming the category. |
| Spell name unresolvable | `MacroManager.buildActiveBody` writes the error-print stub; `PLAYER_SPECIALIZATION_CHANGED` / `BAG_UPDATE_DELAYED` / `GET_ITEM_INFO_RECEIVED` will retrigger recompute when state changes. `LEARNED_SPELL_IN_TAB` one-shot listener is deferred (see TODO). |
| Locked items in bags (B-1) | Scanner counts them. Macro does not flap during mailing / splitting / equipping. |
| Drag-icon tooltip for spell pick (B-2) | Forks on `KCM.ID.IsSpell`; uses `SetSpellByID` for spells. |
| User renames a `KCM_*` macro | Next recompute can't find the name; addon creates a fresh one. Renamed macro is left alone — addon never deletes. |
| `/kcm resync` during combat | Prints a message and bails; recompute on next regen. |

---

## 14. Open Questions / Known Gaps

### 14.1 `Ranker.PCT_WEIGHT` verification (PE M-8)

`PCT_WEIGHT = 1e4` amplifies pct-based Midnight food so it outranks flat tiers. Unverified on live level-cap values — at 3M HP, 7% = 210k, which should beat most flat-value foods, but the constant was not tuned against shipping Midnight numbers.

**Test recipe:**

1. Level-cap character with ~3M HP.
2. Bags contain the highest-tier flat-value food AND the highest-tier pct-value food available in Midnight.
3. `/kcm dump pick FOOD` — inspect the score breakdown. Pct food should win.
4. If flat food wins, either (a) bump `PCT_WEIGHT` to `1e5`, or (b) rewrite the score contribution as `pct/100 * UnitHealthMax("player")` so the two flavours are compared in absolute-restore terms.

Parked in [TODO.md](../TODO.md) until a verified test is done in-game.

### 14.2 Deferred polish from PE review

See the "Deferred from PE review" block in [TODO.md](../TODO.md): M-3 unused param, M-4 legacy GetItemInfo migration, M-11 refresh debounce reset, H-5 reason tracking, P-5 NotifyChange-when-closed, L-7 DRY scorers. None of these are bugs.

---

## 15. Performance Budget

Hot paths: PEW (login + reload), `BAG_UPDATE_DELAYED` storms, `GET_ITEM_INFO_RECEIVED` bursts, Options panel open/refresh.

Expected per-recompute cost after v1.1.0 changes:

1. **BagScanner.Scan** — one pass, ~5 bags × ~30 slots. Unchanged. ~1ms.
2. **Ranker score cache** — on a full 8-category recompute covering ~50 total candidates, TooltipCache + scorer work is incurred once per (catKey, id). Estimated 3–5× reduction vs v1.0.0 on warm cache, 8–10× on cold cache (per PE H-4).
3. **BagScanner.HasItem** — single `C_Item.GetItemCount` call (H-3 removed the fallback `Scan`). `GET_ITEM_INFO_RECEIVED` bursts during first panel open are near-free.
4. **MacroManager.SetMacro** — unchanged; early-returns "unchanged" when body matches (with M-5 dedupe for queued pending writes).
5. **Pipeline pcall guard** — 8 pcalls per recompute. Negligible.

Recompute is frame-coalesced to ≤1 per frame. End-to-end target remains ~3ms per recompute under normal conditions, dropping below 1ms when the score cache is warm.

---

## 16. Testing Strategy

There are no automated tests today. PE §11 recommends a WoW-stub-based unit harness for the pure modules (Selector, Ranker, Classifier, TooltipCache, BagScanner — all side-effect-free). That work is not in v1.1.0 scope.

Manual validation remains the source of truth. Each v1.1.0 milestone in [EXECUTION_PLAN_v2.md](./EXECUTION_PLAN_v2.md) defines its own in-game smoke test gate.

---

## 17. Sign-Off Checklist

Reading this doc, please confirm:

1. **Opaque-numeric ID convention (§5)** is the right model and the three fork sites are correctly enumerated.
2. **AceDB schema (§4)** stays at `schemaVersion = 1` with lazy coercion of `discovered[id] = true` → timestamp. No `Migrations.lua` shim in v1.1.0.
3. **Discovered-set GC (§12)** — 30-day TTL, PEW-only sweep, classifier re-check on stale entries, `added`/`blocked` never touched.
4. **H-4 score cache (§8.3)** — one nested `{[catKey]={[id]=...}}` table per `Pipeline.Recompute`, with a sibling `scoreCache.fields[id]` for shared TooltipCache lookups. Panel-only renders pass `nil`.
5. **M-6 body truncation** — empty-state fallback + one-shot chat error + Debug.Print. Preferable to silent truncation.
6. **M-12 flush retry** — bounded attempt count in `pendingUpdates[name].attempts`; one-time chat notice on give-up.
7. **Widget inventory (§11.2)** and the drag-icon B-2 fork on `KCM.ID.IsSpell` look right.

Once confirmed, I'll write `docs/EXECUTION_PLAN_v2.md`.
