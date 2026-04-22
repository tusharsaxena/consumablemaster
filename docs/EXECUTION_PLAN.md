# Ka0s Consumable Master — Execution Plan

Built from [REQUIREMENTS.md](./REQUIREMENTS.md) + [TECHNICAL_DESIGN.md](./TECHNICAL_DESIGN.md).

The plan is split into **8 milestones**, each landing a working slice. After every milestone the addon should load and not throw errors, even if features are incomplete. Each milestone ends with an **in-game smoke test** that gates the next one.

**How to resume**: open this file, find the first milestone whose checkboxes aren't all ticked, start there. The "Resume hint" line at the end of every milestone tells you exactly which file to open first.

---

## Status Legend
⬜ Not started | 🟡 In progress | ✅ Complete

---

## Milestone 0 — Project bootstrap

**Goal**: empty repo, addon folder layout, Ace3 vendored.

- ✅ M0.1 Addon files live directly at the repo root (flat layout; no inner folder).
- ✅ M0.2 Download Ace3 distribution and extract these libraries into `libs/`:
  - `LibStub`
  - `CallbackHandler-1.0`
  - `AceAddon-3.0`
  - `AceEvent-3.0`
  - `AceDB-3.0`
  - `AceConsole-3.0`
  - `AceConfig-3.0` (umbrella; pulls in `AceConfigCmd-3.0`, `AceConfigDialog-3.0`, `AceConfigRegistry-3.0`)
  - `AceGUI-3.0` (transitive)
- ✅ M0.3 Create `embeds.xml` listing the libs.
- ✅ M0.4 Create `ConsumableMaster.toc` with:
  - `## Interface: 120000`
  - `## Title: Ka0s Consumable Master`
  - `## Notes: Auto-managed account-wide consumable macros for WoW Midnight.`
  - `## Author: Ka0s`
  - `## Version: 0.1.0-dev`
  - `## SavedVariables: ConsumableMasterDB`
  - `embeds.xml`
  - (file load order to be filled in as later milestones add files)
- ✅ M0.5 Verify the addon shows up in WoW's AddOns list and loads without errors (empty-but-loaded).

**Resume hint**: open `ConsumableMaster.toc`.

---

## Milestone 1 — Skeleton + AceAddon wiring

**Goal**: addon registers with AceAddon, AceDB initialized, `/kcm` prints help.

- ✅ M1.1 Create `Core.lua`:
  - `KCM = LibStub("AceAddon-3.0"):NewAddon("ConsumableMaster", "AceEvent-3.0", "AceConsole-3.0")`
  - Empty `OnInitialize`, `OnEnable`.
- ✅ M1.2 Define `KCM.dbDefaults` skeleton (per TECHNICAL_DESIGN §4) — categories table can be empty placeholders for now.
- ✅ M1.3 In `OnInitialize`: `self.db = LibStub("AceDB-3.0"):New("ConsumableMasterDB", KCM.dbDefaults, true)`.
- ✅ M1.4 Create `Debug.lua` with `KCM.Debug = { IsOn(), Toggle(), Print(fmt, ...) }`.
- ✅ M1.5 Create `SlashCommands.lua` with the `/kcm` dispatcher (only `help` and `debug` work for now).
- ✅ M1.6 Register `kcm` chat command in `OnInitialize`.
- ✅ M1.7 Add `Core.lua`, `Debug.lua`, `SlashCommands.lua` to `.toc` (in that order, after `embeds.xml`).
- ✅ M1.8 **Smoke test**: in-game `/kcm` prints help; `/kcm debug` toggles a flag visible via a debug print.

**Resume hint**: open `Core.lua`.

---

## Milestone 2 — Categories + Defaults + SpecHelper

**Goal**: all category metadata + seed defaults + per-spec stat-priority table loaded into Lua-side constants. Nothing functional yet, but `KCM.Categories.LIST`, `KCM.SEED.*`, `KCM.SEED.STAT_PRIORITY` are populated.

