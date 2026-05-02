# Data model

AceDB schema, the opaque-numeric ID convention, the composite-bucket shape, and the discovered-set garbage collector.

## AceDB profile (one profile, account-wide)

`KCM.dbDefaults.profile` (declared in `Core.lua`):

```
db.profile
├── schemaVersion        1
├── debug                boolean
├── categories
│   ├── FOOD  │ DRINK │ HP_POT │ MP_POT │ HS    ← single-pick, non-spec-aware
│   │   ├── added       { [id] = true }                  -- user-added items + spells
│   │   ├── blocked     { [id] = true }                  -- never enters candidate set
│   │   ├── pins        { { id = N, position = K }, ... } -- override Ranker order
│   │   └── discovered  { [id] = unixTimestamp }         -- last-seen-in-bags
│   ├── STAT_FOOD │ CMBT_POT │ FLASK            ← single-pick, spec-aware
│   │   └── bySpec
│   │       └── ["<classID>_<specID>"]
│   │           ├── added
│   │           ├── blocked
│   │           ├── pins
│   │           └── discovered
│   └── HP_AIO  │ MP_AIO                        ← composite (no item buckets)
│       ├── enabled            { [refKey] = boolean }
│       ├── orderInCombat      { refKey, refKey, ... }
│       └── orderOutOfCombat   { refKey, ... }
├── statPriority
│   └── ["<classID>_<specID>"] = { primary, secondary[] }   -- user overrides only
└── macroState
    └── [macroName] = { lastItemID, lastBody, lastIcon, lastCat }   -- early-out cache
```

### Field semantics

- **`added[id] = true`** — user-added entry (item or spell sentinel). Persists across bag changes.
- **`blocked[id] = true`** — user-blocked entry; subtracted from the candidate set. Auto-discovery cannot re-add a blocked id.
- **`pins`** — array of `{ id, position }`. Pinned entries land at their requested position; non-pinned entries fill the gaps in score order. Top-to-bottom ordering.
- **`discovered[id] = <unixTimestamp>`** — auto-discovered item, with last-sighting timestamp used by the GC sweep. Items only — bag discovery cannot find spells.
- **`statPriority[<spec>]`** — optional. Missing entries fall back to the seed default (`Defaults_StatPriority.lua`); if the seed is also missing, the class-primary default is used.
- **`macroState`** — fingerprint cache for `MacroManager`'s "unchanged" early-out. `lastIcon` was added in v1.2.0 to support the `DYNAMIC_ICON` migration; `lastCat` lets `MacroManager` reason about which category owns a slot.

### Effective candidate set

Computed at recompute time in `Selector.BuildCandidateSet`:

```
candidates = (seed[cat] ∪ added[cat] ∪ discovered[cat]) − blocked[cat]
```

Seeds live in `KCM.SEED.<CATKEY>` Lua constants, **not** in SavedVariables — that's why updating a `defaults/Defaults_*.lua` file is a zero-migration upgrade for existing users.

### Migrations

