# CLAUDE.md — working notes for future sessions

Guidance for Claude Code (and other LLM-assisted editors) working on **Ka0s Consumable Master**. Read this first before touching code.

---

## What this addon is

Eight account-wide global macros whose bodies auto-rewrite to the best consumable in bags for each category (food, drink, HP pot, MP pot, healthstone, flask, combat pot, stat food — the panel/tab order). Retail Midnight only (Interface 120000). English only. Ace3 throughout.

Read [ARCHITECTURE.md](./ARCHITECTURE.md) for the module map and pipeline; [docs/TECHNICAL_DESIGN.md](./docs/TECHNICAL_DESIGN.md) for deep design; [docs/REQUIREMENTS.md](./docs/REQUIREMENTS.md) for scope boundaries; [docs/EXECUTION_PLAN.md](./docs/EXECUTION_PLAN.md) for milestone history.

---

## Ground rules that matter

**`MacroManager` is the only module allowed to call protected macro APIs** (`CreateMacro`, `EditMacro`, `DeleteMacro`). Every other module — Classifier, Ranker, Selector, BagScanner, TooltipCache, SpecHelper — must stay pure so the pipeline runs in combat without taint. If you need bag data or tooltip data at macro-write time, call the pure module and pass the result into MacroManager; never import the other direction.

**Macros are identified by name, never slot.** `perCharacter=false` puts them in the account-wide pool (slots 1–120). The addon must never call `DeleteMacro` on a `KCM_*` macro — the slot is the user's.

**English-only.** Classifier compares subType against literal strings; TooltipCache patterns are English. If a Blizzard patch renames a subtype or rewords a tooltip line, edit `ST_*` in `Classifier.lua` or the `PATTERNS` table in `TooltipCache.lua`. Do not introduce localization plumbing — it is explicitly out of scope.

**Seed data is data.** `defaults/Defaults_*.lua` files are just lists of itemIDs that become `KCM.SEED.<CATKEY>`. Updating a seed list is a zero-migration upgrade because the runtime candidate set is `seed ∪ added ∪ discovered − blocked` and the right-side sets live in SavedVariables. See [defaults/README.md](./defaults/README.md) and [docs/REFRESH_ITEMS.md](./docs/REFRESH_ITEMS.md).

**Reset is centralized.** `KCM.ResetAllToDefaults(reason)` in `Core.lua` wipes + resyncs. Both the Options panel "Reset all priorities" button and `/cm reset`'s StaticPopup delegate to it. Don't add a third reset path.

**Priority-list entries are opaque numeric IDs.** Positive numbers are itemIDs; negative numbers are spell-sentinels whose absolute value is the spellID. Seed files compose spell entries via `KCM.ID.AsSpell(spellID)` (see `Core.lua`). The rest of the pipeline — Selector buckets, pins, blocklist, Ranker — treats them as opaque numeric keys, so a negative key works identically to a positive one through every table. Only `MacroManager`, `Ranker.Score`'s spell shortcut, and the UI fork on the sign (`KCM.ID.IsSpell` / `IsItem`) to render `/use item:<id>` vs `/cast <spellname>`. `Selector.MarkDiscovered` rejects spells since bag discovery can't find them; `Selector.AddItem` accepts both so the Options panel's Item/Spell picker can seed either.