- ✅ M2.1 Create `defaults/Categories.lua` with the 8-row `KCM.Categories.LIST` table + `BY_KEY` lookup per TECHNICAL_DESIGN §3.
- ✅ M2.2 Create `defaults/Defaults_StatPriority.lua` with `KCM.SEED.STAT_PRIORITY[<classID>_<specID>] = { primary=..., secondary={...} }` for every spec. Sourced from Method.gg / Icy Veins per-spec guides (April 2026).
- ✅ M2.3 Create one `defaults/Defaults_<Cat>.lua` per category. Seeds are **flat item-id lists** for all categories — the Ranker (M4) handles per-spec fit at runtime via tooltip parsing + stat priority; user overrides (pins/added/blocked) live in the AceDB `bySpec` sub-table for spec-aware categories.
- ✅ M2.4 Create `defaults/README.md` listing every source URL with the date this snapshot was taken.
- ✅ M2.5 Create `SpecHelper.lua`:
  - `GetCurrent()` using `GetSpecializationInfo(GetSpecialization())`.
  - `AllSpecs()` enumerating classes 1..13 with `GetNumSpecializationsForClassID`.
  - `GetStatPriority(specKey)` returning user override, else seed default, else class-primary fallback.
- ✅ M2.6 Add all the new files to `.toc` in dependency order: defaults files first (they only define tables), then `SpecHelper.lua`.
- ✅ M2.7 **Smoke test**: in-game, type `/dump KCM.Categories.LIST` and `/dump KCM.SEED.STAT_PRIORITY` — both should show the populated tables. `/dump KCM.SpecHelper.GetCurrent()` returns your current spec's classID/specID/specKey/specName. `/dump KCM.SpecHelper.GetStatPriority(select(3, KCM.SpecHelper.GetCurrent()))` returns a `{primary, secondary}` table.

**Resume hint**: open `defaults/Categories.lua`.

---

## Milestone 3 — Tooltip parsing + Bag scanning

**Goal**: given an itemID, can extract heal/mana/stat-buff/duration/conjured/feast info. Given current bags, can list what items are present.

- ✅ M3.1 Create `TooltipCache.lua`:
  - PATTERNS table per TECHNICAL_DESIGN §8.2 (with hour/min/sec duration normalization).
  - `Get(itemID)` with cache + lazy parse via `C_TooltipInfo.GetItemByID`.
  - Pending-state handling for items whose data hasn't loaded; `PendingIDs()` exposed for M5 event wiring.
  - `Invalidate(itemID)`, `InvalidateAll()`, `Stats()`.
- ✅ M3.2 Create `BagScanner.lua`:
  - `Scan()` returns `{ [itemID] = count }` iterating `0..NUM_TOTAL_EQUIPPED_BAG_SLOTS` via `C_Container.GetContainerItemInfo`.
  - `HasItem(itemID)` (uses `C_Item.GetItemCount` with bag fallback), `GetAllItemIDs()`.
- ✅ M3.3 `/kcm dump item <itemID>` prints the parsed tooltip cache entry. Also added: `/kcm dump bags`, numeric shortcut `/kcm dump <itemID>` routes to `item`.
- ✅ M3.4 Added `TooltipCache.lua` + `BagScanner.lua` to `.toc` after `SpecHelper.lua`.
- ✅ M3.5 **Smoke test**: pick up a flask in-game, run `/kcm dump 241321` (or another flask ID) — should show `statBuffs`, `buffDurationSec`, etc. `/kcm dump bags` lists all bag items.

**Resume hint**: open `TooltipCache.lua`.

---

## Milestone 4 — Classifier + Ranker

**Goal**: pure functions over (itemID, tooltip data, spec context) returning category match boolean and rank score.

- ✅ M4.1 Create `Classifier.lua` with `Match(catKey, itemID)` per TECHNICAL_DESIGN §5.5.
- ✅ M4.2 Create `Ranker.lua` with per-category score functions per TECHNICAL_DESIGN §5.4. Include the helper `computeStatFoodScore`, `computeCmbtPotScore`, `computeFlaskScore`.
- ✅ M4.3 `KCM.Ranker.SortCandidates(catKey, itemIDs, ctx)` returns sorted array (descending score).
- ✅ M4.4 Add a debug helper `/kcm dump rank <catKey>` that prints all candidates with their scores for the current spec — wired as a `DUMP_TARGETS` entry in SlashCommands.
- ✅ M4.5 Add files to `.toc`.
- ✅ M4.6 **Smoke test**: `/kcm dump rank flask` returns flasks ordered by spec priority. `/kcm dump rank hp_pot` ranks higher-quality pots first.

