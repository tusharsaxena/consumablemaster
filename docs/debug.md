# Debug & diagnostics

The toggle, the dump targets, and the schema-driven slash CLI. All chat output is prefixed with the cyan `|cff00ffff[CM]|r` tag — no raw `print(...)` calls.

## Toggle verbose logging

`/cm debug` flips `KCM.db.profile.debug`. Internally it routes through `Settings.Helpers.SetAndRefresh("debug", next)` so the panel checkbox, `/cm debug`, and `/cm set debug true|false` all share one write+notify+refresh path. Calls to `KCM.Debug.Print(fmt, ...)` early-return when the flag is off, so unconditional calls are safe.

`Debug.lua` is the only sanctioned chokepoint for gated logging:

```lua
KCM.Debug.IsOn()      -- bool
KCM.Debug.Toggle()    -- flips db.profile.debug, prints state, refreshes panel
KCM.Debug.Print(fmt, ...)  -- formatted print prefixed with [CM], no-op when off
```

Don't introduce raw `print(...)` calls. Three sanctioned chat paths:

- `say()` (in `SlashCommands.lua`) — slash output, dump rows, help. Always prepends `[CM]`.
- `KCM.Debug.Print(...)` — gated diagnostics.
- Inline `print("|cff00ffff[CM]|r ...")` — only for one-shot warnings (oversized macro body, give-up notice on flush failure, etc.) where neither helper fits.

## Dump internals

`/cm dump <target>` — inspect runtime state. `DUMP_TARGETS` in `SlashCommands.lua` is the single source of truth; adding a row makes it appear in `/cm dump` help automatically.

| Target | What it shows |
|--------|---------------|
| `categories` | The full `KCM.Categories.LIST` with macro name, display name, spec-awareness flag. |
| `statpriority` | Current spec's stat priority (primary + ordered secondary), with classID / specID / specKey. |
| `bags` | `BagScanner.Scan()` output as `itemID = count`. |
| `item <id>` | Parsed tooltip fields for the item plus the raw tooltip lines (pattern-debugging view). Shows `pending: tooltip data not yet loaded` if the data hasn't hydrated yet. |
| `pick <catKey>` | The effective priority list with per-entry Ranker scores, an `[owned]` tag for entries you actually have, and a `<-- pick` marker on the winner. Composite catKeys (`hp_aio` / `mp_aio`) print the configured order, per-sub-cat picks, and the assembled macro body. |

`<catKey>` is case-insensitive (`flask`, `FLASK`, `hp_aio` all work).

## Force a resync

`/cm resync` — invalidates `TooltipCache`, re-runs auto-discovery against bags, then runs a direct (non-coalesced) `Pipeline.Recompute`. Use after editing a scorer / classifier / tooltip pattern to force a fresh evaluation.

`/cm rewritemacros` (alias `/cm rewrite`) — clears `macroState` + `pendingUpdates` + the oversized-warning gate via `MacroManager.InvalidateState()`, then runs `Pipeline.Recompute` so every macro is re-issued unconditionally. Use when an action-bar icon looks stale (some bar frameworks cache `GetActionTexture` results across an `EditMacro`; a `/reload` after the rewrite forces a re-query).

## Schema-driven slash UX (KickCD parity)

Scalar settings live as rows in `KCM.Settings.Schema` (declared in `settings/Panel.lua`). Each row drives both the General-panel widget (rendered by `Helpers.RenderField` in `settings/General.lua`) AND the slash CLI:

| Slash | Effect |
|-------|--------|
| `/cm list` | Every schema row, grouped by panel, with current value. |
| `/cm get <path>` | Single-row read (e.g. `/cm get debug`). |
| `/cm set <path> <value>` | Type-validated write through `Helpers.SetAndRefresh`; same code path as the panel widget. |

Adding a new scalar = one schema row. Row shape:

```lua
Schema[#Schema + 1] = {
    panel    = "general", section = "general", group = "Diagnostics",
    path     = "debug",   type    = "bool",
    label    = "Debug mode",
    tooltip  = "Print per-event diagnostics to chat. Same as /cm debug.",
    default  = false,
    onChange = function(v) ... end,    -- optional
}
```

`Helpers.ValidateSchema()` lints rows at register-time and prints malformed entries to chat without blocking registration. The schema is the *capacity* for future scalars; today only `general.debug` is wired in.

## List-shaped state — verb namespaces

CM's panel state is mostly list-shaped (priority lists, AIO order, per-spec stats), which doesn't fit a flat scalar schema. Those operations live behind dedicated CLI verbs that follow the same write+notify+refresh contract:

| Verb namespace | Verbs | Notes |
|----------------|-------|-------|
| `/cm priority <cat>` | `list / add / remove / up / down / reset` | `<id>` accepts `12345` (item) or `s:5512` (spell sentinel via `KCM.ID.AsSpell`). Composite categories rejected — use `/cm aio`. |
| `/cm stat` | `list / primary / secondary / reset [<specKey>]` | `<specKey>` is canonical `<classID>_<specID>` or friendly `CLASS:SPEC` (e.g. `SHAMAN:ENHANCEMENT`); defaults to current spec. |
| `/cm aio <key>` | `list / toggle / up / down / reset` | Sub-categories are locked to their section, so `up` / `down` infer the section from where the ref appears. |

All three namespaces dispatch through `findCommand` against an ordered `*_COMMANDS` table; help is generated from the same table. Adding a verb = one row.

## Per-category recompute log

`Core.lua` has a commented-out per-category recompute log (search for "Pipeline.RecomputeOne" near `KCM.Debug.Print`). It fires `N × M` times during login (N categories × M `GET_ITEM_INFO_RECEIVED` events) and floods chat. Uncomment only for short debugging sessions, then re-comment.

## Smoke test recipe

When changing a scorer, classifier, or tooltip pattern:

1. `/cm resync`
2. `/cm dump pick <affected catKey>` — inspect scores (order + why) and the winner.
3. Open the macro UI and check the body of the relevant `KCM_*` macro.
4. For UI changes: open the Options panel page for the affected category.