**Composite categories don't pick items — they compose other categories' picks.** `KCM_HP_AIO` and `KCM_MP_AIO` are flagged `composite = true` in `Categories.LIST` and carry a `components = { inCombat = {...}, outOfCombat = {...} }` table of single-category refs. `Pipeline.RecomputeOne` branches on `cat.composite` and dispatches to `MacroManager.SetCompositeMacro`, which calls `Selector.PickBestForCategory` per enabled ref and assembles a multi-line body (`/castsequence [combat] reset=combat ...` for the in-combat side, `/use [nocombat] item:N` or `/cast [nocombat] <Spell>` per out-of-combat ref). Composites have no `added/blocked/pins/discovered` buckets — their persisted state is `enabled[ref]` plus the two `orderInCombat`/`orderOutOfCombat` arrays. A sub-category step with no current pick is dropped from the body; if one combat-state side has picks and the other is entirely empty, an extra `/run if [not] InCombatLockdown() then print(...) end` line emits a chat-print fallback for the empty side (since `/run` doesn't accept `[combat]`/`[nocombat]` macro conditionals — those are evaluated by the secure-macro parser, which only attaches them to `/use`/`/cast`/`/castsequence`/etc.). Adding a new composite reuses the existing single-cat picking pipeline — no Classifier, Ranker, or `Defaults_*` file is needed.

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

- Slash forms: `/cm` is the short form, `/consumablemaster` is the long alias. Both are registered in `Core:OnInitialize` (`Core.lua`) and route to `KCM:OnSlashCommand` in `SlashCommands.lua`.
- Every chat line the addon emits — slash output, Options notices, MacroManager warnings, and the `/run print(...)` empty-state bodies embedded in the macros themselves — wears a cyan `|cff00ffff[CM]|r` tag. `SlashCommands.lua` defines a `say()` helper that all dump/help prints route through; the prefix is unconditional. Don't introduce raw `print(...)` calls in the addon — go through `say()` (slash UX), `KCM.Debug.Print` (gated logs), or hard-code the `|cff00ffff[CM]|r ` prefix inline if you need a one-off chat print.
- Toggle verbose logs: `/cm debug`. Internally this flips `KCM.db.profile.debug` through the schema layer (`Helpers.SetAndRefresh("debug", ...)`) so the panel checkbox, `/cm debug`, and `/cm set debug true|false` all share one write+notify+refresh path. Call `KCM.Debug.Print(fmt, ...)` — it early-returns when off, so unconditional calls are safe.
- Dump internals: `/cm dump <target>` where targets are `categories`, `statpriority`, `bags`, `item <id>`, `pick <catKey>`. `DUMP_TARGETS` in `SlashCommands.lua` is a single source of truth — add a row and it appears in help automatically. `item` shows parsed tooltip + raw lines (pattern-debugging view appended); `pick` shows the effective priority list with per-entry ranker scores and the owned-item pick.
- Force a resync: `/cm resync` — invalidates TooltipCache, re-runs discovery, runs a direct (non-coalesced) Recompute.

### Schema-driven slash UX (KickCD-parity)

Every truly-scalar setting lives as a row in `KCM.Settings.Schema` (declared in `Options.lua`). Each row drives both the AceConfig widget (read/write through `Helpers.Get`/`Helpers.SetAndRefresh`) AND the slash CLI:

- `/cm list` — every schema row, grouped by panel, with current value.
- `/cm get <path>` — single-row read (e.g. `/cm get debug`).
- `/cm set <path> <value>` — type-validated write; same code path as the panel widget.

Adding a new scalar = one schema row in `Options.lua`. The validator (`Helpers.ValidateSchema`) lints rows at register-time and prints malformed entries to chat without blocking registration. The schema layer mirrors KickCD's `core/KickCD.lua` + `settings/Panel.lua` design — see `/mnt/d/Profile/Users/Tushar/Documents/GIT/KickCD/` for the reference implementation.

CM's panel state is mostly *list-shaped* (priority lists, per-spec stats, AIO order), which doesn't fit a flat scalar schema. Those operations live in dedicated CLI verbs that follow the same write+notify+refresh contract:

- `/cm priority <cat> list|add|remove|up|down|reset` — per-category priority list editor. `<id>` accepts `12345` or `s:5512` (spell sentinel composed via `KCM.ID.AsSpell`). Composite cats are rejected here — use `/cm aio` instead.
- `/cm stat list|primary|secondary|reset [<specKey>]` — per-spec stat priority. `<specKey>` is `<classID>_<specID>` (canonical) or `CLASS:SPEC` (friendly, e.g. `SHAMAN:ENHANCEMENT`); defaults to current spec.
- `/cm aio <key> list|toggle|up|down|reset` — composite-category editor. Sub-categories are locked to their section, so `up`/`down` infer the section from where the ref appears.

All three namespaces dispatch through `findCommand` against an ordered `*_COMMANDS` table; the help index is generated from the same table — adding a verb = one row.

`Core.lua` has a commented-out per-category recompute log. Uncomment only for short debugging sessions; it fires N × M times during login (N categories × M `GET_ITEM_INFO_RECEIVED` events) and floods chat.

---

## Testing approach

**There are no automated tests.** Validation is manual, in-game:

- Load the addon, log in, verify the eight `KCM_*` macros exist.
- Watch `/cm debug` output during login, bag changes, spec swaps, combat enter/leave.
- Use `/cm dump pick <catKey>` to verify the effective priority list (includes per-entry ranker scores) and the owned pick.
- Use `/cm dump item <itemID>` to pattern-debug tooltip parsing — the command prints the parsed tooltip fields plus the raw tooltip lines underneath.

When changing a scorer, classifier, or tooltip pattern, smoke test:

1. `/cm resync`
2. `/cm dump pick <affected catKey>` — inspect scores (order + why) and the winner.
3. Check the actual macro in the macro UI.

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
4. Add a branch in `Ranker.Explain` for the score-button tooltip — the per-row info button in Options renders `{label, value, note?}` rows from here, so mirror the scorer's additive terms.
5. Create `defaults/Defaults_<NewCat>.lua` that writes `KCM.SEED.<KEY>`.
6. Add the file to `ConsumableMaster.toc` in dependency order.
7. Update the `dbDefaults.profile.categories` table in `Core.lua` so AceDB creates the bucket.
8. Options panel picks the category up automatically from `Categories.LIST`.

### Add a new composite category

Composites don't pick items themselves — they compose other categories' picks via `[combat]`/`[nocombat]` conditionals.

1. Append a row to `KCM.Categories.LIST` with `composite = true` and `components = { inCombat = { <refKeys> }, outOfCombat = { <refKeys> } }`. The refs are keys of existing single-category entries (e.g. `"HS"`, `"HP_POT"`, `"FOOD"`).
2. Add a bucket to `dbDefaults.profile.categories` in `Core.lua` with the composite shape: `{ enabled = { [ref] = true, ... }, orderInCombat = { ... }, orderOutOfCombat = { ... } }`.
3. No Classifier, Ranker, or `Defaults_*` file. No `added/blocked/pins/discovered` buckets. The pipeline already branches on `cat.composite` in `Pipeline.RecomputeOne`, dispatching to `MacroManager.SetCompositeMacro` which handles body assembly, the 255-byte limit, fingerprint cache, and the combat-deferral queue (sharing the same `pendingUpdates` table — composite entries carry `entry.cat` so `FlushPending` can dispatch back to `SetCompositeMacro`).
4. Options panel picks the composite up automatically — `buildCategoryArgs` routes `cat.composite` entries to `buildCompositeArgs`, which renders the *In Combat* / *Out of Combat* sections with toggle + reorder controls and a read-only `KCMItemRow` preview per ref.

### Refresh seed item IDs after a patch

Follow [docs/REFRESH_ITEMS.md](./docs/REFRESH_ITEMS.md). Updating a `defaults/Defaults_*.lua` is safe — user SavedVariables are preserved.

### Fix a misclassification

Run `/cm dump item <id>` to see the subType + parsed tooltip. If subType is wrong, Midnight may have renamed the string — edit `ST_*` in `Classifier.lua`. If the tooltip parse is missing a field, check `PATTERNS` in `TooltipCache.lua` (watch for non-breaking space U+00A0 and `|4singular:plural;` escapes — both are already normalized in `normalizeTooltipText`).

---

## Response style for this repo

- Terse. State the change, not the deliberation.
- Use `file_path:line_number` references when pointing at code.
- Don't write summaries the user can read from the diff.
- **Ship functional, defer polish.** The user has explicitly said: when core functionality lands, move on — don't stop to polish UX mid-milestone. Revisit polish later as a dedicated pass.
- Don't add comments that explain *what* well-named code does. Only add a comment when the *why* is non-obvious (subtle invariant, workaround for a specific Blizzard quirk, a hidden constraint).
- Don't create docs or planning files unless asked.
- **Never auto-stage, auto-commit, or auto-push.** The user chooses when to `git add`, `git commit`, and `git push`. Even after finishing a coherent change, do not run any of these unless the user has explicitly asked for it in the current request. This includes `git add <file>`, `git add -A`, `git add -p`, `git add --renormalize`, `git stash`, or any other index-mutating command. Editing files on disk is fine; touching the git index is not. Offering to stage/commit at the end of a turn is fine; doing it yourself is not.
- **Never bump the version without an explicit instruction.** Do not edit `KCM.VERSION` in `Core.lua`, `## Version:` in `ConsumableMaster.toc`, the version badge / inline version in `README.md`, or add a changelog entry, unless the user has explicitly asked for a version bump in the current request. Releases are the user's call, not a side effect of finishing a feature.

---

## Known Midnight gotchas (for when something breaks at patch time)

- **Consumable subType renames.** `"Potion"` → `"Potions"`, `"Flask"`/`"Phial"` → `"Flasks & Phials"`. Underlying classID/subClassID are unchanged but GetItemInfoInstant returns the display string. If another rename lands, update `Classifier.lua`.
- **`C_TooltipInfo.GetItemByID` returns raw template strings.** Grammar-number escapes like `"for 1 |4hour:hrs;"` are not pre-substituted. `TooltipCache.normalizeTooltipText` strips these; don't bypass it.
- **Non-breaking spaces (U+00A0) between numbers and units.** Lua's `%s` does NOT match NBSP. Normalize first.
- **`GET_ITEM_INFO_RECEIVED` does not fire for already-cached items.** That's why FLASK is classified from subType alone (no tooltip gate) and why discovery retries on this event only help the not-yet-cached case. Don't regress this.
- **Combat lockdown taints protected APIs.** Any path that could reach `EditMacro` must check `InCombatLockdown()` first. The only path that does is `MacroManager.SetMacro` — keep it that way.
- **AceConfigDialog:AddToBlizOptions returns `(frame, categoryID)` on modern clients.** The ID is numeric; passing the frame to `Settings.OpenToCategory` produces a range error. Always capture both return values and pass the ID.
- **The stored macro icon beats `#showtooltip` unless the stored icon is the `?` sentinel (fileID `134400`).** WoW (and action-bar addons like ElvUI/Bartender that render via `GetActionTexture`) only lets `#showtooltip` drive the action-bar button's icon when the macro's stored icon is the `?` file — that fileID is the dynamic-icon sentinel. Any other stored icon wins and `#showtooltip` is ignored on the bar. `MacroManager.iconFor(itemID)` picks the stored icon accordingly: active bodies get `DYNAMIC_ICON = 134400` so `#showtooltip` can adopt the picked item's/spell's icon; empty bodies drop `#showtooltip` entirely and get `DEFAULT_ICON = 7704166` (the cooking pot) so that static icon renders. Never store `DEFAULT_ICON` on an active macro — you'll see the cooking pot on the action bar instead of the flask. The in-Options drag-icon widget (`KCMMacroDragIcon.lua`) resolves to `GetItemIcon(lastItemID)` / `C_Spell.GetSpellTexture(spellID)` directly, since the `?` sentinel looks meaningless on a static UI widget.

---

## File index

- Entry + pipeline + events + `KCM.ID` sentinel helpers: `Core.lua`
- DB schema: `Core.lua` → `KCM.dbDefaults`
- Category metadata: `defaults/Categories.lua`
- Seed items / spells: `defaults/Defaults_*.lua`
- Spec identity + stat priority: `SpecHelper.lua`
- Tooltip parsing (incl. `healOverSec` / `manaOverSec` for HOT pots): `TooltipCache.lua`
- Bag enumeration: `BagScanner.lua`
- Category matching: `Classifier.lua`
- Per-category scorers + `Ranker.Explain` / `Ranker.BuildContext`: `Ranker.lua`
- Candidate set + effective priority + DB mutators: `Selector.lua`
- The only protected-API caller (single picks via `SetMacro`, composite picks via `SetCompositeMacro`, both share the same combat-deferral queue): `MacroManager.lua`
- Settings panel — registers a `Settings.RegisterVerticalLayoutCategory` parent ("Ka0s Consumable Master") and one `AceConfigDialog:AddToBlizOptions` sub-page per top-level options group (General, Stat Priority, then each `Categories.LIST` entry). Each sub-page is scoped via the path arg, so it owns the full canvas — no internal AceConfigDialog tree: `Options.lua`
- `/cm` (and `/consumablemaster` alias) dispatcher driven by an ordered `COMMANDS` table (one row per top-level verb; help is generated from it). Schema-driven `list/get/set` plus dedicated `priority`/`stat`/`aio` verb namespaces (each with their own `*_COMMANDS` table). Reset popup + `say()` helper that prepends the cyan `[CM]` prefix to every chat line live here too: `SlashCommands.lua`
- Debug helper: `Debug.lua`
- AceGUI custom widgets (referenced from `Options.lua` via `dialogControl`):
  - Row of [status] [item icon] [name] [pick star]: `KCMItemRow.lua`
  - Gold-hover icon button used for ↑ / ↓ / × and the add-by-ID row: `KCMIconButton.lua`
  - Info "i" button that shows a per-item score breakdown on hover: `KCMScoreButton.lua`
  - Section heading styled like Blizzard's: `KCMHeading.lua`
  - Draggable macro icon (places `KCM_*` macro on an action bar): `KCMMacroDragIcon.lua`
