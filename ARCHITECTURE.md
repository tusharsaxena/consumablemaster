# Architecture

Orient-yourself map for **Ka0s Consumable Master**. This file is the high-level index; topic detail lives in `docs/`.

## What it does

Ten account-wide global macros (`KCM_FOOD`, `KCM_DRINK`, `KCM_HP_POT`, `KCM_MP_POT`, `KCM_HS`, `KCM_FLASK`, `KCM_CMBT_POT`, `KCM_STAT_FOOD`, `KCM_HP_AIO`, `KCM_MP_AIO`) whose bodies auto-rewrite to point at the best consumable currently in your bags. Eight macros run a per-category scorer; two are composites that compose other categories' picks via combat conditionals. Identified by name, never by slot — coexists with every other macro in the user's account-wide pool.

## Subsystems at a glance

```
WoW events ─▶ Core.Pipeline ─▶ Selector ─▶ Ranker     ─▶ candidate score
                  │                │     ─▶ Classifier ─▶ auto-discovery match
                  │                │
                  │                └─▶ pick (first owned id)
                  │
                  └─▶ MacroManager.SetMacro / SetCompositeMacro
                        └─▶ CreateMacro / EditMacro    (the only protected-API caller)

  AceDB (one account-wide profile)  ──  Options panel + /cm slash CLI
```

| Subsystem | Lives in | Read |
|-----------|----------|------|
| Per-module APIs + roles | `Core.lua`, `Selector.lua`, `Ranker.lua`, `Classifier.lua`, `BagScanner.lua`, `TooltipCache.lua`, `SpecHelper.lua`, `Debug.lua`, `Options.lua`, `SlashCommands.lua` | [docs/module-map.md](./docs/module-map.md) |
| Recompute pipeline + score cache + events | `Core.lua` (`KCM.Pipeline`) | [docs/pipeline.md](./docs/pipeline.md) |
| AceDB schema + opaque IDs + discovered GC | `Core.lua` (`KCM.dbDefaults`, `KCM.ID`), `Selector.lua` | [docs/data-model.md](./docs/data-model.md) |
| MacroManager (body builders, composite assembly, combat deferral, action-bar icons) | `MacroManager.lua` | [docs/macro-manager.md](./docs/macro-manager.md) |
| Tooltip parsing + Midnight gotchas | `Classifier.lua`, `TooltipCache.lua` | [docs/midnight-quirks.md](./docs/midnight-quirks.md) |
| Settings panel + slash CLI + schema layer | `Options.lua`, `SlashCommands.lua` | [docs/debug.md](./docs/debug.md), [docs/file-index.md](./docs/file-index.md) |
| Per-file responsibility map | — | [docs/file-index.md](./docs/file-index.md) |
| Routine recipes (add category, refresh seeds, fix misclassification) | — | [docs/common-tasks.md](./docs/common-tasks.md) |
| In/out scope + resolved design decisions | — | [docs/scope.md](./docs/scope.md) |

## Invariants worth not breaking

- **`MacroManager` is the only caller of `CreateMacro` / `EditMacro`.** Selector, Ranker, Classifier, BagScanner, TooltipCache, SpecHelper must all stay pure (no protected APIs) so the pipeline can run in combat without taint.
- **Macros are always identified by name**, never by slot index. `perCharacter=false` puts them in the account-wide pool. The addon never calls `DeleteMacro` on a `KCM_*` macro.
- **Seed lists are data, not code.** Updating a `defaults/Defaults_*.lua` is a zero-migration upgrade — `added`/`discovered`/`blocked` live in SavedVariables and union with the seed at runtime.
- **English-only.** Classifier compares subType against literal strings (`"Potions"`, `"Food & Drink"`, `"Flasks & Phials"`) and TooltipCache patterns are English. If Blizzard renames a subType, edit the `ST_*` constants in `Classifier.lua`.
- **Module publishing pattern:** every file does `KCM.Foo = KCM.Foo or {}; local F = KCM.Foo`. Never shadow the local over the global.
- **Recompute is coalesced.** Event handlers call `Pipeline.RequestRecompute`, never `Pipeline.Recompute` directly — except the rare direct paths (`KCM.ResetAllToDefaults`, `/cm resync`, `/cm rewritemacros`) where the write should land this tick.
- **Priority-list IDs are opaque numbers with sign semantics.** Positive = itemID, negative = `KCM.ID.AsSpell(spellID)`. Only `MacroManager`, `Ranker.Score`'s spell shortcut, and the UI fork on the sign; every other layer treats them as plain table keys.
- **Score cache lives for one Recompute pass and no longer.** `scoreCache` is created fresh in `Pipeline.Recompute` and threaded through `PickBestForCategory` → `SortCandidates`. Tooltip / bag / spec state can shift between events — never cache across passes. Non-pipeline callers (Options panel, `/cm dump pick`) pass `nil`.
- **Composite categories never own item buckets.** No `added`/`blocked`/`pins`/`discovered` — composites compose picks from their referenced single categories at recompute time. Sub-categories are locked to their `inCombat` / `outOfCombat` section.
- **Action-bar icon sentinel.** Active body stores `DYNAMIC_ICON = 134400` (`?` fileID); empty body omits `#showtooltip` and stores `DEFAULT_ICON = 7704166` (cooking pot). Storing `DEFAULT_ICON` on an active body shows the cooking pot on the bar instead of the picked item's icon.

## External dependencies

All vendored under `libs/`:

- LibStub
- CallbackHandler-1.0
- AceAddon-3.0
- AceEvent-3.0
- AceDB-3.0
- AceConsole-3.0
- AceGUI-3.0
- AceConfig-3.0 (pulls in AceConfigRegistry / AceConfigCmd / AceConfigDialog)

`embeds.xml` is the load manifest referenced from `ConsumableMaster.toc`. The TOC's `## Interface:` line is `120000, 120001, 120005`.

## Load order

`ConsumableMaster.toc` is the source of truth. Order is dependency, not alphabetical:

1. `embeds.xml`
2. `Core.lua` (creates `_G.KCM`)
3. `Debug.lua`
4. `defaults/Categories.lua` then `defaults/Defaults_*.lua`
5. `SpecHelper` → `TooltipCache` → `BagScanner` → `Classifier` → `Ranker` → `Selector` → `MacroManager`
6. AceGUI widgets: `KCMIconButton` → `KCMScoreButton` → `KCMHeading` → `KCMMacroDragIcon` → `KCMItemRow`
7. `Options.lua`
8. `SlashCommands.lua`

Event handlers and `Pipeline` functions are *defined* at the top of `Core.lua` but only *called* from `OnEnable` / Ace event dispatch, which runs after every file has loaded — so the bodies can freely reference modules that load later.