**Resume hint**: open `Classifier.lua`.

---

## Milestone 5 — Selector + MacroManager + Pipeline

**Goal**: end-to-end macro updates work. Bags change → macros rewrite. Combat → defer → flush on regen. **This is the first milestone where the addon does its actual job.**

- ✅ M5.1 Create `Selector.lua`:
  - ✅ `BuildCandidateSet(catKey, specKey?)` → `seed ∪ added ∪ discovered − blocked`. (also: `GetBucket(catKey, specKey?)` helper that lazy-inits `bySpec[specKey]` for spec-aware cats.) Wired into `.toc` before `SlashCommands.lua`.
  - ✅ `GetEffectivePriority(catKey, specKey?)` → ranked list with pins merged per §5.3 algorithm.
  - ✅ `PickBestForCategory(catKey)` → first-owned itemID or nil. Added `/kcm dump pick <cat>` helper that prints the full priority + bag-ownership badges + which item would be selected.
  - ✅ `AddItem(catKey, itemID)`, `Block(catKey, itemID)`, `MoveUp/Down(catKey, itemID)` — all mutate `KCM.db.profile.categories.<cat>` in the right place. Also shipped: `Unblock`, `MarkDiscovered` (for BAG_UPDATE_DELAYED auto-discovery in M5.4), `ClearPins`. All mutators return booleans; callers trigger the recompute (keeps Selector pure/testable).
- ✅ M5.2 Create `MacroManager.lua`:
  - ✅ `SetMacro(macroName, itemID, catKey?)` per TECHNICAL_DESIGN §5.2 pseudocode (early-return "unchanged" if body matches lastBody, "deferred" if combat, "created"/"edited" otherwise). Account-wide (`perCharacter=false`).
  - ✅ `FlushPending()` for `PLAYER_REGEN_ENABLED` — returns applied count; leaves still-failing entries queued for the next regen.
  - ✅ `BuildBody(catKey, itemID)` — active = `#showtooltip\n/use item:<id>`, empty = `#showtooltip\n<cat.emptyText>`. Truncates at 255-char cap.
  - ✅ `IsAdopted(macroName)`, `HasPending()`, `PendingCount()` helpers. Added to `.toc` after `Selector.lua`.
- ✅ M5.3 In `Core.lua` add `Pipeline.Recompute(reason)`, `Pipeline.RecomputeOne(catKey, reason)`, and `Pipeline.RequestRecompute(reason)` (coalesced via `C_Timer.After(0, ...)` — gated by `_recomputePending` + `_recomputeScheduled` so a flurry collapses to one pipeline run).
- ✅ M5.4 In `Core:OnEnable` register events:
  - ✅ `PLAYER_ENTERING_WORLD` → `runAutoDiscovery` + recompute.
  - ✅ `BAG_UPDATE_DELAYED` → `runAutoDiscovery` (walks bags, runs `Classifier.MatchAny`, skips seed items, calls `Selector.MarkDiscovered` for new matches) + recompute.
  - ✅ `PLAYER_SPECIALIZATION_CHANGED` → recompute.
  - ✅ `PLAYER_REGEN_DISABLED` → set `_inCombat=true`.
  - ✅ `PLAYER_REGEN_ENABLED` → set `_inCombat=false`, `MacroManager.FlushPending()`.
  - ✅ `GET_ITEM_INFO_RECEIVED` → invalidate that itemID's tooltip cache, recompute.
