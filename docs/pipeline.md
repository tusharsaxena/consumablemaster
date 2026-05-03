# Pipeline

The recompute path: how events become macro writes. Coalescing, the per-pass score cache, combat deferral, and the events that drive the whole thing.

## Pull-based, frame-coalesced

```
event ──▶ RequestRecompute(reason)
            │  sets _recomputePending, schedules C_Timer.After(0, ...)
            │  multiple events in the same frame collapse to one run
            ▼
          Recompute(reason)
            │  if db.profile.enabled == false:
            │      Debug.Print("skipped (disabled)")     -- master enable gate
            │      return                                -- no-op; macros keep
            │                                            -- last-written body
            │  scoreCache = { fields = {} }              -- fresh per pass
            │  for each cat in Categories.LIST:
            │      pcall(RecomputeOne, cat.key, scoreCache, reason)
            │         if cat.composite:
            │             MacroManager.SetCompositeMacro(cat, scoreCache)
            │             (resolves each enabled ref via
            │              Selector.PickBestForCategory under the hood)
            │         else:
            │             pick = Selector.PickBestForCategory(cat.key, nil, scoreCache)
            │             MacroManager.SetMacro(cat.macroName, pick, cat.key)
            │  Options.RequestRefresh()                  -- debounced panel rebuild
            ▼
          per-category:
              Selector.GetEffectivePriority(catKey, specKey, scoreCache)
                  candidates = BuildCandidateSet(catKey)                    -- pure
                  sorted     = Ranker.SortCandidates(cat, cands, ctx, cache) -- pure
                  final      = mergePins(sorted, bucket.pins)               -- pure
              walk final, return first id BagScanner.HasItem says you own
              (items) or IsPlayerSpell confirms (spell sentinels)
```

## Coalescing — `RequestRecompute`

Defined in `Core.lua` (`KCM.Pipeline.RequestRecompute`):

```lua
function P.RequestRecompute(reason)
    KCM._recomputePending = true
    KCM._recomputeReason  = reason or KCM._recomputeReason or "unknown"
    if KCM._recomputeScheduled then return end
    KCM._recomputeScheduled = true
    C_Timer.After(0, function()
        KCM._recomputeScheduled = false
        if KCM._recomputePending then
            local r = KCM._recomputeReason
            KCM._recomputePending = false
            KCM._recomputeReason  = nil
            P.Recompute(r)
        end
    end)
end
```

`C_Timer.After(0, ...)` defers to end-of-frame, which collapses a flurry of events (e.g. multiple `BAG_UPDATE_DELAYED` during loot) into a single pipeline run. Event handlers should call `RequestRecompute`, not `Recompute` directly — except the rare direct paths (`KCM.ResetAllToDefaults`, `/cm resync`, `/cm rewritemacros`) where the write should land this tick.

## Per-category isolation — `pcall`

```lua
for _, cat in ipairs(KCM.Categories.LIST) do
    local ok, err = pcall(P.RecomputeOne, cat.key, scoreCache, reason)
    if not ok and KCM.Debug and KCM.Debug.Print then
        KCM.Debug.Print("Recompute %s failed: %s", cat.key, tostring(err))
    end
end
```

A bad scorer in one category can no longer break the other nine macros. The `pcall` cost is negligible (10 per recompute, recompute fires at most once per frame).

## Score cache — H-4

`scoreCache` is a single Lua table created at the top of `Pipeline.Recompute` and threaded through `RecomputeOne` → `PickBestForCategory` → `SortCandidates` → `Score`. It memoizes:

- `scoreCache.fields[id]` — the `GetItemInfo` + `TooltipCache.Get` lookup. Shared across categories so an item appearing in multiple candidate sets isn't re-parsed.
- `scoreCache[catKey][id]` — the per-category score. Spell entries short-circuit and don't populate this; item scores are full Ranker output.

The same `scoreCache` is also handed to `MacroManager.SetCompositeMacro`, which calls `Selector.PickBestForCategory(refKey, nil, scoreCache)` for each enabled sub-cat. Items that appear in both a single-pick category's macro write and a composite's reference resolution share the cache hit.

### Lifetime

- Created at the top of `Pipeline.Recompute`.
- Discarded when `Pipeline.Recompute` returns.
- **Panel-only renders** (Options panel building rows, `/cm dump pick`) pass `nil` and fall back to direct computation. Ranker tolerates a nil cache. This preserves the live-data view — panel rows always reflect current state, never a stale snapshot.

### Why one pass, not persistent

Tooltip / bag / spec state can shift between events. A persistent cache would serve stale picks. The per-pass cache is just enough to deduplicate work *within one recompute*.

## Events

Wired in `Core:OnEnable`:

