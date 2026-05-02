# Review Findings — Ka0s Consumable Master

**Date:** 2026-05-02
**Reviewer:** principal-level engineering review (Claude)
**Scope:** Full addon at `/mnt/d/Profile/Users/Tushar/Documents/GIT/ConsumableMaster/` excluding `libs/`.

---

## Verdict

**Minor issues.** No critical bugs, no taint leaks, no protected-API misuse, no deprecated-API breakage. The taint-firewall (`MacroManager`-only protected calls), composite-bucket invariant, opaque-ID convention, and centralized reset are all upheld in the source. The findings below are mostly polish, dead surface area, low-impact correctness gaps, and a few UX/CLI inconsistencies — none of them block ship.

Counts: **Critical: 0  · High: 1  · Medium: 13  · Low: 9**

> The single High is a CLI-feedback path that prints success-shaped output even when the underlying write was rejected. Everything else is Medium or below.

---

## High

### F-001 [design][ux] `/cm set` prints success-shaped feedback even when `SetAndRefresh` rejects the write
**File:** `SlashCommands.lua:603-604`

```lua
H.SetAndRefresh(def.path, newValue)
say(("%s = %s"):format(def.path, formatValue(def, H.Get(def.path))))
```

`H.SetAndRefresh` returns `false` when `Helpers.Set → Helpers.Resolve(path)` fails — for example mid-init when `KCM.db.profile` isn't yet hydrated. On that rejected-write path the chat line still prints the *old* value as if the set succeeded. The pre-validation by `H.FindSchema(def.path)` only protects against an unknown schema path, not a Resolve failure. Easy fix: check the return before printing.

**Impact:** confusing CLI feedback if `/cm set` is invoked before `OnInitialize` has hydrated `db`. Low real-world incidence (the user repeats the command and it works the second time), but the contract is wrong.

---

## Medium

### F-002 [design] Dead exports never called from any non-`libs/` `.lua`
**Files:** `BagScanner.lua:60` (`GetAllItemIDs`), `MacroManager.lua:235`/`239`/`523` (`HasPending`/`PendingCount`/`IsAdopted`), `TooltipCache.lua:112`/`117`/`363` (`IsPending`/`PendingIDs`/`Stats`), `settings/Panel.lua:90`/`470` (`SchemaForPanel`/`MakeCheckbox`).

Verified by grep across `*.lua` (excluding `libs/`): nothing in production calls these. They are documented in `docs/module-map.md` as part of the public surface. Either they're test/debug aids never wired up, or they were planned API that never landed. Dead public surface drifts out of sync with the rest of the code over time.