- ✅ M5.5 Added `Selector.lua` + `MacroManager.lua` to `.toc`. **Deviation from original plan**: `Core.lua` must load *first* (not last), because it's where `_G.KCM = LibStub("AceAddon-3.0"):NewAddon(...)` publishes the namespace everything else reads at file-load time. Final order: `Core` → `Debug` → `defaults/*` → `SpecHelper` → `TooltipCache` → `BagScanner` → `Classifier` → `Ranker` → `Selector` → `MacroManager` → `SlashCommands`. (`OnEnable` runs after all files finish loading, so event handlers can reference later-defined modules without issue.)
- ✅ M5.6 **Smoke test (the big one)** — passed on Resto Shaman 2026-04-22.
  Bugs discovered and fixed during smoke test:
  - Midnight renamed consumable subType strings. Fixed `Classifier.lua`
    constants: `"Potion"` → `"Potions"`, and legacy `"Flask"` / `"Phial"`
    merged into `"Flasks & Phials"`. Without this, nothing classified.
  - `Classifier.Match` was gating FLASK on tooltip availability, but FLASK
    classification is subType-only. On `/reload` `C_TooltipInfo` returns
    empty for seconds and `GET_ITEM_INFO_RECEIVED` doesn't fire for
    cache-resident items — so flask discovery silently never retried.
    FLASK now classifies on subType alone.
  - `CMBT_POT` matcher required `hasStatBuff`, excluding potions like
    "Potion of Recklessness" whose tooltip says "highest secondary stat"
    (no stat name the parser recognizes). Broadened to "short-duration
    potion that isn't heal/mana".
  - Added `TOP_SECONDARY` synthetic stat so TooltipCache captures
    "N of your highest secondary stat" phrasing, and Ranker scores it
    against the spec's top secondary.
  - Extended `/kcm dump item <id>` to print `GetItemInfoInstant` output
    + `Classifier.MatchAny` result — primary diagnostic for category
    misclassification.
  - Refreshed all seed files from Method.gg Midnight consumables list
    (prior seeds had ~30 fabricated item names). New doc
    `docs/REFRESH_ITEMS.md` is the repeatable playbook.

**Resume hint**: open `Options.lua`.

---

## Milestone 6 — Settings UI

**Goal**: full settings panel integrated into Blizzard's AddOns settings page. Add / remove / pin / reset / spec-switch / stat-priority override all functional.

M6 is broken into sub-steps (6.1a–6.1e) on the same interim-checkpoint pattern used for M5.

