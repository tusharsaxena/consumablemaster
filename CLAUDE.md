# CLAUDE.md — working notes for future sessions

Guidance for Claude Code (and other LLM-assisted editors) working on **Ka0s Consumable Master**. Read this first before touching code.

## What this addon is

Ten account-wide global macros whose bodies auto-rewrite to the best consumable in bags. Eight are single-pick categories (food, drink, HP pot, MP pot, healthstone, flask, combat pot, stat food) and two are composites (`KCM_HP_AIO`, `KCM_MP_AIO`) that compose other categories' picks via `[combat]` / `[nocombat]` conditionals. Panel/tab order is FOOD → DRINK → HP_POT → MP_POT → HS → FLASK → CMBT_POT → STAT_FOOD → HP_AIO → MP_AIO. Retail Midnight only (Interface 120000, 120001, 120005). English only. Ace3 throughout.

User-facing reference: [README.md](./README.md). Design overview + invariants: [ARCHITECTURE.md](./ARCHITECTURE.md).

## Hard rules

- **`MacroManager` is the only module allowed to call protected macro APIs** (`CreateMacro`, `EditMacro`, `DeleteMacro`). Every other module — Classifier, Ranker, Selector, BagScanner, TooltipCache, SpecHelper — must stay pure so the recompute pipeline can run in combat without taint. If you need bag or tooltip data at macro-write time, call the pure module and pass the result into MacroManager; never the other direction.
- **Macros are identified by name, never slot.** `perCharacter=false` puts them in the account-wide pool (slots 1–120). The addon must never call `DeleteMacro` on a `KCM_*` macro — the slot is the user's.
- **English-only.** Classifier compares subType against literal English strings; TooltipCache patterns are English. If a Blizzard patch renames a subType or rewords a tooltip line, edit `ST_*` in `Classifier.lua` or the `PATTERNS` table in `TooltipCache.lua`. Do not introduce localization plumbing — it is explicitly out of scope.
- **Seed data is data.** `defaults/Defaults_*.lua` files are just lists of itemIDs that become `KCM.SEED.<CATKEY>`. Updating a seed list is a zero-migration upgrade because the runtime candidate set is `(seed ∪ added ∪ discovered) − blocked` and the right-side sets live in SavedVariables.
- **Reset is centralized.** `KCM.ResetAllToDefaults(reason)` in `Core.lua` wipes + resyncs. Both the Options panel "Reset all priorities" button and `/cm reset`'s StaticPopup delegate to it. Don't add a third reset path.
- **Priority-list entries are opaque numeric IDs.** Positive = itemID, negative = `KCM.ID.AsSpell(spellID)` sentinel. Only `MacroManager`, `Ranker.Score`'s spell shortcut, and the UI fork on the sign — every other layer treats IDs as plain table keys. Keep it that way; no new side channels.
- **Composite categories don't pick items — they compose other categories' picks.** HP_AIO and MP_AIO carry `composite=true` + `components = { inCombat={...}, outOfCombat={...} }`. The pipeline branches on `cat.composite` and dispatches to `MacroManager.SetCompositeMacro`. Composites have no `added/blocked/pins/discovered` buckets.
- **Cyan `[CM]` chat prefix on all addon output.** Routes through `say()` in `SlashCommands.lua`, `KCM.Debug.Print` (gated), or inline `|cff00ffff[CM]|r ` prefix for one-shot warnings. **No raw `print(...)` calls.**

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

## Working environment

- **Dual-path WSL.** `/home/tushar/GIT/ConsumableMaster/` and `/mnt/d/Profile/Users/Tushar/Documents/GIT/ConsumableMaster/` are the same repo via symlink. Either path works for git and file tools.
- **Git remote.** No remote yet; only local commits on `master`.
- **`.gitignore`** covers `.claude/settings.local.json`, OS cruft, editor scratch files. `libs/` is tracked (vendored Ace3, standard WoW addon practice). `defaults/`, `docs/`, all `.lua` source are tracked.
- **No automated tests.** Validation is manual, in-game. See [docs/common-tasks.md](./docs/common-tasks.md) for the smoke-test recipe.

## Response style for this repo

- **Terse.** State the change, not the deliberation.
- **Use `file_path:line_number` references** when pointing at code.
- **Don't write summaries** the user can read from the diff.
- **Ship functional, defer polish.** When core functionality lands, move on — don't stop to polish UX mid-milestone. Revisit polish later as a dedicated pass.
- **No comments explaining *what* well-named code does.** Only add a comment when the *why* is non-obvious (subtle invariant, workaround for a specific Blizzard quirk, hidden constraint).
- **Don't create docs or planning files unless asked.**
- **Never auto-stage, auto-commit, or auto-push.** The user chooses when to `git add`, `git commit`, and `git push`. This includes `git add <file>`, `git add -A`, `git add -p`, `git add --renormalize`, `git stash`, or any other index-mutating command. Editing files on disk is fine; touching the git index is not. Offering to stage/commit at the end of a turn is fine; doing it yourself is not. **Exception**: invoking a commit-purpose slash command (e.g. `/wow-addon:commit`) IS the explicit instruction. Proceed through the skill's confirmation flow and treat the user's `y` as authorization to run `git add` + `git commit` on the files the skill named. Pushing still requires a separate explicit ask.
- **Never bump the version without an explicit instruction.** Do not edit `KCM.VERSION` in `Core.lua`, `## Version:` in `ConsumableMaster.toc`, the version badge / inline version in `README.md`, or add a changelog entry, unless the user has explicitly asked. Releases are the user's call.

## Doc index

Topic-specific detail lives in `docs/`. Read on demand — these are not auto-loaded.

| Topic | File | When to read |
|-------|------|--------------|
| Scope boundaries (in / out / resolved decisions) | [docs/scope.md](./docs/scope.md) | Evaluating a feature request; deciding whether to add a category. |
| Per-file responsibility map | [docs/file-index.md](./docs/file-index.md) | "Which file owns X?" |
| Recipes (add category / composite, refresh seeds, fix misclassification) | [docs/common-tasks.md](./docs/common-tasks.md) | Routine modifications. |
| Debug toggle, dump targets, schema CLI | [docs/debug.md](./docs/debug.md) | Diagnosing in-game; building schema-driven settings. |
| Midnight quirks (subtype renames, NBSP, secret values, icon sentinel) | [docs/midnight-quirks.md](./docs/midnight-quirks.md) | Patch-day breakage, tooltip pattern issues. |
| Module map + public APIs | [docs/module-map.md](./docs/module-map.md) | Designing a cross-module change. |
| Recompute pipeline + score cache + events | [docs/pipeline.md](./docs/pipeline.md) | Touching event handling, performance. |
| AceDB schema + opaque IDs + composites + GC | [docs/data-model.md](./docs/data-model.md) | Adding a category, persistent state changes. |
| MacroManager — body builders, composite assembly, flush retry, icons | [docs/macro-manager.md](./docs/macro-manager.md) | Anything touching macro writes. |
| Seed reference + refresh procedure | [defaults/README.md](./defaults/README.md) | Patch-day seed updates. |