**Impact:** API noise, ambient maintenance burden when refactoring callers (you have to verify nothing depends on a function you can't search-grep). Documentation lies about what's actually used.

### F-003 [design][correctness] `Pipeline.Recompute` skips the panel refresh when master enable is off
**File:** `Core.lua:124-129` vs `Core.lua:151-155`

When `db.profile.enabled == false`, `Pipeline.Recompute` early-returns at line 128 — it never reaches the `Options.RequestRefresh()` call at line 151. That's the right behaviour for skipping macro writes, but it also means the panel never re-renders for events that fire while the addon is off (item info storms, bag updates). On re-enable, the off→on transition kicks one recompute, which refreshes the panel; users opening the panel while the addon is OFF still see live bag data because `RequestRecompute` won't have run since the last user action — but priority list rows that haven't hydrated yet will sit on `[Loading]` until the user re-enables the addon.

**Impact:** stale `[Loading]` placeholders in the priority list when the panel is opened with master enable off.

### F-004 [bug][correctness] Spec change does not refresh the Options panel's `_viewedSpec`
**Files:** `Core.lua:297` (`OnSpecChanged`), `settings/StatPriority.lua:24-50`

`OnSpecChanged` only requests a recompute. The `_viewedSpec` panel state is sticky — `resolveViewedSpec()` populates it once on first render, then never re-checks. After spec change the panel keeps showing the old spec's priority list / stat editor until the user manually picks the new spec from the dropdown, even though every spec-aware macro has already retargeted to the new spec. This is debatably "by design" (so the user can edit any spec while on another) but the docs say "viewing spec defaults to your current spec" — that's only true on first open of the panel.

**Impact:** confusing UX after a respec — viewed spec, current spec, and macro picks disagree until the user notices.

### F-005 [bug][correctness] Secondary-stat compaction silently drops mid-list gaps and duplicates
**File:** `settings/StatPriority.lua:116-119`

```lua
for _, s in ipairs(cur.secondary) do
    if s and s ~= "" then table.insert(compacted, s) end
end
```

If the user picks `{CRIT, "(none)", CRIT, MASTERY}`, this compacts to `{CRIT, CRIT, MASTERY}` — silently inserting a duplicate that the Ranker's `statWeight` will weight twice. The settings UI should either reject duplicates outright or dedupe; gaps probably shouldn't shift later picks up (the user expecting position 3 to mean "third" gets surprised when their pick shows in position 2). The CLI `/cm stat secondary` validates against `SECONDARY_STATS` but does not dedupe either.

**Impact:** unexpected scoring when the user makes a pick that looks valid but produces duplicate weights.

### F-006 [design] Two panel-registration paths run on every login
**File:** `Core.lua:67-69`, `settings/Panel.lua:695-728`

`Settings.RegisterAddOnCategory` lands during `OnInitialize` (via `KCM.Options.Register()` → `registerPanel()`) AND from a bootstrap event listener for `PLAYER_LOGIN` / `ADDON_LOADED`. Idempotency via `if KCM.Settings.main then return end` keeps it correct today, but the dual-path design hides which path actually wins and adds load-order fragility: if a future Blizzard change makes `Settings.Register*` unavailable until `PLAYER_LOGIN`, the `OnInitialize` invocation silently no-ops at the early return at lines 697-700, and the bootstrap listener becomes the sole live path.

**Impact:** load-order fragility, dual init paths that need to stay in sync.

### F-007 [design] Single-write-path bypassed: many DB writes skip `Helpers.Set`
**Files:** `Selector.lua` (multiple mutators), `settings/StatPriority.lua:120-124`, `settings/Category.lua:141-144`/`133-135`/`504-509`/`518-519`/`530-531`, `SlashCommands.lua:793-795`/`882-885`/`914-917`/`928-931`/`1048`/`1071`/`1084-1086`, `Core.lua:265-266`.

`Helpers.Set` (`settings/Panel.lua:82`) is documented as the canonical setter and routes through `FireConfigChanged`. It's used by exactly one code path (the schema-driven flat-row writes via `SetAndRefresh`). Every other DB write — pin reorder, AIO toggle, AIO order swap, stat-priority writes, reset-to-defaults table replacement, bucket clears — goes direct. `FireConfigChanged` is a stub today (`Helpers.FireConfigChanged` at Panel.lua:76 is a no-op), so there's no live regression, but the **single-write-path** convention the existence of `Helpers.Set` implies is not actually held. If the day comes when `FireConfigChanged` needs to do something — invalidate a cache, fire a signal, mark dirty for save — every bypass site becomes a latent bug.

**Impact:** a documented convention not enforced today; either the convention should go away (delete `Helpers.Set` + `FireConfigChanged`) or the bypassing call sites should be migrated.

### F-008 [perf][hot-path] `Classifier.MatchAny` walks composite categories on every discovery hit
**File:** `Classifier.lua:153-164`

```lua
for _, cat in ipairs(KCM.Categories.LIST) do
    if C.Match(cat.key, itemID) then ...
```

The list has 10 entries; 2 of them (HP_AIO, MP_AIO) are composite and never have a matcher (`matchers[catKey]` is nil → `C.Match` returns false at line 115). Wasted iterations × every bag item × every PEW + BAG_UPDATE_DELAYED + GIIR retry. Trivial perf — this is a 20% reduction in a function called dozens of times per second on first login — but it's also a *type* problem: `MatchAny` mixes single and composite categories with no protection.

**Impact:** ~20% wasted classification work; if a future composite cat ships with a typo'd matcher it'll silently fail.

### F-009 [perf][correctness] `bestImmediateAmount` recomputes on every `BuildContext` call even with `scoreCache`
**File:** `Ranker.lua:135-152` + `Ranker.lua:282-290`

`BuildContext` is called by `SortCandidates` once per category per recompute, then again by panel renderers per row tooltip rebuild via `Explain`. Each call walks `itemIDs` and pulls `tt` per id — the early branch at line 140 hits the field cache, so the cost is small, but the *result* itself isn't memoized in `scoreCache`. Stash `scoreCache.bestImmediate[catKey]` so the panel-side per-row Explain calls don't redo the walk for HP_POT / MP_POT.

**Impact:** small, but the structure does more work than it should during panel renders.

### F-010 [naming][doc] `specLabelCache` per-key invalidation comment is misleading
**File:** `settings/StatPriority.lua:193`

The label cache stores `class — spec |T<icon>|t` strings keyed by `specKey`. The `specLabelCache[v] = nil  -- icon fileID may have changed across logins` comment claims protection against an event that doesn't happen mid-session — the cache is a file-local table that's rebuilt fresh on every fresh load. Either drop the per-key invalidation (no observed value), or move the invalidation to a real trigger.

**Impact:** code that protects against an event that doesn't happen at the time the protection runs; minor confusion when reading.

### F-011 [design][taint] `KCM.ResetAllToDefaults` calls `Pipeline.Recompute` (not `RequestRecompute`) directly
**File:** `Core.lua:274-276`

Calling `Recompute` rather than `RequestRecompute` is an explicit choice (write-this-tick), and during normal use it's safe because `MacroManager` defers protected calls when `InCombatLockdown()` is true. The comment at line 257-258 explicitly notes "this is safe to run without a combat guard" — depending on the queue rather than guarding feels like the wrong default. A user who reads the code can't easily verify the guarantee. The contract is correct today, but if it ever changes (e.g. a future module learns to write macros), this path quietly becomes a taint hazard. Worth annotating loudly.

**Impact:** correct today, but the contract relies on `MacroManager` always being the only protected-API caller. Documentation only.

### F-012 [design] `_inCombat` flag is set/cleared but never read
**File:** `Core.lua:301-303`, `Core.lua:305-313`

`KCM._inCombat` is written but never read by anyone — every actual combat gate uses `InCombatLockdown()` directly. The flag is dead state. Either remove the writes or wire it into a check (probably the former — `InCombatLockdown()` is the canonical truth).

**Impact:** dead state, maintenance noise.

### F-013 [ux][cli] `/cm priority <cat> reset` chat confirmation does not say discovered items are preserved
**File:** `SlashCommands.lua:785-799`

```lua
say(("reset %s%s — added/blocked/pins cleared.")
```

`discovered` is intentionally preserved (matches the panel popup `KCM_RESET_CATEGORY`). The chat says "added/blocked/pins cleared" — true, but a user who reads "reset cat" expects a full restore. The README "Reset category" tooltip text correctly notes "Discovered items (from bag scans) are preserved"; the CLI confirmation does not.

**Impact:** users using the CLI may not realize `reset` keeps discovered items.

### F-014 [design][naming] `Helpers.Set`'s `section` parameter is unused after the FireConfigChanged stub
**File:** `settings/Panel.lua:82-88`

```lua
function Helpers.Set(path, section, value)
    ...
    Helpers.FireConfigChanged(section)
```

`section` is forwarded to a stub. Today every caller passes `def.section` from the schema, but the section value never affects behaviour. This is forward-looking, but it locks every caller into producing a `section` value that's never used. Either commit (wire up CallbackHandler so consumers can subscribe to section-level changes) or unwire (drop the `section` param + `FireConfigChanged`).

**Impact:** API shape promises an extension point that doesn't exist.

---

## Low

### F-015 [naming] `Debug.Toggle` shadows Lua's built-in `next`
**File:** `Debug.lua:17`

```lua
local next = not KCM.db.profile.debug
```

Shadowing the global `next` inside this function is harmless (it's not used as a function later in this scope) but is a smell — the variable is the new value, so call it `newValue` or `nextValue`.

**Impact:** readability only.

### F-016 [naming][comment] Comments reference removed deliberation, not invariants
**Files:** `Core.lua:108-113`, `MacroManager.lua:33-36`

Several comments document past debate ("uncomment for debugging pick resolution", "Cleared only on /reload — that's a feature: the user reported it once, further noise is waste"). They're fine as code archaeology, but a future reader may not know whether to trust the rationale. Annotate with rough date / version when the decision was made.

**Impact:** comment freshness drift.

### F-017 [perf] `formatNumber` allocates a reversed string per call
**File:** `settings/Category.lua:78-85`

Per priority list row this is invoked twice (score in tooltip header + per signal). With 30 rows × ~5 signals each, ~300 `string.reverse + gsub + reverse` chain calls per panel render. The format is human-readable thousands separators; no problem if the panel renders rarely, but it does re-render on every mutation and on every `RequestRefresh` debounce.

**Impact:** minor; a single forward `gsub` would do.

### F-018 [naming] Confusing `local R = KCM.Ranker` vs `local R = KCM.<anything>` shorthand
**Files:** various

Each module exports as `KCM.X` and keeps a one-letter local. Most are obvious in context (`S` for Selector, `M` for MacroManager) but `R` is Ranker in `Ranker.lua` and unrelated elsewhere. Not breaking, but readers grepping for `R\.` cross-module get noisy hits.

**Impact:** readability.

### F-019 [naming] `KCMItemRow.lua`'s `applyLabelWidth` constants are duplicated
**File:** `KCMItemRow.lua:108-115`

`leftOffset` / `rightOffset` are hardcoded numbers (20, 4, 22, 4, 14, 1, 22, 4) that mirror `OWNED_ICON_SIZE`, `ICON_GAP`, `ICON_SIZE`, `QUALITY_SIZE`, `QUALITY_GAP`, `PICK_SIZE` — all already named constants at the top of the file. If any of those constants change, `applyLabelWidth` silently desynchronizes from layout reality. Worth deriving from the named constants.

**Impact:** layout fragility on a config-constant change.

### F-020 [perf] `KCMItemRow.craftingQualityAtlas` calls `GetItemInfo` separately from `RefreshDisplay`
**File:** `KCMItemRow.lua:126-142`

`craftingQualityAtlas` does its own `GetItemInfo(itemID)` for the link (line 127), then calls `C_TradeSkillUI.GetItem*QualityInfo(link)`. With 30 rows × full re-render, this is ~30 `GetItemInfo` calls in addition to the `iconForItem` and `itemDisplayName` calls already happening per row. Cheap individually; could be folded into a per-render itemInfo memo.

**Impact:** small redundant work in panel renders.

### F-021 [bug][correctness] `dropdownAllowed` always coerces values via `tostring` even for numeric values
**File:** `SlashCommands.lua:556-560`

```lua
out[i] = tostring(item.value)
```

If a future schema row uses a number-typed dropdown, this stringifies it for the comparison at line 587 against the user's text input — but the schema row's `def.values[].value` could already be a number, and the user typed a string. Today nothing ships a numeric dropdown. Latent bug if one is added.

**Impact:** latent — one schema row away.

### F-022 [doc][ux] `/cm resync` and `/cm rewritemacros` print "in combat — macro writes deferred until regen" but proceed to call `Pipeline.Recompute` synchronously
**Files:** `SlashCommands.lua:1158-1171`, `1175-1184`

Both hit the same pattern: print combat warning, then call `Pipeline.Recompute` regardless. Recompute itself runs Selector / Ranker (pure) and feeds MacroManager which queues the writes. Behaviourally fine, but the "in combat" warning followed by the synchronous Recompute can confuse a user who expects "deferred until regen" to mean "nothing happened just now". The warning could read "in combat — picks computed now, macro writes will apply when combat ends" or similar.

**Impact:** UX clarity only.

### F-023 [doc] Doc index references — verify file existence on every doc edit
**File:** `defaults/README.md` (referenced from `CLAUDE.md` doc index)

Cosmetic only. Verified via `ls`; the file exists.

**Impact:** none today.

---

## Notes & non-issues (deliberately not flagged)

- **Event registrations** — all in `OnEnable`, all documented, including the modern `LEARNED_SPELL_IN_SKILL_LINE` replacement for the removed `LEARNED_SPELL_IN_TAB`. Good.
- **Protected APIs** — `CreateMacro` / `EditMacro` strictly behind MacroManager and `InCombatLockdown()` checks. `KCMMacroDragIcon` calls only `PickupMacro` (unprotected) and `GetMacroInfo` (read-only). `GetMacroIndexByName` is read-only and used outside MacroManager only by `KCMMacroDragIcon` and `M.IsAdopted`. All within bounds.
- **Combat lockdown** — every macro-touching path I could trace is guarded.
- **Settings.OpenToCategory** — correctly passes the numeric `categoryID` (`Core.lua` stores `main:GetID()` at registration time; `Open()` reads the numeric ID).
- **NBSP / `|4...;` grammar escapes** — `TooltipCache.normalizeTooltipText` normalises both, parsers run after normalisation. Good.
- **Deprecated APIs** — Classifier, Ranker, TooltipCache use `GetItemInfo` (still the documented retail API for multi-return name/quality/ilvl/subType); both `C_Item.GetItemInfoInstant` and `C_AddOns.GetAddOnMetadata` are used as the modern path with legacy fallbacks. `C_Spell.GetSpellName` is the primary spell-name lookup with `C_Spell.GetSpellInfo` / `GetSpellInfo` fallbacks. Not flagging these — the current state is "modern path with documented legacy fallback". If `GetItemInfo` is ever fully removed by Blizzard the addon needs an audit, but I cannot find documentation that it's removed in 12.0.x.
- **TOC interface line** — `120000,120001,120005` matches the current Midnight build cycle.
- **`.gitattributes`** — declares `text=auto eol=crlf` (project requested CRLF).
- **`COMMANDS` table vs README** — every README-listed slash command (`config`, `resync`, `rewritemacros`, `reset`, `debug`, `version`, `list`, `get`, `set`, `priority`, `stat`, `aio`, `dump`) appears in the `COMMANDS` table. `help` is in the table but not the README — that's fine.
- **DUMP_TARGETS / DUMP_ORDER** — every key in `DUMP_TARGETS` is in `DUMP_ORDER` and vice versa.
- **`emptyText` vs `CHAT_PREFIX`** — the addon uses an inline `|cff00ffff[CM]|r` literal in macro `emptyText` strings (`defaults/Categories.lua`) and a shared `PREFIX` local in `Debug.lua` / `SlashCommands.lua`. There is no project-wide `CHAT_PREFIX` constant; the duplication is small and the shape is consistent. Not flagging.
- **Schema rows missing `tooltip`** — both schema rows have `tooltip` set. No flag.
- **Hardcoded subType strings** — they live as `ST_*` constants in `Classifier.lua`. No flag.
- **AceConfig icon-button pattern** — addon uses custom AceGUI widgets with `image` properties; never embeds `|T...|t` in button text. Good.
- **`AceConfigDialog:AddToBlizOptions` return-value mishandling** — addon doesn't use AceConfigDialog at all (hand-built canvas). Not applicable.
- **Subcategory `appName` collision** — addon uses `Settings.RegisterCanvasLayoutSubcategory`, not AceConfig. Not applicable.
- **`docs/CLAUDE_SECRET_VALUES.md`** — does not exist; addon does not appear to handle secret-valued protected returns. `docs/midnight-quirks.md` discusses the topic but no secret values are bound in the source today. No flag.