`schemaVersion` stays at `1`. The discovered-set format change in v1.1.0 (`true` → unix timestamp) is forward-compatible via lazy coercion (see [Discovered-set GC](#discovered-set-gc) below). A real `Migrations.lua` shim only lands when an actually-incompatible change is introduced.

## Composite bucket shape

Composites (HP_AIO, MP_AIO) compose other categories' picks via `[combat]` / `[nocombat]` macro conditionals — they don't run their own ranker. The persisted state is just a per-ref enabled flag plus two ordered ref arrays:

```lua
HP_AIO = {
    enabled          = { HS = true, HP_POT = true, FOOD = true },
    orderInCombat    = { "HS", "HP_POT" },
    orderOutOfCombat = { "FOOD" },
}
```

- `enabled[ref] ~= false` defaults to true when the field is unset (e.g. for refs added later via Categories metadata that aren't yet in the saved bucket).
- `orderInCombat` and `orderOutOfCombat` are arrays of single-category keys. Sub-categories are **locked to their section** — HS / HP_POT / MP_POT only ever appear in `inCombat`; FOOD / DRINK only ever in `outOfCombat`. The Options panel enforces this; `Pipeline.RecomputeOne` doesn't double-check.
- Composites have no `added` / `blocked` / `pins` / `discovered` buckets — picks come from the underlying single categories at recompute time.

The composite body is assembled by `MacroManager.SetCompositeMacro` (see [macro-manager.md](./macro-manager.md#composite-body-assembly)).

## Opaque-numeric ID convention

Priority-list entries are **opaque numeric IDs** that the pipeline treats uniformly. The sign encodes the kind:

- **Positive** → itemID.
- **Negative** → spell sentinel. The spell's ID is `math.abs(id)`.

Conversions and predicates live in `KCM.ID` (declared in `Core.lua`):

```lua
KCM.ID.AsSpell(spellID)  -- returns -spellID
KCM.ID.IsSpell(id)       -- id < 0
KCM.ID.IsItem(id)        -- id > 0
KCM.ID.SpellID(id)       -- -id when spell, else nil
KCM.ID.ItemID(id)        -- id when item, else nil
```

Seed files compose spell entries via `KCM.ID.AsSpell(spellID)` for readability — e.g. `KCM.ID.AsSpell(1231411)` for Recuperate.

### Fork sites

The Selector, pins / added / blocked / discovered tables, Ranker context tables, and most of the pipeline treat these as opaque numeric keys — a negative key works identically to a positive one through every table. **Only three call sites fork on the sign:**

1. `MacroManager` body builders → `/use item:<id>` for items, `/cast <Spell>` for spells (single-pick); `item:<id>` token vs spell name for `/castsequence` (composite).
2. `Ranker.Score` → spell entries short-circuit to a fixed `SPELL_SCORE` above every item (no tooltip lookup).
3. UI widgets (`KCMItemRow`, `KCMMacroDragIcon`) → `GameTooltip:SetSpellByID` vs `:SetItemByID` for hover tooltips.

Keep it that way. No new side channels — every other layer should treat IDs as plain table keys.

### Discovery accepts items only

`Selector.MarkDiscovered` rejects spells (bag discovery can't find them). `Selector.AddItem` accepts both, so the Options panel's Item / Spell picker can seed either kind.

## Discovered-set GC

### The problem

In v1.0.0, `discovered[id] = true` accumulated forever. One-shot consumables looted months ago stayed in the priority list as "not in bags" rows.

### The fix

`discovered[id] = <unixTimestamp>` — the last time the id was seen in `BagScanner.Scan()`'s output. `Selector.MarkDiscovered(catKey, id, specKey, nowUnix)` writes / bumps the timestamp.

### Lazy migration of legacy `true` values

- Reader (`Selector.BuildCandidateSet`, GC sweep) treats `true` as "age unknown".
- `Selector.MarkDiscovered` is idempotent: writes `nowUnix` whether the entry was missing, `true`, or stale.
- Next bag scan that sees the id bumps the timestamp.
- Legacy `true` values that are **not** seen within the TTL get swept on the next sweep.

### Sweep trigger

`PLAYER_ENTERING_WORLD`, after auto-discovery and before the first recompute. Pseudo-code:

```
SweepStaleDiscovered(nowUnix):
    cutoff   = nowUnix - 30 * 86400        -- 30-day TTL
    bagCounts = BagScanner.Scan()
    for each category, for each bucket:
        for id, ts in pairs(bucket.discovered):
            if bagCounts[id] and bagCounts[id] > 0:
                bucket.discovered[id] = nowUnix       -- bump; never sweep owned items
            else:
                staleTs = (ts == true) and 0 or ts
                if staleTs < cutoff:
                    bucket.discovered[id] = nil        -- drop: stale
```

TTL is the only gate. A classifier re-check on stale entries was considered and dropped — if a subType rename re-classifies an id under a different category, the stale entry times out on its own within 30 days of bag absence.

### What's never swept

- `added[id]` — user intent.
- `blocked[id]` — user intent.
- Only `discovered` is subject to GC.

### Manual trigger

There isn't one. `/cm resync` does a full rescan but **does not** include a GC sweep — that's an explicit PEW-only policy. If demand emerges, a `/cm gc` variant is trivial to add.

## Reset path

`KCM.ResetAllToDefaults(reason)` in `Core.lua` is the one place that wipes `categories` + `statPriority` back to `dbDefaults`. Both the Options "Reset all priorities" button and `/cm reset`'s StaticPopup delegate to it so semantics stay identical regardless of entry point.

After the DB wipe, the function drives a full resync: `TooltipCache.InvalidateAll` → `RunAutoDiscovery` → `Pipeline.Recompute`. Macro writes that land in combat defer via the pending queue, so this is safe to run without a combat guard.

`macroState` is **not** wiped — live macros stay valid. If you need the macros re-issued unconditionally, use `/cm rewritemacros`, which calls `MacroManager.InvalidateState()` to clear `macroState` + `pendingUpdates` and then re-runs the pipeline.