- ✅ M6.1a Scaffold `Options.lua` + General page + registration.
  - `KCM.Options` namespace with `Build / Refresh / Register / Open`.
  - General page: debug toggle, force-resync execute (combat-guarded, invalidates TooltipCache, runs auto-discovery + recompute), reset-all execute (with `confirm = true` + `confirmText`; rebuilds `categories` + `statPriority` from `KCM.dbDefaults` via `CopyTable`; preserves `macroState` so live macros aren't orphaned).
  - Version description footer.
  - Wired: added `Options.lua` to `.toc` before `SlashCommands.lua`; `Core:OnInitialize` calls `KCM.Options.Register()` after AceDB init; `/kcm config` routes to `KCM.Options.Open()` (which uses `Settings.OpenToCategory(KCM._settingsCategoryID)`).
- ✅ M6.1b (merged into 6.1a) General page content.
- ✅ M6.1c/d Category page factory + apply to all 8 categories.
  - `buildCategoryArgs(catKey)` in `Options.lua`: description header → add-by-id input (validates via `GetItemInfoInstant`) → priority list → per-category reset.
  - Each row renders as four widgets with widths summing to 2.0 so they fit on one row in AceConfigDialog's default 2-unit layout: label (`description`, 1.5) + `up` (0.15) + `dn` (0.15) + `X` (0.2). Label shows `[owned]` / `[---]` tag, item icon, name, `id=N`, and `<- pick` marker when it matches `Selector.PickBestForCategory`.
  - Row buttons call `Selector.MoveUp`/`MoveDown`/`Block` then `afterMutation` (shared helper: `Pipeline.RequestRecompute` + `O.Refresh`).
  - Reset wipes `added/blocked/pins` via `Selector.GetBucket` but preserves `discovered` so auto-discovered items don't need to re-scan. Spec-aware categories get a "(current spec)" suffix in the confirmText.
  - `O.Build` iterates `KCM.Categories.LIST` appending one sub-group per category (keyed by `cat.key:lower()`).
  - Spec-aware categories currently mirror the active spec via `currentSpecKey()` — spec selector arrives in M6.1e.
- ✅ M6.1e Spec-aware pages (spec selector + stat-priority editor).
  - `O._viewedSpec[catKey]` holds the currently-viewed spec per category (module-local, not persisted — opens each session on the active spec).
  - Spec selector dropdown lists all 39 specs via `SpecHelper.AllSpecs()`, formatted `<Class> — <Spec>` and sorted alphabetically. Changing it redraws the page against the new spec's bucket.
  - Stat-priority editor appears as an inline `group` below the per-category reset, only when a specKey resolves. Five dropdowns: primary (STR/AGI/INT) + secondary slots 1–4 (CRIT/HASTE/MASTERY/VERSATILITY + `(none)` sentinel). `readStatPriority` pads secondary to 4 slots for display; `writeStatPriority` compacts `""` out on save so the Ranker always sees a dense list.
  - "Reset stat priority" wipes `db.profile.statPriority[specKey]` so `SpecHelper.GetStatPriority` falls back to seed → class-primary.
  - All mutations call `afterMutation` which chains `Pipeline.RequestRecompute` + `O.Refresh`, so the panel's priority list re-sorts live as the user changes stat priority.
- ✅ M6.2 (covered by 6.1a) — `AceConfig:RegisterOptionsTable` + `AddToBlizOptions` in `Options.Register`.
- ✅ M6.3 Refresh hooks for external mutations.
  - Panel-initiated mutations already call `afterMutation` → `O.Refresh`. The remaining gap was event-driven state (bag updates, spec change, item-info received, auto-discovery) and `/kcm debug` toggles, which would leave the panel showing stale ownership tags / item names / debug-toggle state if open.
  - Hooked at choke points rather than per-mutation: `Pipeline.Recompute` calls `O.Refresh` at the tail (covers every event path since they all route through RequestRecompute → Recompute); `Debug.Toggle` calls `O.Refresh` after flipping the flag.
  - `O.Refresh` is a `NotifyChange` passthrough — cheap no-op when the panel isn't open, so unconditional firing on every recompute is fine.
- ✅ M6.4 (covered by 6.1a) — `/kcm config` now routes to `Options.Open`.
- ✅ M6.5 (covered by 6.1a) — `.toc` updated.
- ✅ M6.6 **Smoke test** — all 7 scenarios passed (tabs enumerate, priority list ownership tags flip live, move/remove/add persist across `/reload`, spec selector exposes all 39 specs, stat-priority overrides re-rank immediately). UX polish (widget widths, label density, dropdown labels) deferred to M8.

**Resume hint**: M6 complete. M7 in progress — `/kcm reset` popup wired.

---

## Milestone 7 — Slash commands flesh-out + reset popup

**Goal**: complete `/kcm` UX.

- ✅ M7.1 `SlashCommands.lua` surface.
  - `/kcm`, `/kcm config`, `/kcm debug`, `/kcm resync` were already live from earlier milestones.
  - `/kcm reset` now calls `StaticPopup_Show("KCM_CONFIRM_RESET")` instead of the placeholder print.
- ✅ M7.2 `StaticPopupDialogs["KCM_CONFIRM_RESET"]` registered in `SlashCommands.lua`. `OnAccept` calls `KCM.ResetAllToDefaults("slash_reset")` — a new shared helper in `Core.lua` that wipes `categories` + `statPriority` from `dbDefaults` (preserving `macroState`) and triggers a pipeline recompute. The panel's "Reset all priorities" execute now calls the same helper so both entry points have identical semantics. Popup uses `preferredIndex = 3` to dodge taint cascades from other addons using slots 1/2.
- ✅ M7.3 Decision: keep `/kcm dump` and `/kcm rank` unconditionally rather than gating on `Debug.IsOn()`. These are documented as the primary verification tool in `docs/REFRESH_ITEMS.md` (the seed-refresh playbook calls them out by name) and have no runtime cost when unused. Gating them would make the refresh workflow dependent on a debug toggle.
- ✅ M7.4 **Smoke test** — all 6 scenarios passed (help block, /kcm config, /kcm debug mirror, /kcm resync, reset popup accept/decline, Options reset-all parity). Follow-up scope change accepted mid-milestone: "Reset all priorities" was extended to also run the full resync sequence (tooltip cache invalidate → auto-discovery → Recompute) so users don't have to chain `/kcm reset` + `/kcm resync` manually. Implemented in `KCM.ResetAllToDefaults`.

**Resume hint**: M7 complete; plan moves to M8 (acceptance gate).

---

## Milestone 8 — Polish, taint check, ship 0.1.0 ✅

**Goal**: validate full acceptance criteria, fix any rough edges, bump version.

Code-side M8 items:

- ✅ M8.4 Trim debug prints that aren't behind `Debug.IsOn()`. **No-op after audit** — every unguarded `print` in the addon is either a slash-command response, a user-facing warning from a UI action (e.g. "in combat — resync deferred"), or inside `Debug.lua` itself. All diagnostics are routed through `KCM.Debug.Print`, which gates on `IsOn()` internally. Nothing to trim.

In-game acceptance checks (user-driven):

- ✅ M8.1 REQUIREMENTS.md §10 acceptance criteria — all passed.
- ✅ M8.2 `/console scriptErrors 1` + `/console taintLog 2` session — no KCM-related taint or Lua errors.
- ✅ M8.3 Every category sub-page walked — seed items render with icons, ownership and pick markers correct. Origin-tagging (the old "(auto)" badge concept) punted to backlog — see OOB.3.

Ship:

- ✅ M8.5 Version bumped to `0.1.0` in `ConsumableMaster.toc` and `KCM.VERSION` (`Core.lua`).
- ✅ M8.6 Final `/reload` smoke pass — clean.

**Milestone 8 complete. v0.1.0 ships.** Polish items listed under OOB.3 are non-blocking backlog.

---

## Out-of-band tasks (not blocking any milestone)

- ⬜ OOB.1 Stage a `defaults/UPDATING.md` short guide for future me: "to refresh defaults for a new patch, edit the relevant `Defaults_*.lua`, bump the date in `defaults/README.md`, no code changes required."
- ⬜ OOB.2 Decide later whether to publish to CurseForge (out of scope for v1).
- ⬜ OOB.3 Settings-panel UX polish pass. Known-rough items flagged during M6 but deferred per ship-functional-first pattern:
  - Row widget widths (label 1.5 + up/down/X 0.15/0.15/0.2 = 2.0) may wrap on some client widths.
  - Row label density: `[owned] icon name id=N <- pick` is information-dense; consider abbreviating or splitting.
  - Spec selector dropdown label is just `<Class> — <Spec>`; no grouping or icons.
  - Add-by-id input clears on submit but doesn't surface a success message.
  - Reset buttons ("Reset category" / "Reset stat priority") live next to each other with similar wording; may need stronger visual separation.
  - Origin tagging (distinguishing auto-discovered from seed from user-added items) — concept existed in an early draft of M8.3 as an "(auto)" badge but was never built. Decide during polish whether it's worth the widget count.

---

## Quick reference — file load order in `.toc`

For copy-paste convenience when wiring `.toc`:

```
embeds.xml

Core.lua
Debug.lua

defaults\Categories.lua
defaults\Defaults_StatPriority.lua
defaults\Defaults_Food.lua
defaults\Defaults_Drink.lua
defaults\Defaults_StatFood.lua
defaults\Defaults_HPPot.lua
defaults\Defaults_MPPot.lua
defaults\Defaults_Healthstone.lua
defaults\Defaults_CombatPot.lua
defaults\Defaults_Flask.lua

SpecHelper.lua
TooltipCache.lua
BagScanner.lua
Classifier.lua
Ranker.lua
Selector.lua
MacroManager.lua
Options.lua
SlashCommands.lua
```

(`Core.lua` first because it does `_G.KCM = LibStub("AceAddon-3.0"):NewAddon(...)` — every subsequent file reads `_G.KCM` at load time. `Debug.lua` second because everything below may call `KCM.Debug.Print`. Files below Debug are loaded in dependency order: seed defaults → helpers → classifier → ranker → selector → macro layer → slash. `Options.lua` lands once M6 adds it.)
