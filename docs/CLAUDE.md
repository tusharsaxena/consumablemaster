# CLAUDE.md — working notes for future sessions

Guidance for Claude Code (and other LLM-assisted editors) working on **Ka0s Consumable Master**. Read this first before touching code.

---

## What this addon is

Eight account-wide global macros whose bodies auto-rewrite to the best consumable in bags for each category (food, drink, stat food, HP pot, MP pot, healthstone, combat pot, flask). Retail Midnight only (Interface 120000). English only. Ace3 throughout.

Read [ARCHITECTURE.md](./ARCHITECTURE.md) for the module map and pipeline; [TECHNICAL_DESIGN.md](./TECHNICAL_DESIGN.md) for deep design; [REQUIREMENTS.md](./REQUIREMENTS.md) for scope boundaries; [EXECUTION_PLAN.md](./EXECUTION_PLAN.md) for milestone history.

---

## Ground rules that matter

**`MacroManager` is the only module allowed to call protected macro APIs** (`CreateMacro`, `EditMacro`, `DeleteMacro`). Every other module — Classifier, Ranker, Selector, BagScanner, TooltipCache, SpecHelper — must stay pure so the pipeline runs in combat without taint. If you need bag data or tooltip data at macro-write time, call the pure module and pass the result into MacroManager; never import the other direction.

**Macros are identified by name, never slot.** `perCharacter=false` puts them in the account-wide pool (slots 1–120). The addon must never call `DeleteMacro` on a `KCM_*` macro — the slot is the user's.

**English-only.** Classifier compares subType against literal strings; TooltipCache patterns are English. If a Blizzard patch renames a subtype or rewords a tooltip line, edit `ST_*` in `Classifier.lua` or the `PATTERNS` table in `TooltipCache.lua`. Do not introduce localization plumbing — it is explicitly out of scope.

**Seed data is data.** `defaults/Defaults_*.lua` files are just lists of itemIDs that become `KCM.SEED.<CATKEY>`. Updating a seed list is a zero-migration upgrade because the runtime candidate set is `seed ∪ added ∪ discovered − blocked` and the right-side sets live in SavedVariables. See [defaults/README.md](../defaults/README.md) and [REFRESH_ITEMS.md](./REFRESH_ITEMS.md).

**Reset is centralized.** `KCM.ResetAllToDefaults(reason)` in `Core.lua` wipes + resyncs. Both the Options panel "Reset all priorities" button and `/kcm reset`'s StaticPopup delegate to it. Don't add a third reset path.

---

## Load order

`ConsumableMaster.toc` is the source of truth. Key points:

1. `embeds.xml` loads LibStub + Ace3 first.
2. `Core.lua` loads second and creates `KCM` via `AceAddon:NewAddon`, publishing it on `_G.KCM`. **Every other file assumes `_G.KCM` exists at load time.**
3. `defaults/Categories.lua` loads before the other `defaults/Defaults_*.lua` files so they can reference `KCM.Categories`.
4. Runtime modules order: `SpecHelper` → `TooltipCache` → `BagScanner` → `Classifier` → `Ranker` → `Selector` → `MacroManager` → `Options` → `SlashCommands`.

Event handler bodies are defined at the top of `Core.lua` but only *called* from `OnEnable` (which runs after every file has loaded), so the bodies can freely reference modules that load later.

If you add a new runtime file, put it in the right place in `ConsumableMaster.toc` — alphabetical is not the right order; dependency order is.

---

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

---

## Debug and diagnostics

- Toggle verbose logs: `/kcm debug`. Internally this flips `KCM.db.profile.debug`. Call `KCM.Debug.Print(fmt, ...)` — it early-returns when off, so unconditional calls are safe.
- Dump internals: `/kcm dump <target>` where targets are `categories`, `statpriority`, `bags`, `item <id>`, `raw <id>`, `rank <catKey>`, `pick <catKey>`. `DUMP_TARGETS` in `SlashCommands.lua` is a single source of truth — add a row and it appears in help automatically.
- Force a resync: `/kcm resync` — invalidates TooltipCache, re-runs discovery, runs a direct (non-coalesced) Recompute.

`Core.lua` has a commented-out per-category recompute log. Uncomment only for short debugging sessions; it fires N × M times during login (N categories × M `GET_ITEM_INFO_RECEIVED` events) and floods chat.

---

## Testing approach

**There are no automated tests.** Validation is manual, in-game:

- Load the addon, log in, verify the eight `KCM_*` macros exist.
- Watch `/kcm debug` output during login, bag changes, spec swaps, combat enter/leave.
- Use `/kcm dump pick <catKey>` to verify the effective priority list and the owned pick.
- Use `/kcm dump rank <catKey>` to verify Ranker scoring against seed items.
- Use `/kcm dump raw <itemID>` to pattern-debug tooltip parsing.

