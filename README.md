# Ka0s Consumable Master

An auto-managed consumable-macro addon for **World of Warcraft: Midnight** (Retail, Interface 120000). Keeps a fixed set of account-wide global macros pointed at the single best consumable currently in your bags, for eight categories — so you never rebuild a food / flask / potion macro again.

**Slash prefix:** `/kcm`
**Framework:** Ace3 (AceAddon, AceEvent, AceDB, AceConsole, AceConfig)
**Version:** 0.1.0
**Locale:** English only

---

## What it does

Every time you loot a better food, swap spec, reload, or leave combat, Ka0s Consumable Master re-runs its pipeline and rewrites each macro's body to `#showtooltip / /use item:<best>`. The macros live in the **account-wide** pool (identified by name — the addon never hardcodes a slot), so they're shared across every character, survive slot reordering, and coexist with every other macro in your list.

| # | Category                  | Macro           | Spec-aware? |
|---|---------------------------|-----------------|-------------|
| 1 | Basic / conjured food     | `KCM_FOOD`      | No          |
| 2 | Drink (mana regen)        | `KCM_DRINK`     | No          |
| 3 | Stat food                 | `KCM_STAT_FOOD` | **Yes**     |
| 4 | Healing potion            | `KCM_HP_POT`    | No          |
| 5 | Mana potion               | `KCM_MP_POT`    | No          |
| 6 | Warlock healthstone       | `KCM_HS`        | No          |
| 7 | Combat potion (throughput)| `KCM_CMBT_POT`  | **Yes**     |
| 8 | Flask                     | `KCM_FLASK`     | **Yes**     |

Selection is three layers: **shipped seed list ∪ your added items ∪ auto-discovered bag items − your blocklist**, then ranked by tooltip-parsed heal / mana / stat value (spec-aware for the three stat categories), then pin-adjusted if you reorder rows in the settings panel. The first entry you actually own wins; if you own none, the macro prints a friendly `KCM: no X in bags` stub so the slot stays valid.

Macro writes that would land during combat are queued and flushed on `PLAYER_REGEN_ENABLED` — the addon never calls a protected macro API in combat.

---

## Usage

1. Install the addon using the Addon Manager of choice, or manually
2. Launch the game. The addon initializes on login — first `PLAYER_ENTERING_WORLD` scans bags, discovers known items, and writes all eight macros.
3. Drag the new `KCM_*` macros onto your action bars from the macro UI.

| Command              | What it does                                                           |
|----------------------|------------------------------------------------------------------------|
| `/kcm`               | Show help.                                                             |
| `/kcm config`        | Open the settings panel (priority lists, spec selector, add-by-ID).    |
| `/kcm resync`        | Force a full rescan: invalidate tooltip cache, re-discover, recompute. |
| `/kcm reset`         | Confirm-and-reset every priority list and stat override to defaults.   |
| `/kcm debug`         | Toggle verbose logging.                                                |
| `/kcm dump <target>` | Inspect internal state (categories, stat priority, bags, item, rank, pick, raw). |

The settings panel (also reachable via Escape → Options → AddOns → Ka0s Consumable Master) gives you:

- **Per-category priority list** with ↑ / ↓ / X buttons and an **Add item by ID** box.
- **Spec selector** on the three spec-aware categories (Stat Food, Combat Pot, Flask).
- **Stat priority editor** (primary stat + ordered secondary stats) for the active or viewed spec.
- **Reset this category** and a global **Reset all priorities** execute.

---

## Docs

- [ARCHITECTURE.md](ARCHITECTURE.md) — short-form architecture map for orientation.
- [CLAUDE.md](CLAUDE.md) — guidance for Claude Code / LLM-assisted sessions.
- [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) — what the addon does, category scope, constraints.
- [docs/TECHNICAL_DESIGN.md](docs/TECHNICAL_DESIGN.md) — full internal design (module contracts, DB schema, events, tooltip parsing).
- [docs/EXECUTION_PLAN.md](docs/EXECUTION_PLAN.md) — milestone plan / history.
- [docs/RESEARCH.md](docs/RESEARCH.md) — notes on Blizzard APIs, Ace3 patterns, Midnight changes.
- [docs/REFRESH_ITEMS.md](docs/REFRESH_ITEMS.md) — procedure for refreshing seed item lists each patch.
- [defaults/README.md](defaults/README.md) — seed data layout and source citations.
