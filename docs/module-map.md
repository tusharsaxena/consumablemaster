# Module map

Per-module roles + public APIs. Pair this with [pipeline.md](./pipeline.md) for how the modules talk to each other.

```
Core.lua ───────── AceAddon entry. OnInitialize creates the DB;
                   Pipeline.Recompute / RequestRecompute orchestrate
                   every recompute; event handlers live at the bottom.
                   Also houses KCM.ID sentinel helpers (AsSpell /
                   IsSpell / IsItem / SpellID / ItemID).

Debug.lua ──────── KCM.Debug.Print — gated on db.profile.debug.

defaults/         Seed data only. Evaluated at load; writes to
├── Categories.lua        KCM.Categories.LIST + KCM.Categories.BY_KEY
├── Defaults_StatPriority.lua    → KCM.SEED.STAT_PRIORITY
└── Defaults_*.lua         → KCM.SEED.<CATKEY>
                           Entries can be itemIDs or KCM.ID.AsSpell(sid)
                           sentinels (e.g. Recuperate in FOOD).

SpecHelper.lua ── Class/spec identity. Spec keys are "<classID>_<specID>".
                   GetStatPriority merges user override → seed → class fallback.

TooltipCache.lua  C_TooltipInfo.GetItemByID(id) → parsed struct cached per
                   session. Invalidate(id) on GET_ITEM_INFO_RECEIVED.
                   Parser handles NBSP + |4singular:plural; grammar escapes,
                   captures healOverSec / manaOverSec so the Ranker can
                   tell immediate pots from heal-over-time pots.

BagScanner.lua ── C_Container.GetContainerItemInfo sweep → { [id] = count }.
                   Stateless per-call.

Classifier.lua ── (itemID) → which of the 8 single-pick categories. Reads
                   subType + parsed tooltip. FLASK is subType-only (tooltip-
                   free) so first-bag-scan discovery is deterministic for
                   already-cached flasks.

Ranker.lua ────── Pure scorers per category. Spec-aware scorers weight stats
                   against { primary, secondary[] } from SpecHelper. Spell
                   entries short-circuit to a fixed SPELL_SCORE above any
                   item. HP_POT / MP_POT apply an immediate-pot bonus that
                   HOT candidates only earn when their amount beats the
                   best-immediate in the set by >20%.

Selector.lua ──── Owns the candidate set ((seed ∪ added ∪ discovered) − blocked),
                   drives Ranker, merges pins (user overrides), returns the
                   effective priority list. PickBestForCategory returns the
                   first entry the player actually owns — bag-count for
                   items, IsPlayerSpell for spell sentinels.

MacroManager.lua  The ONLY module that calls CreateMacro / EditMacro.
                   SetMacro for single picks, SetCompositeMacro for HP_AIO
                   and MP_AIO. Combat-deferral queue, fingerprint cache,
                   bounded flush retry, action-bar icon convention.
                   Detail in macro-manager.md.

Options.lua ───── AceConfig option table built from KCM.Categories.LIST.
                   Settings.RegisterVerticalLayoutCategory parent + one
                   AceConfigDialog:AddToBlizOptions sub-page per top-level
                   group. Settings.Schema + Helpers drive both panel widgets
                   and /cm list / get / set.

SlashCommands.lua /cm (and /consumablemaster alias) dispatcher. Three
                   ordered tables: COMMANDS, DUMP_TARGETS, and the
                   *_COMMANDS verb namespaces. say() helper prepends the
                   cyan [CM] prefix. Detail in debug.md.

KCM*.lua         AceGUI custom widgets registered via dialogControl =
                  "KCM<Name>" from Options. Detail in file-index.md.
```

## Public APIs

### Core (`Core.lua`)

```lua
-- Lifecycle
KCM:OnInitialize()                           -- AceDB, slash registration, Options register
KCM:OnEnable()                               -- event subscriptions

-- Pipeline (also see pipeline.md)
KCM.Pipeline.RequestRecompute(reason)        -- frame-coalesced entry point
KCM.Pipeline.Recompute(reason)               -- iterates categories, with pcall + score cache
KCM.Pipeline.RecomputeOne(catKey, scoreCache, reason)  -- single category
KCM.Pipeline.RunAutoDiscovery(reason) -> n   -- bag scan + classifier + MarkDiscovered
KCM.Pipeline.DiscoverOne(itemID, reason, nowUnix?)  -- one-id retry path

-- Sentinel helpers (also see data-model.md)
KCM.ID.AsSpell(spellID)  -> negative
KCM.ID.IsSpell(id)       -> bool
KCM.ID.IsItem(id)        -> bool
KCM.ID.SpellID(id)       -> spellID | nil
KCM.ID.ItemID(id)        -> itemID  | nil

-- Centralized reset
KCM.ResetAllToDefaults(reason) -> bool       -- wipes categories + statPriority, runs
                                             --   InvalidateAll → RunAutoDiscovery → Recompute
```