When changing a scorer, classifier, or tooltip pattern, smoke test:

1. `/kcm resync`
2. `/kcm dump rank <affected catKey>` — check the order.
3. `/kcm dump pick <affected catKey>` — check the winner.
4. Check the actual macro in the macro UI.

If you can only reason about the change from code and cannot test it in WoW, say so explicitly — don't claim it works.

---

## Working environment

- Dual-path WSL: `/home/tushar/GIT/ConsumableMaster/` and `/mnt/d/Profile/Users/Tushar/Documents/GIT/ConsumableMaster/` are the same repo via symlink. Either path works for git and file tools.
- Git remote: the repo has no remote commits yet; only local commits on `master`.
- `.gitignore` covers `.claude/settings.local.json`, OS cruft, editor scratch files. `libs/` **is** tracked (vendored Ace3, standard WoW addon practice). `defaults/`, `docs/`, and all `.lua` source are tracked.

---

## Common tasks

### Add a new category

1. Append a row to `KCM.Categories.LIST` in `defaults/Categories.lua` (set `specAware` correctly).
2. Add a matcher in `Classifier.lua`'s `matchers` table.
3. Add a scorer in `Ranker.lua`'s `scorers` table.
4. Create `defaults/Defaults_<NewCat>.lua` that writes `KCM.SEED.<KEY>`.
5. Add the file to `ConsumableMaster.toc` in dependency order.
6. Update the `dbDefaults.profile.categories` table in `Core.lua` so AceDB creates the bucket.
7. Options panel picks the category up automatically from `Categories.LIST`.

### Refresh seed item IDs after a patch

Follow [REFRESH_ITEMS.md](./REFRESH_ITEMS.md). Updating a `defaults/Defaults_*.lua` is safe — user SavedVariables are preserved.

### Fix a misclassification

Run `/kcm dump item <id>` to see the subType + parsed tooltip. If subType is wrong, Midnight may have renamed the string — edit `ST_*` in `Classifier.lua`. If the tooltip parse is missing a field, check `PATTERNS` in `TooltipCache.lua` (watch for non-breaking space U+00A0 and `|4singular:plural;` escapes — both are already normalized in `normalizeTooltipText`).

---

## Response style for this repo

- Terse. State the change, not the deliberation.
- Use `file_path:line_number` references when pointing at code.
- Don't write summaries the user can read from the diff.
- **Ship functional, defer polish.** The user has explicitly said: when core functionality lands, move on — don't stop to polish UX mid-milestone. Revisit polish later as a dedicated pass.
- Don't add comments that explain *what* well-named code does. Only add a comment when the *why* is non-obvious (subtle invariant, workaround for a specific Blizzard quirk, a hidden constraint).
- Don't create docs or planning files unless asked.

---

## Known Midnight gotchas (for when something breaks at patch time)

- **Consumable subType renames.** `"Potion"` → `"Potions"`, `"Flask"`/`"Phial"` → `"Flasks & Phials"`. Underlying classID/subClassID are unchanged but GetItemInfoInstant returns the display string. If another rename lands, update `Classifier.lua`.
- **`C_TooltipInfo.GetItemByID` returns raw template strings.** Grammar-number escapes like `"for 1 |4hour:hrs;"` are not pre-substituted. `TooltipCache.normalizeTooltipText` strips these; don't bypass it.
- **Non-breaking spaces (U+00A0) between numbers and units.** Lua's `%s` does NOT match NBSP. Normalize first.
- **`GET_ITEM_INFO_RECEIVED` does not fire for already-cached items.** That's why FLASK is classified from subType alone (no tooltip gate) and why discovery retries on this event only help the not-yet-cached case. Don't regress this.
- **Combat lockdown taints protected APIs.** Any path that could reach `EditMacro` must check `InCombatLockdown()` first. The only path that does is `MacroManager.SetMacro` — keep it that way.
- **AceConfigDialog:AddToBlizOptions returns `(frame, categoryID)` on modern clients.** The ID is numeric; passing the frame to `Settings.OpenToCategory` produces a range error. Always capture both return values and pass the ID.

---

## File index

- Entry + pipeline + events: `Core.lua`
- DB schema: `Core.lua` → `KCM.dbDefaults`
- Category metadata: `defaults/Categories.lua`
- Seed items: `defaults/Defaults_*.lua`
- Spec identity + stat priority: `SpecHelper.lua`
- Tooltip parsing: `TooltipCache.lua`
- Bag enumeration: `BagScanner.lua`
- Category matching: `Classifier.lua`
- Per-category scorers: `Ranker.lua`
- Candidate set + effective priority + DB mutators: `Selector.lua`
- The only protected-API caller: `MacroManager.lua`
- Settings panel: `Options.lua`
- `/kcm` dispatcher + reset popup: `SlashCommands.lua`
- Debug helper: `Debug.lua`
