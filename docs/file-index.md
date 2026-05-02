# File index

Where each responsibility lives in the source tree. Match this map to the actual files before editing — the TOC at `ConsumableMaster.toc` is the source of truth for load order.

## Top-level Lua

| File | Responsibility |
|------|----------------|
| `Core.lua` | AceAddon entry. `OnInitialize` (DB, slash registration, Options register), `OnEnable` (event subscriptions). Houses `Pipeline.Recompute` / `RequestRecompute` / `RecomputeOne`, the event handlers, `KCM.ID` sentinel helpers (positive = item, negative = spell), `KCM.dbDefaults` (the AceDB schema), and `KCM.ResetAllToDefaults`. |
| `Debug.lua` | `KCM.Debug.IsOn() / Toggle() / Print(fmt, ...)`. Toggle routes through `Settings.Helpers.SetAndRefresh` so the panel checkbox, `/cm debug`, and `/cm set debug` share one path. |
| `SpecHelper.lua` | Class/spec identity. `GetCurrent()` returns `(classID, specID, specKey, specName)`. `GetStatPriority(specKey)` merges user override → seed default → class fallback. `MakeKey(classID, specID)` produces the canonical `<classID>_<specID>` string. |
| `TooltipCache.lua` | `C_TooltipInfo.GetItemByID(id)` parser + per-session cache. Captures heal/mana values (incl. HOT amounts), stat buffs, conjured/feast flags, durations. `Get(id) / Invalidate(id) / InvalidateAll() / IsPending(id) / PendingIDs() / IsUsableByPlayer(id) / Stats()`. Handles NBSP and `\|4singular:plural;` escapes. |
| `BagScanner.lua` | `Scan() -> {[itemID] = count}` (one pass over `C_Container`). `HasItem(itemID) -> ownsBool, count` via a single `C_Item.GetItemCount` call (no full-Scan fallback). Stateless. |
| `Classifier.lua` | `(itemID) → categories`. `Match(catKey, id, tt, subType)` and `MatchAny(id) -> { catKeys }`. English-only subType + tooltip-pattern matching. `ST_*` constants at the top of the file absorb Midnight subType renames. |
| `Ranker.lua` | Per-category scorers. `Score(catKey, id, ctx, scoreCache) / SortCandidates(catKey, ids, ctx, scoreCache) / BuildContext(catKey, itemIDs, existing, scoreCache) / Explain(catKey, id, ctx)`. Spell entries short-circuit to a fixed score above every item. HP_POT / MP_POT apply the immediate-vs-HOT 20% rule. Spec-aware scorers weight by `ctx.specPriority`. |
| `Selector.lua` | Candidate set + pin merge + ownership walk. Public surface: `BuildCandidateSet / GetEffectivePriority / PickBestForCategory` (read), `AddItem / Block / Unblock / MoveUp / MoveDown / ClearPins / MarkDiscovered / SweepStaleDiscovered` (write). Owns the `(seed ∪ added ∪ discovered) − blocked` math and the 30-day discovered GC. |
| `MacroManager.lua` | The **only** module that calls `CreateMacro` / `EditMacro`. `SetMacro(macroName, id, catKey)` for single picks; `SetCompositeMacro(cat, scoreCache)` for HP_AIO / MP_AIO. Combat-deferral queue (`pendingUpdates`), bounded retry on flush, DYNAMIC_ICON / DEFAULT_ICON convention, 255-byte body limit fallback. `InvalidateState()` clears caches for `/cm rewritemacros`. See [macro-manager.md](./macro-manager.md). |
| `Options.lua` | AceConfig panel + `Settings.Schema` + `Helpers`. Registers `Settings.RegisterVerticalLayoutCategory` parent + one `AceConfigDialog:AddToBlizOptions` sub-page per top-level group (General, Stat Priority, then each `Categories.LIST` entry). `O.Refresh()` (immediate) and `O.RequestRefresh()` (debounced). `Helpers.Get / Set / SetAndRefresh / RestoreDefaults / ValidateSchema` drive both panel widgets and `/cm list/get/set`. |
| `SlashCommands.lua` | `/cm` (and `/consumablemaster` alias) dispatcher. Three ordered tables: `COMMANDS` (top-level verbs), `DUMP_TARGETS` (`/cm dump <target>`), and `PRIORITY_COMMANDS` / `STAT_COMMANDS` / `AIO_COMMANDS` (verb namespaces). The `say()` helper prepends the cyan `[CM]` prefix to every chat line. Owns the `KCM_CONFIRM_RESET` StaticPopup. |

## AceGUI custom widgets

Loaded between `MacroManager` and `Options` so `Options.lua` can reference them by `dialogControl` name at table-build time.

| File | Purpose |
|------|---------|
| `KCMItemRow.lua` | Priority-list row: status glyphs (green check / red / yellow star) + item icon + name + quality tier. Hover renders the real in-game item or spell tooltip (forks on `KCM.ID.IsSpell`). |
| `KCMIconButton.lua` | Gold-hover icon button used for ↑ / ↓ / × and the Add-by-ID submit. |
| `KCMScoreButton.lua` | The blue "i" info button. Hover renders the per-item `Ranker.Explain` breakdown. Swallows `SetLabel` so the option's `name` becomes the tooltip title without rendering a text label under the icon. |
| `KCMHeading.lua` | Section heading styled like Blizzard's. |
| `KCMMacroDragIcon.lua` | Pickable macro icon at the top of each category page. Resolves to `GetItemIcon(lastItemID)` / `C_Spell.GetSpellTexture(spellID)` directly (the `?` sentinel is meaningless on a static UI widget). |

## defaults/

| File | Populates | Purpose |
|------|-----------|---------|
| `defaults/Categories.lua` | `KCM.Categories.LIST` + `KCM.Categories.BY_KEY` | Category metadata: macro name, displayName, specAware, classifier/ranker keys. Composite rows carry `composite=true` + `components = { inCombat={...}, outOfCombat={...} }`. |
| `defaults/Defaults_StatPriority.lua` | `KCM.SEED.STAT_PRIORITY` | Primary + ordered secondary stats per `<classID>_<specID>`. |
| `defaults/Defaults_<CAT>.lua` | `KCM.SEED.<CATKEY>` | Seed item / spell IDs per category. Spell entries use `KCM.ID.AsSpell(spellID)`. Composite categories have no seed file. |
| `defaults/README.md` | — | Seed file map + category scope decisions + refresh procedure. See [../defaults/README.md](../defaults/README.md). |

## Shared infrastructure

- `embeds.xml` — XML manifest pulled in by `ConsumableMaster.toc`; loads LibStub + every Ace3 sub-library before any addon source.
- `libs/` — vendored Ace3 + LibStub. Tracked in git (standard WoW addon practice).
- `ConsumableMaster.toc` — Interface line (`120000, 120001, 120005`), version, SavedVariables, file load order. Order is dependency order, not alphabetical.

## Top-level docs

- `README.md` — user-facing.
- `CLAUDE.md` — engineer working notes (hard rules + response style + doc index).
- `ARCHITECTURE.md` — design overview + invariants + doc index.
- `docs/*.md` — topic chunks (this file is one of them).
