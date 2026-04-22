# Architecture — short form

This is the orient-yourself map. For the full design (DB schema, tooltip parsing rules, taint analysis, milestone decisions) read [docs/TECHNICAL_DESIGN.md](./docs/TECHNICAL_DESIGN.md).

---

## Module map

```
Core.lua ───────── AceAddon entry. OnInitialize creates the DB;
                   Pipeline.Recompute / RequestRecompute orchestrate
                   every recompute; event handlers live at the bottom.

Debug.lua ──────── KCM.Debug.Print — gated on db.profile.debug.

defaults/         Seed data only. Evaluated at load; writes to
├── Categories.lua        KCM.Categories.LIST + KCM.Categories.BY_KEY
├── Defaults_StatPriority.lua    → KCM.SEED.STAT_PRIORITY
└── Defaults_*.lua         → KCM.SEED.<CATKEY>

SpecHelper.lua ── Class/spec identity. Spec keys are "<classID>_<specID>".
                   GetStatPriority merges user override ▸ seed ▸ class fallback.

TooltipCache.lua  C_TooltipInfo.GetItemByID(id) → parsed struct cached per
                   session. Invalidate(id) on GET_ITEM_INFO_RECEIVED.
                   Parser handles NBSP + |4singular:plural; grammar escapes.

BagScanner.lua ── C_Container.GetContainerItemInfo sweep → { [id] = count }.
                   Stateless per-call.

Classifier.lua ── (itemID) → which of the 8 categories. Reads subType +
                   parsed tooltip. FLASK is subType-only (tooltip-free)
                   so first-bag-scan discovery is deterministic.

Ranker.lua ────── Pure scorers per category. Spec-aware scorers weight stats
                   against { primary, secondary[] } from SpecHelper.
                   Score(catKey, itemID, ctx) / SortCandidates(catKey, ids, ctx).

Selector.lua ──── Owns the candidate set (seed ∪ added ∪ discovered − blocked),
                   drives Ranker, merges pins (user overrides), returns the
                   effective priority list. PickBestForCategory returns the
                   first entry the player actually owns.
                   Also houses DB mutators: AddItem / Block / Unblock /
                   MoveUp / MoveDown / MarkDiscovered / ClearPins.

MacroManager.lua  The ONLY module that calls CreateMacro / EditMacro.
                   SetMacro compares body to lastBody (early-out on
                   unchanged), defers in-combat writes into pendingUpdates,
                   and FlushPending replays them on PLAYER_REGEN_ENABLED.

Options.lua ───── AceConfig option table built from KCM.Categories.LIST.
                   Registered to Blizzard Settings via
                   AceConfigDialog:AddToBlizOptions (returns frame + ID).
                   Refresh() is a NotifyChange passthrough — safe to call
                   unconditionally.

SlashCommands.lua /kcm dispatcher. DUMP_TARGETS is a single source of truth
                   so adding a dump name makes it appear in help output.
                   Owns the KCM_CONFIRM_RESET StaticPopup.
```

---

## Load order (`ConsumableMaster.toc`)

1. `embeds.xml` — LibStub + every Ace3 sub-library.
2. `Core.lua` — creates `KCM` via `AceAddon:NewAddon` and publishes `_G.KCM`. **Every other file assumes `_G.KCM` already exists.**
3. `Debug.lua`.
4. `defaults/Categories.lua` then each `defaults/Defaults_*.lua`.
5. Runtime modules in dependency order: `SpecHelper` → `TooltipCache` → `BagScanner` → `Classifier` → `Ranker` → `Selector` → `MacroManager` → `Options` → `SlashCommands`.

Event handlers and Pipeline functions are *defined* in `Core.lua` at the top of the file but only *called* from `OnEnable` / Ace event dispatch, which runs after every file has loaded. So the bodies are free to reference modules that load later.

---

## Pipeline (the recompute path)

```
event  ─▶  RequestRecompute(reason)
            │  sets _recomputePending, schedules C_Timer.After(0, ...)
            │  coalesces a flurry of events into one run.
            ▼
          Recompute(reason)
            │  for each category in Categories.LIST:
            │      RecomputeOne(catKey, reason)
            │         pick = Selector.PickBestForCategory(catKey)
            │         MacroManager.SetMacro(cat.macroName, pick, catKey)
            │  then Options.Refresh() — cheap NotifyChange passthrough.
            ▼
          per-category:
              Selector.GetEffectivePriority(catKey)
                  candidates = BuildCandidateSet(catKey)       -- pure
                  sorted     = Ranker.SortCandidates(...)      -- pure
                  final      = mergePins(sorted, bucket.pins)  -- pure
              walk final, return first itemID BagScanner says you own.
```

