# Architecture — short form

This is the orient-yourself map. For the full design (DB schema, tooltip parsing rules, taint analysis, milestone decisions) read [docs/TECHNICAL_DESIGN.md](./docs/TECHNICAL_DESIGN.md).

---

## Module map

```
Core.lua ───────── AceAddon entry. OnInitialize creates the DB;
                   Pipeline.Recompute / RequestRecompute orchestrate
                   every recompute; event handlers live at the bottom.
                   Also houses the KCM.ID sentinel helpers
                   (AsSpell/IsSpell/IsItem/SpellID/ItemID) — the
                   positive-item / negative-spell encoding for
                   priority-list IDs.

Debug.lua ──────── KCM.Debug.Print — gated on db.profile.debug.

defaults/         Seed data only. Evaluated at load; writes to
├── Categories.lua        KCM.Categories.LIST + KCM.Categories.BY_KEY
├── Defaults_StatPriority.lua    → KCM.SEED.STAT_PRIORITY
└── Defaults_*.lua         → KCM.SEED.<CATKEY>
                           Entries can be itemIDs or KCM.ID.AsSpell(sid)
                           sentinels (e.g. Recuperate in Food).

SpecHelper.lua ── Class/spec identity. Spec keys are "<classID>_<specID>".
                   GetStatPriority merges user override ▸ seed ▸ class fallback.

TooltipCache.lua  C_TooltipInfo.GetItemByID(id) → parsed struct cached per
                   session. Invalidate(id) on GET_ITEM_INFO_RECEIVED.
                   Parser handles NBSP + |4singular:plural; grammar escapes,
                   captures healOverSec / manaOverSec so the Ranker can
                   tell immediate pots from heal-over-time pots.

BagScanner.lua ── C_Container.GetContainerItemInfo sweep → { [id] = count }.
                   Stateless per-call.

Classifier.lua ── (itemID) → which of the 8 categories. Reads subType +
                   parsed tooltip. FLASK is subType-only (tooltip-free)
                   so first-bag-scan discovery is deterministic.

Ranker.lua ────── Pure scorers per category. Spec-aware scorers weight stats
                   against { primary, secondary[] } from SpecHelper. Spell
                   entries short-circuit to a fixed SPELL_SCORE above any
                   item. HP_POT / MP_POT apply an immediate-pot bonus that
                   HOT candidates only earn when their amount beats the
                   best-immediate in the set by >20%.
                   Score / SortCandidates / BuildContext (pre-computes
                   per-set signals like bestImmediateAmount) /
                   Explain (structured per-signal breakdown consumed by
                   the Options score-button tooltip).

Selector.lua ──── Owns the candidate set (seed ∪ added ∪ discovered − blocked),
                   drives Ranker, merges pins (user overrides), returns the
                   effective priority list. PickBestForCategory returns the
                   first entry the player actually owns — bag-count for
                   items, IsPlayerSpell for spell sentinels.
                   DB mutators: AddItem (items and spells) / Block / Unblock /
                   MoveUp / MoveDown / MarkDiscovered (items only) /
                   ClearPins.

MacroManager.lua  The ONLY module that calls CreateMacro / EditMacro.
                   SetMacro compares body to lastBody (early-out on
                   unchanged), defers in-combat writes into pendingUpdates,
                   and FlushPending replays them on PLAYER_REGEN_ENABLED.
                   Body is "/use item:<id>" for items or "/cast <name>"
                   for spell sentinels.

Options.lua ───── AceConfig option table built from KCM.Categories.LIST.
                   Registered to Blizzard Settings via
                   AceConfigDialog:AddToBlizOptions (returns frame + ID).
                   Per-row priority widgets: status/name label, score-info
                   button, up/down, delete. Add-by-ID uses a kind dropdown
                   (Item/Spell) + validator + confirm popup.
                   Refresh() is a NotifyChange passthrough — safe to call
                   unconditionally.

SlashCommands.lua /kcm dispatcher. DUMP_TARGETS is a single source of truth
                   so adding a dump name makes it appear in help output
                   (categories / statpriority / bags / item / pick).
                   Owns the KCM_CONFIRM_RESET StaticPopup.

KCM*.lua         AceGUI custom widgets registered via
                   `dialogControl = "KCM<Name>"` from Options:
                   - KCMItemRow: priority-row label with status glyphs,
                     item icon, quality tier, pick star, and real
                     in-game item/spell tooltip on hover.
                   - KCMIconButton: gold-hover icon button used for
                     ↑ / ↓ / × and the macro drag icon.
                   - KCMScoreButton: same hover swatch, swallows
                     SetLabel so the option's `name` drives the
                     tooltip title without rendering a text label
                     under the icon; tooltip body renders the
                     Ranker.Explain breakdown.
                   - KCMMacroDragIcon: pickable macro icon at the
                     top of each category page.
                   - KCMHeading / KCMTitle: headline styling that
                     matches Blizzard's native settings look.
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
            │  scoreCache = { fields = {} }            -- fresh per pass
            │  for each category in Categories.LIST:
            │      pcall(RecomputeOne, catKey, scoreCache, reason)
            │         pick = Selector.PickBestForCategory(catKey, nil, scoreCache)
            │         MacroManager.SetMacro(cat.macroName, pick, catKey)
            │  then Options.Refresh() — cheap NotifyChange passthrough.
            ▼
          per-category:
              Selector.GetEffectivePriority(catKey, specKey, scoreCache)
                  candidates = BuildCandidateSet(catKey)                    -- pure
                  sorted     = Ranker.SortCandidates(cat, cands, ctx, cache) -- pure
                  final      = mergePins(sorted, bucket.pins)               -- pure
              walk final, return first id BagScanner.HasItem says you own
              (items) or IsPlayerSpell confirms (spell sentinels).
```

