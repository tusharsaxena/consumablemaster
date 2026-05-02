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
| `Selector.lua` | Candidate set + pin merge + ownership walk. Public surface: `BuildCandidateSet / GetEffectivePriority / PickBestForCategory / GetBucket` (read), `AddItem / Block / MoveUp / MoveDown / MarkDiscovered / SweepStaleDiscovered` (write). Owns the `(seed ∪ added ∪ discovered) − blocked` math and the 30-day discovered GC. |
| `MacroManager.lua` | The **only** module that calls `CreateMacro` / `EditMacro`. `SetMacro(macroName, id, catKey)` for single picks; `SetCompositeMacro(cat, scoreCache)` for HP_AIO / MP_AIO. Combat-deferral queue (`pendingUpdates`), bounded retry on flush, DYNAMIC_ICON / DEFAULT_ICON convention, 255-byte body limit fallback. `InvalidateState()` clears caches for `/cm rewritemacros`. See [macro-manager.md](./macro-manager.md). |
| `SlashCommands.lua` | `/cm` (and `/consumablemaster` alias) dispatcher. Three ordered tables: `COMMANDS` (top-level verbs), `DUMP_TARGETS` (`/cm dump <target>`), and `PRIORITY_COMMANDS` / `STAT_COMMANDS` / `AIO_COMMANDS` (verb namespaces). The `say()` helper prepends the cyan `[CM]` prefix to every chat line. Owns the `KCM_CONFIRM_RESET` StaticPopup. |

## settings/

Each tab module registers a builder via `KCM.Settings.RegisterTab(key, builder)`; `settings/Panel.lua`'s bootstrap iterates `KCM.Settings.order` and calls each builder once Blizzard_Settings is ready. Bodies are hand-built AceGUI widget trees inside a `Helpers.CreatePanel` canvas — no AceConfigDialog.

| File | Responsibility |
|------|----------------|
| `settings/Panel.lua` | Framework. `Helpers.CreatePanel` (gold title + atlas divider + body), lazy AceGUI ScrollFrame with always-visible scrollbar gutter (`PatchAlwaysShowScrollbar`), `Section` / `Button` / `ButtonPair` / `Label` / `RenderField` builders. Owns the `KCM.Settings.Schema` array, `Helpers.Get / Set / SetAndRefresh / SchemaForPanel / FindSchema / ValidateSchema / RefreshAllPanels`. Hosts the parent (About) canvas via `BuildAboutContent`. Publishes the `KCM.Options.{Register,Refresh,RequestRefresh,Open}` shim that Core / Debug / SlashCommands / Pipeline call. |
| `settings/General.lua` | General tab: Diagnostics (Debug toggle — schema-driven) + Maintenance (Force resync \| Force rewrite paired) + Reset (Reset all priorities, StaticPopup-confirmed via `KCM_RESET_ALL`). |
| `settings/StatPriority.lua` | Stat Priority tab: full-width spec dropdown (class+spec icon markup), Primary alone in a half-row, Secondary 1\|2 + 3\|4 paired half-rows, inline Reset. Owns `KCM.Options._viewedSpec` + `O.ResolveViewedSpec` + `O.FormatSpec`. |
| `settings/Category.lua` | Per-category tabs (single + composite). One builder per row in `KCM.Categories.LIST`. Single dispatch: drag icon → Add-by-ID (Type \| ID input) → Priority list rows (KCMItemRow + KCMScoreButton + ↑/↓/× buttons) → inline Reset. Composite dispatch: drag icon → In Combat / Out of Combat sections (each row: KCMItemRow + Enabled checkbox + ↑/↓) → inline Reset. Shared `KCM_RESET_CATEGORY` StaticPopup. |

## AceGUI custom widgets

Loaded between `MacroManager` and `settings/`. Each file calls `AceGUI:RegisterWidgetType` at the bottom; the tab builders acquire instances via `AceGUI:Create("KCM…")` at render time.

| File | Purpose |
|------|---------|
| `KCMItemRow.lua` | Priority-list row: status glyphs (green check / red / yellow star) + item icon + name + quality tier. Hover renders the real in-game item or spell tooltip (forks on `KCM.ID.IsSpell`). |
| `KCMIconButton.lua` | Gold-hover icon button used for ↑ / ↓ / ×. |
| `KCMScoreButton.lua` | The blue "i" info button. Hover renders the per-item `Ranker.Explain` breakdown. No-op `SetLabel` so the caller can pass an arbitrary tooltip-title string without rendering a text label under the icon. |
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