**Events** (wired in `Core:OnEnable`):

| Event                           | Handler                   | What it does                          |
|---------------------------------|---------------------------|----------------------------------------|
| `PLAYER_ENTERING_WORLD`         | `OnPlayerEnteringWorld`   | auto-discovery + RequestRecompute.    |
| `BAG_UPDATE_DELAYED`            | `OnBagUpdateDelayed`      | auto-discovery + RequestRecompute.    |
| `PLAYER_SPECIALIZATION_CHANGED` | `OnSpecChanged`           | RequestRecompute.                     |
| `PLAYER_REGEN_DISABLED`         | `OnRegenDisabled`         | `KCM._inCombat = true`.               |
| `PLAYER_REGEN_ENABLED`          | `OnRegenEnabled`          | `MacroManager.FlushPending()`.        |
| `GET_ITEM_INFO_RECEIVED`        | `OnItemInfoReceived`      | TooltipCache.Invalidate(id) + retry discovery + RequestRecompute. |

`GET_ITEM_INFO_RECEIVED` retry exists because `Classifier.Match` returns false while a tooltip is pending; without the retry, items present in bags from `/reload` silently skip discovery on the first pass.

---

## Data model (AceDB profile)

One profile, shared account-wide.

```
db.profile
├── schemaVersion        1
├── debug                boolean
├── categories
│   ├── FOOD   │ DRINK │ HP_POT │ MP_POT │ HS    ← simple:
│   │   ├── added       { [itemID] = true }
│   │   ├── blocked     { [itemID] = true }
│   │   ├── pins        { { itemID, position }, ... }
│   │   └── discovered  { [itemID] = true }
│   └── STAT_FOOD │ CMBT_POT │ FLASK            ← spec-aware:
│       └── bySpec
│           └── ["<classID>_<specID>"]
│               ├── added
│               ├── blocked
│               ├── pins
│               └── discovered
├── statPriority
│   └── ["<classID>_<specID>"] = { primary, secondary[] }   -- user overrides only
└── macroState
    └── [macroName] = { lastItemID, lastBody, lastCat }     -- early-out cache
```

`KCM.ResetAllToDefaults(reason)` in Core.lua is the one place that wipes `categories` + `statPriority` back to `dbDefaults`. Both the Options "Reset all" button and `/kcm reset`'s StaticPopup delegate to it so semantics stay identical. It also runs TooltipCache.InvalidateAll → RunAutoDiscovery → Recompute on every call.

---

## Invariants worth not breaking

- **`MacroManager` is the only caller of `CreateMacro` / `EditMacro`.** Classifier, Ranker, Selector, BagScanner, TooltipCache must all stay pure (no protected APIs) so the pipeline can run in combat without taint.
- **Macros are always identified by name**, never by slot index. `perCharacter=false` in the CreateMacro call puts them in the account-wide pool.
- **Seed lists are treated as data, not code.** Updating a `defaults/Defaults_*.lua` is a zero-migration upgrade for existing users because `added`/`discovered`/`blocked` live in SavedVariables and union with the seed at runtime.
- **English-only.** Classifier compares subType against literal strings (`"Potions"`, `"Food & Drink"`, `"Flasks & Phials"`) and TooltipCache patterns are English. If Blizzard renames a subtype, edit the `ST_*` constants in `Classifier.lua`.
- **Module publishing pattern:** every file does `KCM.Foo = KCM.Foo or {}; local F = KCM.Foo`. Never shadow the local over the global.
- **Recompute is coalesced.** Event handlers call `RequestRecompute`, never `Recompute` directly — except the rare direct path (Reset, `/kcm resync`) where we want the write to land this tick.

---

## External dependencies

All vendored under `libs/`:

- `LibStub`
- `CallbackHandler-1.0`
- `AceAddon-3.0`
- `AceEvent-3.0`
- `AceDB-3.0`
- `AceConsole-3.0`
- `AceGUI-3.0`
- `AceConfig-3.0` (pulls in AceConfigRegistry / AceConfigCmd / AceConfigDialog)

`embeds.xml` is the load manifest referenced from `ConsumableMaster.toc`.