`scoreCache` is threaded all the way through Pipeline → Selector → Ranker. It memoizes `GetItemInfo` + `TooltipCache.Get` results under `scoreCache.fields[id]` and per-category Ranker scores under `scoreCache[catKey][id]` — so a bag-flurry event that touches multiple macros doesn't re-score the same candidate set once per category. Panel rendering and `/kcm dump` paths pass `nil` and fall back to the uncached code path, preserving the live-data view.

Per-category `pcall` isolates failures: one throwing scorer (e.g. a Blizzard tooltip-shape change) can't break the other seven macros in the same recompute.

**Events** (wired in `Core:OnEnable`):

| Event                           | Handler                   | What it does                          |
|---------------------------------|---------------------------|----------------------------------------|
| `PLAYER_ENTERING_WORLD`         | `OnPlayerEnteringWorld`   | auto-discovery, `Selector.SweepStaleDiscovered(time())`, then RequestRecompute. |
| `BAG_UPDATE_DELAYED`            | `OnBagUpdateDelayed`      | auto-discovery + RequestRecompute.    |
| `PLAYER_SPECIALIZATION_CHANGED` | `OnSpecChanged`           | RequestRecompute.                     |
| `PLAYER_REGEN_DISABLED`         | `OnRegenDisabled`         | `KCM._inCombat = true`.               |
| `PLAYER_REGEN_ENABLED`          | `OnRegenEnabled`          | `MacroManager.FlushPending()`.        |
| `GET_ITEM_INFO_RECEIVED`        | `OnItemInfoReceived`      | TooltipCache.Invalidate(id) + retry discovery + RequestRecompute. |
| `LEARNED_SPELL_IN_SKILL_LINE`   | `OnLearnedSpell`          | RequestRecompute — so a newly-learned spell entry hydrates its macro body without a reload. |

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
│   │   └── discovered  { [itemID] = unixTimestamp }  -- last-seen in bags
│   └── STAT_FOOD │ CMBT_POT │ FLASK            ← spec-aware:
│       └── bySpec
│           └── ["<classID>_<specID>"]
│               ├── added
│               ├── blocked
│               ├── pins
│               └── discovered   { [itemID] = unixTimestamp }
├── statPriority
│   └── ["<classID>_<specID>"] = { primary, secondary[] }   -- user overrides only
└── macroState
    └── [macroName] = { lastItemID, lastBody, lastCat }     -- early-out cache
```

`KCM.ResetAllToDefaults(reason)` in Core.lua is the one place that wipes `categories` + `statPriority` back to `dbDefaults`. Both the Options "Reset all" button and `/kcm reset`'s StaticPopup delegate to it so semantics stay identical. It also runs TooltipCache.InvalidateAll → RunAutoDiscovery → Recompute on every call.

`Selector.MarkDiscovered` stamps `discovered[id]` with the current unix time on every sighting; legacy `true` values written by v1.0.0 are honoured on read and bumped to a timestamp the first time the item is seen again. `Selector.SweepStaleDiscovered(nowUnix)` (PEW-only) refreshes any id still present in bags and deletes entries older than 30 days — a bounded-growth guarantee for accounts that pass through many consumable tiers.

---

## Invariants worth not breaking

- **`MacroManager` is the only caller of `CreateMacro` / `EditMacro`.** Classifier, Ranker, Selector, BagScanner, TooltipCache must all stay pure (no protected APIs) so the pipeline can run in combat without taint.
- **Macros are always identified by name**, never by slot index. `perCharacter=false` in the CreateMacro call puts them in the account-wide pool.
- **Seed lists are treated as data, not code.** Updating a `defaults/Defaults_*.lua` is a zero-migration upgrade for existing users because `added`/`discovered`/`blocked` live in SavedVariables and union with the seed at runtime.
- **English-only.** Classifier compares subType against literal strings (`"Potions"`, `"Food & Drink"`, `"Flasks & Phials"`) and TooltipCache patterns are English. If Blizzard renames a subtype, edit the `ST_*` constants in `Classifier.lua`.
- **Module publishing pattern:** every file does `KCM.Foo = KCM.Foo or {}; local F = KCM.Foo`. Never shadow the local over the global.
- **Recompute is coalesced.** Event handlers call `RequestRecompute`, never `Recompute` directly — except the rare direct path (Reset, `/kcm resync`) where we want the write to land this tick.
- **Priority-list IDs are opaque numbers with sign semantics.** Positive = itemID, negative = `KCM.ID.AsSpell(spellID)`. Only `MacroManager` and the UI fork on sign; every other layer treats them as plain table keys. Keep it that way — no new side channels.
- **Score cache lives for one Recompute pass and no longer.** `scoreCache` is created fresh in `Pipeline.Recompute` and threaded through `Selector.PickBestForCategory` → `Ranker.SortCandidates`. Never cache across passes — tooltip/bag/spec state can shift between events. Non-pipeline callers (the Options panel, `/kcm dump pick`) pass `nil` so they always see fresh scores.

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