| Event | Handler | What it does |
|-------|---------|--------------|
| `PLAYER_ENTERING_WORLD` | `OnPlayerEnteringWorld` | Run `runAutoDiscovery`, then `Selector.SweepStaleDiscovered(time())`, then `RequestRecompute`. Sweep runs after discovery so bumped timestamps are seen, and before recompute so the cleaned-up set feeds the first pick. |
| `BAG_UPDATE_DELAYED` | `OnBagUpdateDelayed` | `runAutoDiscovery` + `RequestRecompute`. |
| `PLAYER_SPECIALIZATION_CHANGED` | `OnSpecChanged` | `RequestRecompute`. |
| `PLAYER_REGEN_ENABLED` | `OnRegenEnabled` | `MacroManager.FlushPending()` — applies queued combat-deferred writes. |
| `GET_ITEM_INFO_RECEIVED` | `OnItemInfoReceived` | `TooltipCache.Invalidate(id)`, then split: bag items → `discoverOne` + `RequestRecompute`; non-bag items → `Options.RequestRefresh` only. See [GIIR bag/non-bag split](#giir-bagnon-bag-split). |
| `LEARNED_SPELL_IN_SKILL_LINE` | `OnLearnedSpell` | `RequestRecompute("learned_spell")`. Closes the window where `spellNameFor()` returned nil because the spell book hadn't hydrated yet, but the spell becomes known later in the same session without a spec change or bag event. |

### GIIR bag/non-bag split

`OnItemInfoReceived` is the hottest event by frequency on first panel open. Opening Options hydrates ~150 priority-list items that aren't in bags, each fires this event as data arrives, and a full `Pipeline.Recompute` per fire (160+ tooltip parses × dozens of events / sec) tanks FPS for 5–10 seconds. Non-bag items can never affect a macro pick — macros only select from bag items — so the recompute is pure waste.

The split:

```
TooltipCache.Invalidate(itemID)
if BagScanner.HasItem(itemID):
    discoverOne(itemID, "item_info_received")     -- retry classification
    Pipeline.RequestRecompute("item_info_received")
else:
    Options.RequestRefresh()                      -- debounced panel-only refresh
```

The retry exists because `Classifier.Match` returns false while a tooltip is pending; without it, items present in bags from `/reload` silently skip discovery on the first pass and never re-enter the candidate set until bags change.

## Combat deferral

```
BAG_UPDATE_DELAYED in combat:
    runAutoDiscovery (pure)
    Pipeline.RequestRecompute("bag_update_delayed")
        → Recompute runs (Selector / Ranker / Classifier are pure)
        → MacroManager.SetMacro: InCombatLockdown() true → enqueue in pendingUpdates
PLAYER_REGEN_ENABLED:
    MacroManager.FlushPending()   -- bounded retries
```

No protected API is called during combat. Selector, Ranker, Classifier, BagScanner, TooltipCache, SpecHelper are pure and combat-safe. Only `MacroManager.SetMacro` / `SetCompositeMacro` reach `EditMacro` / `CreateMacro`, and they early-out on `InCombatLockdown()`. The combat gate is `InCombatLockdown()` itself — no separate flag.

`pendingUpdates[macroName]` carries `{ body, itemID, catKey, attempts }` for single picks or `{ body, itemID=nil, catKey, cat, attempts }` for composites — composite entries carry `cat` so `FlushPending` can dispatch back to `SetCompositeMacro`. Last-write-wins: if the body changes again before `PLAYER_REGEN_ENABLED`, only the final version is applied. See [macro-manager.md](./macro-manager.md#flush-retry).

## First-run / defaults seeding

`Core:OnInitialize`:

1. `self.db = LibStub("AceDB-3.0"):New("ConsumableMasterDB", KCM.dbDefaults, true)`.
2. `schemaVersion` is set to `1` on fresh install.
3. Defaults files are Lua constants (`KCM.SEED.<CAT> = { ... }`), **not** copied into SavedVariables. The candidate set is computed at recompute time as `(seed ∪ added ∪ discovered) − blocked`.
4. Stat-priority defaults follow the same model: `KCM.SEED.STAT_PRIORITY[<spec>]`. Only user overrides go into SavedVariables.
5. The first recompute happens after `PLAYER_ENTERING_WORLD`, post-discovery and post-sweep.

## Performance budget

Hot paths: PEW (login + reload), `BAG_UPDATE_DELAYED` storms, `GET_ITEM_INFO_RECEIVED` bursts, Options panel open / refresh.

Per-recompute cost:

1. **`BagScanner.Scan`** — one pass, ~5 bags × ~30 slots. ~1 ms.
2. **Score cache** — on a full 10-category recompute covering ~50 total candidates, TooltipCache + scorer work is incurred once per `(catKey, id)`. Estimated 3–5× reduction vs no-cache on warm cache, 8–10× on cold cache.
3. **`BagScanner.HasItem`** — single `C_Item.GetItemCount` call. `GET_ITEM_INFO_RECEIVED` bursts during first panel open are near-free.
4. **`MacroManager.SetMacro`** — early-returns "unchanged" when body matches; M-5 dedupe also clears redundant queued pending writes.
5. **Pipeline `pcall` guard** — 10 per recompute. Negligible.

Recompute is frame-coalesced to ≤1 per frame. End-to-end target is ~3 ms per recompute under normal conditions, dropping below 1 ms when the score cache is warm.