### MacroManager — see [macro-manager.md](./macro-manager.md)

### Selector (`Selector.lua`)

```lua
-- Read
KCM.Selector.GetBucket(catKey, specKey?)               -> { added, blocked, pins, discovered }
KCM.Selector.BuildCandidateSet(catKey, specKey?)       -> array of ids
KCM.Selector.GetEffectivePriority(catKey, specKey?, scoreCache?) -> array of ids (sorted + pinned)
KCM.Selector.PickBestForCategory(catKey, specKey?, scoreCache?)  -> id | nil

-- Write (mutators)
KCM.Selector.AddItem(catKey, id, specKey?)             -> changed:bool   -- accepts items + spells
KCM.Selector.Block(catKey, id, specKey?)               -> changed:bool
KCM.Selector.Unblock(catKey, id, specKey?)             -> changed:bool
KCM.Selector.MoveUp(catKey, id, specKey?)              -> changed:bool
KCM.Selector.MoveDown(catKey, id, specKey?)            -> changed:bool
KCM.Selector.ClearPins(catKey, specKey?)               -> changed:bool
KCM.Selector.MarkDiscovered(catKey, id, specKey?, nowUnix) -> changed:bool   -- items only
KCM.Selector.SweepStaleDiscovered(nowUnix) -> droppedCount  -- 30-day TTL, PEW-only
```

`AddItem` also unblocks: if the id is in `blocked`, it's removed from there *and* added to `added`, so `changed = true` even when `added[id]` was already set.

### Ranker (`Ranker.lua`)

```lua
KCM.Ranker.Score(catKey, id, ctx, scoreCache?)         -> number
KCM.Ranker.SortCandidates(catKey, ids, ctx, scoreCache?) -> sorted ids
KCM.Ranker.BuildContext(catKey, itemIDs, existing, scoreCache?) -> ctx
KCM.Ranker.Explain(catKey, id, ctx) -> { {label, value, note?}, ... }
```

`ctx` carries spec priority for spec-aware scorers and per-set signals (e.g. `bestImmediateAmount` for HP_POT / MP_POT's 20% HOT rule).

### Classifier (`Classifier.lua`)

```lua
KCM.Classifier.Match(catKey, id, tt, subType) -> bool
KCM.Classifier.MatchAny(id) -> { catKeys }   -- used by auto-discovery
```

Per-category predicates are English-only against `subType` + parsed `tt`. The Midnight subtype renames live as `ST_*` constants at the top of the file.

### BagScanner (`BagScanner.lua`)

```lua
KCM.BagScanner.Scan() -> { [itemID] = count }     -- one pass; counts locked items
KCM.BagScanner.HasItem(itemID) -> bool, count     -- single C_Item.GetItemCount call
KCM.BagScanner.GetAllItemIDs() -> { itemIDs }
```

`HasItem` does not fall back to a full `Scan`. `C_Item.GetItemCount(id, false, false, true)` is trusted.

### TooltipCache (`TooltipCache.lua`)

```lua
KCM.TooltipCache.Get(itemID) -> { healValue, healValueAvg, healOverSec,
                                  manaValue, manaValueAvg, manaOverSec,
                                  isConjured, hasStatBuff, isFeast, buffDurationSec,
                                  statBuffs = { {stat, amount}, ... } }
KCM.TooltipCache.Invalidate(itemID)
KCM.TooltipCache.InvalidateAll()
KCM.TooltipCache.IsPending(itemID) -> bool
KCM.TooltipCache.PendingIDs() -> { itemIDs }
KCM.TooltipCache.IsUsableByPlayer(itemID) -> bool
KCM.TooltipCache.Stats() -> { total, pending }
```

If `C_TooltipInfo.GetItemByID` returns nil or empty, the cache marks the id `pending`. The first `GET_ITEM_INFO_RECEIVED` for that id invalidates the entry and triggers a recompute (for bag items only — see [pipeline.md GIIR split](./pipeline.md#giir-bagnon-bag-split)).

### SpecHelper (`SpecHelper.lua`)

```lua
KCM.SpecHelper.GetCurrent() -> classID, specID, specKey, specName
KCM.SpecHelper.MakeKey(classID, specID) -> "<classID>_<specID>"
KCM.SpecHelper.AllSpecs() -> { { classID, specID, specKey, specName }, ... }
KCM.SpecHelper.GetStatPriority(specKey) -> { primary, secondary = { ... } }
```

`GetStatPriority` merges in this order: user override (`db.profile.statPriority[specKey]`) → seed default (`KCM.SEED.STAT_PRIORITY[specKey]`) → class-primary fallback. There is no setter — user-override writes go directly through `db.profile.statPriority[specKey] = { primary, secondary }` (Options panel via the local `writeStatPriority` helper, slash CLI via `/cm stat primary` / `/cm stat secondary`).

### Options (`Options.lua`)

```lua
-- Lifecycle
KCM.Options.Register()       -- one-time, called from Core:OnInitialize
KCM.Options.Open()           -- opens panel directly to General

-- Refresh
KCM.Options.Refresh()        -- immediate: invalidate cache + NotifyChange
KCM.Options.RequestRefresh() -- trailing-edge debounced (1.0s quiet, 3.0s max wait)

-- Schema layer
KCM.Settings.Schema          -- ordered list of {panel, section, group, path, type, label, default, onChange?}
KCM.Settings.Helpers.Resolve(path) -> parent, key
KCM.Settings.Helpers.Get(path) -> value
KCM.Settings.Helpers.Set(path, section, value) -> bool
KCM.Settings.Helpers.SchemaForPanel(panelKey) -> { rows }
KCM.Settings.Helpers.FindSchema(path) -> row | nil
KCM.Settings.Helpers.ValidateSchema() -> errorCount
KCM.Settings.Helpers.SetAndRefresh(path, value) -> bool   -- write + onChange + refresh
KCM.Settings.Helpers.RestoreDefaults(panelKey)
KCM.Settings.Helpers.RefreshAllPanels()
```

`RequestRefresh` is the panel-side equivalent of pipeline coalescing — it collapses a burst of `GET_ITEM_INFO_RECEIVED`-driven `Pipeline.Recompute` runs into one panel rebuild. User-driven mutations (add / remove / move buttons) call `Refresh` directly via `afterMutation` for snappy click response. Detail in [pipeline.md GIIR split](./pipeline.md#giir-bagnon-bag-split).

### Debug (`Debug.lua`)

```lua
KCM.Debug.IsOn() -> bool
KCM.Debug.Toggle()   -- routes through Helpers.SetAndRefresh("debug", ...)
KCM.Debug.Print(fmt, ...)   -- conditional; early-returns when off
```

See [debug.md](./debug.md).

## Module publishing pattern

Every module uses the same idiom:

```lua
local KCM = _G.KCM
KCM.Foo = KCM.Foo or {}
local F = KCM.Foo
```

- Never overwrite an existing `KCM.Foo` without `or {}` — another file may have reached it first.
- Never make the local shadow the global (`local KCM = {}` would break everything downstream).
- Expose the public API on `F` (or `KCM.Foo` directly). Keep helpers `local` to the file.

## Load order

`ConsumableMaster.toc` is the source of truth. Order is dependency order, not alphabetical:

1. `embeds.xml` — LibStub + every Ace3 sub-library.
2. `Core.lua` — creates `KCM` via `AceAddon:NewAddon` and publishes `_G.KCM`. **Every other file assumes `_G.KCM` already exists.**
3. `Debug.lua`.
4. `defaults/Categories.lua` then each `defaults/Defaults_*.lua`.
5. Runtime modules: `SpecHelper` → `TooltipCache` → `BagScanner` → `Classifier` → `Ranker` → `Selector` → `MacroManager`.
6. AceGUI widgets: `KCMIconButton` → `KCMScoreButton` → `KCMHeading` → `KCMMacroDragIcon` → `KCMItemRow`.
7. `Options.lua`.
8. `SlashCommands.lua`.

Widgets load before `Options.lua` because `Options.lua` references their `dialogControl` names at table-build time. Event handlers and `Pipeline` functions are *defined* in `Core.lua` at the top of the file but only *called* from `OnEnable` / Ace event dispatch, which runs after every file has loaded — so the bodies can freely reference modules that load later.

If you add a new runtime file, put it in the right place in `ConsumableMaster.toc`.
