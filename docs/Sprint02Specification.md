# Crystalbound - Sprint 02 Specification

**Sprint:** 02 - Player Foundation
**Phase:** Design & Specification
**Status:** Specification. Not approved for implementation.
**Authored:** 29 July 2026
**Revised:** 29 July 2026 - Currency section genericised (A.1.1); review decisions recorded in Appendix A.
**Revised:** 29 July 2026 - 6.3/6.4 updated for provider-owned key construction; 4.3 module table completed; 6.5 aligned to the DataStore-only decision; 8.9 failure messages added.

---

# 1. Sprint Objective

Implement the Player Foundation: a persistent, versioned, validated player data layer that every future gameplay system depends on.

Sprint 02 delivers two things:

- **PlayerDataService** - loads, stores, validates, provides and saves player data.
- **StorageProvider** - the only module in the project permitted to contact Roblox persistence.

The objective is a data layer that is correct, safe under failure, and expandable without breaking existing saves. No gameplay system is built in this sprint.

The guiding constraint, restated from `CrystalEngineSpecification.md`:

> The engine provides tools. Gameplay systems use those tools.

PlayerDataService is the same idea one layer up. It owns data, not decisions.

---

# 2. Scope

In scope for Sprint 02:

- `PlayerDataService`, registered as a Service on the CrystalEngine Service tier.
- `StorageProvider`, a data-agnostic persistence abstraction backed by `DataStoreService`.
- The default player profile schema, covering all twelve required sections.
- Profile validation and default backfilling.
- Save version tracking and the migration framework.
- Session lifecycle: player join, autosave, player leave, server shutdown.
- Failure handling for every read and write path.
- Runtime verification in Roblox Studio, including the engine paths Sprint 01 left unexercised.

---

# 3. Out of Scope

Explicitly **not** part of Sprint 02:

**All gameplay systems.** No `InventoryService`, `MiningService`, `CraftingService`, `CrystalService`, `MissionService`, `EquipmentService` or any Manager. The profile schema reserves space for their data; none of their logic is written.

**Remotes and client access.** No RemoteEvents, no RemoteFunctions, no client-side data replication. Profiles remain server-only for this sprint.

**ClientEngine and Controllers.** Still future work per `CrystalEngineSpecification.md`.

**Actual migrations.** The migration *framework* is built and tested; no migration functions exist, because `CURRENT_VERSION` is 1 and there is no earlier version to migrate from.

**Cross-server session locking.** See the risk note in section 8.6 and Appendix A. This is a real data-integrity gap and is recommended for Sprint 03.

**Trading, leaderboards, cross-server data, and analytics pipelines.**

**Equipment stat calculation, luck calculation, drop tables, recipes.** These are Config-driven runtime calculations owned by future gameplay services. They are named here only to establish that they are *not* saved.

---

# 4. Architecture

## 4.1 Option B - Layered Persistence

```
              Player
                |
                v
       PlayerDataService          owns profile lifecycle, validation, session cache
                |
                v
        StorageProvider           owns all persistence I/O, retries, error handling
                |
                v
      Roblox DataStoreService     the only place this is ever touched
```

**Hard rule:** `PlayerDataService` must never reference `DataStoreService`, `GlobalDataStore`, `DataStore`, or any Roblox persistence API. Not in a require, not in a call, not in a fallback path. Section 13.10 defines a mechanical check for this.

## 4.2 Why the abstraction exists

Three concrete reasons, in order of importance:

1. **Testability.** `PlayerDataService` can be exercised against an in-memory provider with no DataStore budget, no network latency, and deliberately injectable failures. Testing failure paths against the live DataStore API is impractical; against a provider interface it is trivial.
2. **Substitutability.** If Roblox persistence changes, or the project later adopts a third-party library such as ProfileStore, the change is confined to one module. Nothing above the boundary moves.
3. **Separation of failure domains.** Transient DataStore failures - throttling, budget exhaustion, timeouts - are persistence concerns. `StorageProvider` absorbs and classifies them so `PlayerDataService` reasons about *outcomes*, not *retry mechanics*.

## 4.3 Module placement

| Module | Location | Loaded by |
|---|---|---|
| `PlayerDataService` | `src/ServerScriptService/Services/PlayerDataService/init.lua` | CrystalEngine `ServiceLoader` |
| `StorageProvider` | `src/ServerScriptService/Services/PlayerDataService/StorageProvider.lua` | Required directly by `PlayerDataService` |
| `Migrations` | `src/ServerScriptService/Services/PlayerDataService/Migrations.lua` | Required directly by `PlayerDataService` |
| `ProfileValidator` | `src/ServerScriptService/Services/PlayerDataService/ProfileValidator.lua` | Required directly by `PlayerDataService` |
| `DefaultProfile` | `src/ReplicatedStorage/Config/DefaultProfile.lua` | Required by `ProfileValidator` |
| `PersistenceConfig` | `src/ReplicatedStorage/Config/PersistenceConfig.lua` | Required by `PlayerDataService` and `StorageProvider` |
| `ProfileTypes` | `src/ReplicatedStorage/Shared/Types/ProfileTypes.lua` | Type-only; required by `PlayerDataService` and `ProfileValidator` |

`PlayerDataService` becomes a directory with `init.lua`. Rojo maps that to a single ModuleScript named `PlayerDataService` with `StorageProvider` and `Migrations` as children.

**This is compatible with the existing loader.** `SystemLoader.LoadFolder` calls `folder:GetChildren()` on `Services/` and inspects only direct children. `StorageProvider` and `Migrations` are grandchildren, so they are never discovered, never validated against the `Service` suffix rule, and never given a lifecycle. They are plain modules, and correctly so - neither carries `Name` or `Version` metadata.

**Why nested rather than a shared folder.** `Architecture.md` defines no home for server-only infrastructure modules. `Core` is engine foundation only. `Services/` requires the `Service` suffix. `ReplicatedStorage/Modules` is client-visible, which server-only persistence code must never be. Nesting keeps the data layer cohesive without inventing a folder. If `StorageProvider` later needs to serve consumers beyond player data, promoting it is a deliberate future decision - see Appendix A.

`DefaultProfile` lives in Config because it contains starting balance values - starting currency, starting inventory capacity, starting equipment - and `ClaudeInstructions.md` requires that balancing values live in Config rather than inside scripts.

## 4.4 Engine integration

```lua
Service.Name = "PlayerDataService"
Service.Version = 1
Service.Dependencies = {}
```

No dependencies. `PlayerDataService` is the foundation every other Service will depend on, and it depends on nothing itself. This makes it the root of the Service tier's dependency graph.

---

# 5. Responsibilities of PlayerDataService

## 5.1 Owns

**Load.** Request a player's stored data through `StorageProvider`, or construct a fresh default profile when none exists.

**Store.** Hold exactly one authoritative in-memory profile per active session. This cache is the single source of truth for a player's data while they are in the server.

**Validate.** Confirm a loaded profile is structurally sound. Backfill missing sections and fields from `DefaultProfile`. Reject data that is corrupt rather than silently repairing it into something wrong.

**Provide.** Give gameplay systems access to the profile, and a reliable way to know when it is ready.

**Save.** Persist profiles on autosave, on player leave, and on server shutdown, through `StorageProvider`.

**Version.** Read, write and enforce the profile `Version` field, and run migrations when a profile is behind.

## 5.2 Does not own

`PlayerDataService` contains **no gameplay logic**. It must not:

- Decide what an item does, what it is worth, or whether it stacks.
- Add, remove, or move inventory items as a gameplay action.
- Calculate mining yield, drop chance, luck, or any RNG outcome.
- Calculate equipment stats or apply equipment bonuses.
- Evaluate mission objectives or grant mission rewards.
- Validate crafting recipes or perform crafting.
- Compute completion percentages of any kind.
- Award currency, experience, or unlocks as a gameplay consequence.

It moves and guards data. Meaning belongs to the systems above it.

The distinction in practice: `PlayerDataService` may reject `Progression.Experience = "banana"` because it is not a number. It must not reject `Progression.Experience = 999999999` because that seems too high - that is a gameplay judgement, and it belongs to whichever system grants experience.

## 5.3 Public API

Lifecycle methods use PascalCase because `CrystalEngineSpecification.md` defines the engine contract that way. All other public methods use camelCase per `CodingStandards.md`. This split is deliberate and should be applied to every future Service.

```lua
-- Engine lifecycle
function PlayerDataService:Initialize()
function PlayerDataService:Start()

-- Access
function PlayerDataService:getProfile(player: Player): Profile?
function PlayerDataService:isLoaded(player: Player): boolean
function PlayerDataService:waitForProfile(player: Player, timeout: number?): Profile?

-- Readiness notification
function PlayerDataService:onProfileLoaded(callback: (Player, Profile) -> ()): () -> ()
function PlayerDataService:onProfileReleasing(callback: (Player, Profile) -> ()): () -> ()

-- Persistence
function PlayerDataService:save(player: Player): boolean
function PlayerDataService:saveAll(): ()
```

**`getProfile` returns `nil` when the profile is not loaded.** It never yields and never errors. A player can be in the server with data still in flight, and every caller must handle that.

**`waitForProfile` yields** until the profile is ready, the timeout elapses, or the player leaves. This is the method gameplay systems should normally use.

**`onProfileLoaded` returns a disconnect function.** Registering after a player has already loaded fires the callback immediately for that player, so a late-starting Service cannot miss the event. This matters because `Start` is dispatched through `task.spawn` and Service start order is not guaranteed to complete in sequence.

**`onProfileReleasing`** fires before the final save, giving gameplay systems a last chance to write session state into the profile.

Section 7.3 defines which system may write which section.

---

# 6. Responsibilities of StorageProvider

## 6.1 Owns

**All contact with `DataStoreService`.** Every read and every write in the entire project passes through this module.

**Retry and backoff.** Transient failures are retried with exponential backoff and a bounded attempt count. The caller never implements retry logic.

**Error classification.** Every failure is reported as one of:

| Result | Meaning | Caller's correct response |
|---|---|---|
| `Ok` | Data returned, or write committed | Proceed |
| `NotFound` | Key has never been written | Create a default profile |
| `Transient` | Throttled, budget exhausted, timed out | Retries already exhausted. Do not overwrite. Fail safe. |
| `Corrupt` | Data returned but not a usable table | Do not overwrite. Fail safe. |

The `Transient` / `NotFound` distinction is the single most important thing this module provides. Treating a throttled read as "no data" and writing a default profile over a real one is the classic total-progress-loss bug, and the type system should make that mistake hard to write.

**Budget awareness.** Respect `DataStoreService:GetRequestBudgetForRequestType` and avoid issuing requests that will certainly throttle.

**Write concurrency.** Writes use `UpdateAsync`, not `SetAsync`. `UpdateAsync` serialises concurrent writes to the same key and prevents a stale write from clobbering a newer one.

## 6.2 Does not own

**Any knowledge of profile shape.** `StorageProvider` moves opaque tables. It does not know what a profile is, does not know the field `Version` exists, does not validate, does not migrate, and does not apply defaults.

This is what makes it substitutable. A provider that understands profiles is not an abstraction - it is a second data layer.

It also must not: decide when to save, own the session cache, know about `Player` objects, or contain gameplay logic of any kind.

## 6.3 Public API

Every method takes a `UserId`. **No caller ever constructs or sees a storage key.**

```lua
export type ReadResult = "Ok" | "NotFound" | "Transient" | "Corrupt"

function StorageProvider.read(userId: number): (ReadResult, table?, string?)
function StorageProvider.write(userId: number, data: table): (boolean, string?)
function StorageProvider.update(userId: number, transform: (table?) -> table?): (boolean, string?)
```

`read` returns a result code, the data when successful, and a diagnostic message when not.

`write` is implemented over `UpdateAsync` internally despite its name, and returns success plus a diagnostic message.

`update` exposes read-modify-write for cases needing true atomicity.

`PlayerDataService` passes a `UserId` and nothing else. It never builds a key, never receives one, and never learns the format. This keeps every persistence detail - key layout, store name, prefix - behind the boundary, which is what makes the provider substitutable in practice rather than only in principle.

## 6.4 Key construction

Key construction is **private to `StorageProvider`**. The current format is:

```
<KeyPrefix><UserId>
```

`DataStoreName` and `KeyPrefix` come from `PersistenceConfig` and are read **only** by `StorageProvider`. No key string crosses the module boundary in either direction, so the format can change without touching any consumer.

## 6.5 Studio testing

Studio DataStore access requires *Enable Studio Access to API Services*.

`StorageProvider` is **DataStore-backed only** for Sprint 02. No switchable backend, no in-memory provider, no Config backend flag. Automated testing and mock storage providers are deferred to a future sprint dedicated to testing infrastructure.

The consequence is accepted rather than worked around: verification checks that require a forced DataStore failure - 13.5 and 13.6 - are recorded as **Not Exercised** per 13.11. See A.2.2.

---

# 7. Communication Flow

## 7.1 Load

```
Player joins
    |
    v
PlayerDataService          builds key, requests read
    |
    v
StorageProvider            DataStore read, retry, classify
    |
    v
Roblox DataStoreService
    |
    v
StorageProvider            returns (ReadResult, data)
    |
    v
PlayerDataService          validate -> migrate -> backfill -> cache
    |
    v
onProfileLoaded fires      gameplay systems may now read
```

## 7.2 Gameplay access (future sprints)

```
Client
    |
    v
Remote                     one-way event or request/response
    |
    v
Gameplay Service           validates the request, applies gameplay rules
    |
    v
PlayerDataService          getProfile -> returns the cached profile table
    |
    v
Gameplay Service           mutates only its own section
    |
    v
PlayerDataService          persists on autosave, leave, or shutdown
```

This matches the canonical flow in `Architecture.md`. The server remains authoritative; the client only requests actions.

## 7.3 Section ownership

`PlayerDataService` hands out the profile table and does not police individual field writes - doing so would require gameplay knowledge it is forbidden to have. Ownership is therefore a **convention enforced by review**, and it is documented here so future sprints have no ambiguity.

| Section | Written by | Sprint |
|---|---|---|
| `Version` | PlayerDataService only | 02 |
| `Profile` | PlayerDataService only | 02 |
| `Currency` | EconomyService / reward-granting services | 03+ |
| `Progression` | ProgressionService | 03+ |
| `Inventory` | InventoryService | 03+ |
| `Equipment` | EquipmentService | 03+ |
| `WorldExploration` | WorldManager / ExplorationService | 04+ |
| `Missions` | MissionService | 04+ |
| `Collection` | CollectionService | 04+ |
| `Unlocks` | ProgressionService / MissionService | 03+ |
| `Statistics` | The service that owns the counted event | 03+ |
| `Settings` | SettingsService, on validated client request | 03+ |

`Version` and `Profile` are the only sections `PlayerDataService` writes. Everything else it merely carries.

---

# 8. Runtime Lifecycle

## 8.1 Engine Initialize

- Require `StorageProvider`, `Migrations`, `DefaultProfile`.
- Select the storage backend from Config.
- Create empty session caches and callback registries.
- **Touch no players and open no connections.**

Per `CrystalEngineSpecification.md`, gameplay must not begin during Initialize.

## 8.2 Engine Start

- Connect `Players.PlayerAdded` and `Players.PlayerRemoving`.
- **Process players already present.** Between Initialize and Start, a player may already have joined - in Studio this is routine. Iterate `Players:GetPlayers()` after connecting, or the first player of every Studio test session loads no data. This is a common and easily missed bug.
- Start the autosave loop.
- Register `game:BindToClose`.

## 8.3 Player join

1. Build the key from `UserId`.
2. Call `StorageProvider.read`.
3. Branch on the result:
   - `Ok` - proceed to validation.
   - `NotFound` - create a fresh profile from `DefaultProfile` at `CURRENT_VERSION`.
   - `Transient` - **do not create a default profile.** Kick the player with a retry message.
   - `Corrupt` - **do not overwrite.** Kick, and log the raw payload for investigation.
4. If `Version < CURRENT_VERSION`, run migrations (section 11).
5. If `Version > CURRENT_VERSION`, refuse. The player has been placed on an older server than the one that wrote their save; loading it would discard fields this build does not know about. Kick with an explanatory message.
6. Validate and backfill against `DefaultProfile`.
7. Update `Profile.LastLoginAt` and increment `Statistics.SessionCount`.
8. Cache the profile and fire `onProfileLoaded`.

**The rule underneath steps 3 and 5:** a failure to *read* must never become a decision to *write*. Every ambiguous outcome fails closed.

## 8.4 Session

Gameplay systems read and mutate the cached profile. `PlayerDataService` does not observe or interpret those mutations.

## 8.5 Autosave

- Interval from Config, default 120 seconds.
- Players are staggered rather than saved simultaneously, to spread DataStore budget.
- A failed autosave is logged and retried on the next cycle. It is not fatal - the session continues with the in-memory profile intact.

## 8.6 Player leave

1. Fire `onProfileReleasing`.
2. Perform a final save, with more retry attempts than autosave uses - this is the last chance.
3. Release the cache entry.
4. If the final save fails after all retries, log at Error with the `UserId` and the failure reason. Progress since the last successful save is lost; this must be loud, never silent.

**Risk, out of scope this sprint:** with no cross-server session lock, a player who leaves and rejoins a *different* server quickly can have the new server load a profile the old server has not finished saving, and the newer session then overwrites it. Single-server behaviour is correct; multi-server behaviour is not fully safe. Recorded in Appendix A.

## 8.7 Server shutdown

- `game:BindToClose` saves every cached profile.
- Roblox allows roughly 30 seconds. Saves run concurrently with a bounded worker count so a full server does not exceed the window.
- Studio shutdown must be verified explicitly - `BindToClose` behaves differently there.

## 8.8 Edge cases that must be handled

| Case | Required behaviour |
|---|---|
| Player leaves mid-load | Abandon the load. Do not cache, do not save, do not fire callbacks. |
| `getProfile` called before load completes | Return `nil`. Never yield, never error. |
| Same player rejoins the same server before release completes | Await release, then load fresh. Never hand out a released profile. |
| Autosave fires while a final save is in progress | Serialise per player. One write per profile at a time. |
| Read succeeds but payload is not a table | `Corrupt`. Kick. Do not overwrite. |
| Migration raises an error | Do not save. Kick. Log the version pair and the error. |
| Server shuts down during a player's load | Load is abandoned; nothing was cached, so nothing is saved. |

## 8.9 Player-facing failure messages

Every kick path uses a message from `PersistenceConfig.Messages`. They are Config data, not inline strings, so wording can change without touching logic and a localisation layer has a seam to hook into later.

| Key | Trigger | Message |
|---|---|---|
| `TransientLoadFailure` | `read` returned `Transient` | "Unable to load your data. Please try joining again in a moment." |
| `CorruptSave` | `read` returned `Corrupt`, or validation rejected the profile | "Your save data could not be loaded safely. Please contact support if this continues." |
| `FutureSaveVersion` | `Version` above `CURRENT_VERSION` | "Your save was created with a newer version of Crystalbound. Please update the game and try again." |

A migration failure reuses `CorruptSave`, since from the player's perspective the outcome is identical and the technical distinction belongs in the log, not in the kick dialog.

---

# 9. Default Player Profile

## 9.1 Conventions

**Keys are PascalCase**, consistent with the engine's `Name` / `Version` / `Dependencies` fields and with the section names in this specification.

**IDs are strings referencing Config.** A save stores `"pickaxe_iron"`. It never stores that pickaxe's name, rarity, mining power, or icon. Those live in Config and are looked up at runtime.

**Sets are `[id] = true` maps.** Order-independent, cheap to test, and cheap to merge.

**Absent keys mean absent data.** Roblox serialisation drops `nil` values, so a missing key is normal and must never be treated as corruption. Validation backfills; it does not reject.

## 9.2 The schema

```lua
--!strict
-- src/ReplicatedStorage/Config/DefaultProfile.lua
--
-- Starting values for a new player. Data only - no logic.
-- Every field here is either OWNED state or PROGRESSION state.
-- Nothing here is a calculated gameplay value.

return {
    -- Save schema version. Owned exclusively by PlayerDataService.
    -- Bumped only for structural or semantic changes - see section 10.
    Version = 1,

    -- Identity and session lifecycle. Written only by PlayerDataService.
    Profile = {
        UserId = 0,
        CreatedAt = 0,       -- unix seconds, set once on first join
        LastLoginAt = 0,
        LastSavedAt = 0,
    },

    -- Spendable balances only.
    -- Materials and crystals are Inventory items, not currency.
    --
    -- Intentionally empty. The game economy is not finalised and no
    -- currency names are assumed here. Adding a currency later is a
    -- purely ADDITIVE change (section 10.2): a new key with a default of
    -- 0 is backfilled into every existing save on its next load, with no
    -- version bump and no migration. Deferring the economy costs nothing.
    --
    -- When names are decided, add them here as `<Name> = 0`.
    Currency = {},

    -- Progression the player has earned.
    -- Upgrades store OWNED LEVELS. The resulting multipliers are
    -- calculated at runtime from Config and never saved.
    Progression = {
        Level = 1,
        Experience = 0,
        Upgrades = {
            Luck = 0,        -- level, not a luck multiplier
            MiningSpeed = 0, -- level, not a speed value
        },
    },

    -- Capacity and Items only, per the sprint's design decisions.
    -- Capacity is the player's OWNED slot count. Effective capacity
    -- (base + equipment bonuses) is calculated at runtime, never saved.
    Inventory = {
        Capacity = 50,
        Items = {},          -- [itemId] = count
    },

    -- Equipped item IDs only. Stats are NEVER saved - they are read
    -- from Config by ID and recalculated after every load.
    -- An absent slot means nothing is equipped.
    Equipment = {
        Pickaxe = "pickaxe_starter",
        Bracelet = nil,
        Hood = nil,
        Hat = nil,
        Mantle = nil,
    },

    -- What the player has DISCOVERED. Never completion percentages -
    -- those are calculated against Config's full catalogue at runtime.
    -- World ACCESS lives in Unlocks.Worlds; this is exploration progress.
    WorldExploration = {
        CurrentWorld = "world_starter",
        DiscoveredAreas = {},     -- [areaId] = true
        DiscoveredLandmarks = {}, -- [landmarkId] = true
    },

    -- Mission PROGRESS only. Objectives, targets and rewards live in Config.
    Missions = {
        Active = {},         -- [missionId] = { Progress = { [objectiveId] = number }, StartedAt = number }
        Completed = {},      -- [missionId] = completionCount, supports repeatables
        LastDailyReset = 0,
    },

    -- Permanent record of everything ever found, independent of Inventory.
    -- Inventory is what you HOLD; Collection is what you have EVER SEEN.
    -- Collection completion percentage is calculated, never stored.
    Collection = {
        Crystals = {},       -- [crystalId] = { FirstFoundAt = number, TimesFound = number }
        Materials = {},      -- [materialId] = { FirstFoundAt = number, TimesFound = number }
        Equipment = {},      -- [equipmentId] = { FirstObtainedAt = number }
    },

    -- Access and entitlement flags.
    -- Recipes stores WHICH recipes are known. Recipe contents are Config.
    Unlocks = {
        Worlds = { world_starter = true },
        Features = {},       -- [featureId] = true
        Recipes = {},        -- [recipeId] = true
        Achievements = {},   -- [achievementId] = true
    },

    -- Lifetime counters that CANNOT be reconstructed from other sections.
    -- Deliberately excluded: MissionsCompleted (derive from Missions.Completed),
    -- CrystalsDiscovered (derive from Collection.Crystals). Storing a value
    -- that is derivable creates two sources of truth that will drift.
    Statistics = {
        TotalPlayTime = 0,   -- seconds
        SessionCount = 0,
        OresMined = 0,
        ItemsCrafted = 0,
        LuckiestRoll = 0,
    },

    -- Player preferences. The only section a client may request changes to,
    -- and therefore the only section needing input clamping on write.
    Settings = {
        MusicVolume = 1,
        SfxVolume = 1,
        ScreenShake = true,
        RarityNotifications = true,
    },
}
```

## 9.3 What is deliberately absent

Each of these was considered and excluded, because saving it would violate a stated design decision:

| Not saved | Reason | Where it comes from instead |
|---|---|---|
| Equipment stats | Stats are Config data keyed by ID | Config lookup on load |
| Total luck value | Calculated from upgrade levels, equipment and achievements | Recalculated at runtime |
| Active buffs | Not persisted unless persistence is explicitly required | Recalculated after load |
| Mining power / speed | Derived from equipped items and upgrade levels | Recalculated at runtime |
| Exploration percentage | Calculated from discovered areas against Config | Calculated on demand |
| Collection percentage | Calculated from Collection against Config | Calculated on demand |
| Recipe contents | Balance data | Config |
| Drop tables and rarity weights | Balance data | Config |
| Item display names, icons, descriptions | Presentation data | Config |
| `MissionsCompleted` count | Derivable from `Missions.Completed` | Counted on demand |

**Equipment bonuses are recalculated after every load.** Nothing in the save reflects an equipment bonus. This means rebalancing a pickaxe in Config applies to every existing player immediately, with no migration - which is precisely why stats are not saved.

---

# 10. Save Versioning Strategy

## 10.1 The version field

`Version` is an integer at the profile root. `CURRENT_VERSION` is a constant in `PlayerDataService`. Sprint 02 ships `CURRENT_VERSION = 1`.

Only `PlayerDataService` reads or writes `Version`. No gameplay system may touch it.

## 10.2 Expansion without a version bump

Most schema growth is additive and needs **no** version bump.

On every load, `PlayerDataService` deep-merges `DefaultProfile` into the loaded profile: any key present in the default and missing from the save is filled with the default value. Existing values are never overwritten.

This is what makes saves expandable. Adding `Statistics.CrystalsSold = 0` to `DefaultProfile` requires no migration and no version change - existing saves gain the field with its default on their next load.

**Additive changes are safe when:** a new key is added with a sensible default, and no existing key changes meaning, type, location, or units.

## 10.3 When a version bump IS required

Bump `CURRENT_VERSION` and write a migration when:

- A field is **renamed** or **moved** to a different section.
- A field's **type** changes - for example `Items` moving from an array to a map.
- A field's **meaning or units** change - `TotalPlayTime` in minutes becoming seconds.
- A field is **removed** and its data must be preserved elsewhere.
- A field becomes **derived**, and the stored copy must be deleted to avoid two sources of truth.

The test to apply: *would a save written by the previous build be silently misinterpreted by this build?* If yes, it needs a version.

## 10.4 Downgrade protection

A profile with `Version > CURRENT_VERSION` is **refused**, not loaded.

This happens when a player is routed to a server running an older build after a partial rollout or a rollback. That save may contain fields this build does not understand. Loading it, then saving, would silently drop them.

Refusing and kicking with a clear message costs one player one session. Loading it costs that player permanent, invisible data loss.

## 10.5 Rules

- `Version` only ever increases.
- Version numbers are integers, incremented by one. No semantic versioning, no gaps.
- A version bump is never combined with unrelated schema work in the same change.
- Every bump is recorded in the migration registry with a comment stating what changed and why.

---

# 11. Future Save Migration Strategy

## 11.1 Stepwise migration

Migrations are an ordered registry of single-step functions:

```lua
-- src/ServerScriptService/Services/PlayerDataService/Migrations.lua

return {
    -- [fromVersion] = function(profile) -> profile
    -- Each step migrates exactly one version forward. Never skip.
}
```

A profile at version 1 loading into a build at version 4 runs `1->2`, then `2->3`, then `3->4`, in that order. There is never a `1->4` shortcut. Stepwise migration means each function only needs to understand two adjacent schema versions, and a new migration never requires revisiting an old one.

## 11.2 Where migration runs

```
StorageProvider.read -> Ok
        |
        v
Version check      too new? refuse (10.4)
        |
        v
Migration chain    stepwise, in order
        |
        v
Validation         type checks
        |
        v
Default backfill   additive fields
        |
        v
Cache
```

Migration runs **before** validation, so a migration may rely on the old shape being present. Backfill runs **after**, so a migration never has to add fields that the default merge would supply anyway.

## 11.3 Failure handling

If any migration step raises an error:

1. Abandon the load.
2. **Do not save.** The in-memory profile is now in an unknown intermediate state, and writing it would make the corruption permanent.
3. Log at Error with the `UserId`, the from/to version pair, and the error.
4. Kick the player with a support-facing message.

A failed migration is a bug in the migration, not in the player's data. The data is still intact on the DataStore, and it must be left that way until the bug is fixed.

## 11.4 Requirements on migration functions

- **Pure.** Input profile, output profile. No DataStore access, no `Player` access, no side effects.
- **Total.** Must handle a partial or unusual profile at the source version, including missing optional sections.
- **Never destructive without transfer.** Data being removed is moved first, then deleted in the same step.
- **Permanent.** A shipped migration is never edited or deleted. Old saves can arrive at any time - a player returning after a year enters at whatever version they left.

## 11.5 Worked example

The most likely first migration, drawn from a real ambiguity in this schema.

`Inventory.Capacity` currently stores an owned slot count. If inventory capacity later becomes a levelled upgrade, its level belongs in `Progression.Upgrades`, and `Capacity` becomes derived - at which point the stored copy must go, or the two will drift.

```lua
-- 1 -> 2: inventory capacity becomes a levelled upgrade.
-- Capacity is now derived from Config; the stored value is removed
-- after its level is recovered so no second source of truth remains.
[1] = function(profile)
    local capacity = profile.Inventory.Capacity or 50
    local baseCapacity = 50
    local slotsPerLevel = 10

    profile.Progression.Upgrades.InventoryCapacity =
        math.max(0, math.floor((capacity - baseCapacity) / slotsPerLevel))

    profile.Inventory.Capacity = nil
    profile.Version = 2
    return profile
end,
```

This illustrates all four requirements: it is pure, it tolerates a missing `Capacity`, it transfers before deleting, and once shipped it is frozen.

---

# 12. Definition of Done

Sprint 02 is complete when every item below is true and verified.

## Architecture

- [ ] `PlayerDataService` contains zero references to any Roblox persistence API.
- [ ] `StorageProvider` contains zero references to profile structure.
- [ ] `PlayerDataService` contains no gameplay logic per the section 5.2 prohibitions.
- [ ] `DefaultProfile` lives in Config and contains data only.

## Engine integration

- [ ] `PlayerDataService` is discovered and validated by `ServiceLoader`.
- [ ] It declares `Name`, `Version` and `Dependencies`.
- [ ] It appears in the startup summary as `Services : 1`.
- [ ] `Initialize` opens no connections; `Start` opens all of them.

## Data correctness

- [ ] A first-time player receives a complete default profile at `CURRENT_VERSION`.
- [ ] All twelve sections are present and correctly typed after load.
- [ ] Data persists across rejoin.
- [ ] A save missing sections is backfilled without losing existing values.
- [ ] A save with `Version` above `CURRENT_VERSION` is refused.
- [ ] The migration framework exists, is unit-exercised with a synthetic v0 profile, and is documented as empty at v1.

## Failure safety

- [ ] A transient read failure never writes a default profile.
- [ ] A corrupt payload never overwrites stored data.
- [ ] A migration failure never saves.
- [ ] A failed final save logs at Error with the `UserId`.
- [ ] `getProfile` returns `nil` rather than yielding or erroring when data is not ready.

## Lifecycle

- [ ] Players present before `Start` are loaded.
- [ ] Autosave fires on its configured interval and staggers players.
- [ ] Player leave triggers a final save and releases the cache.
- [ ] `BindToClose` saves all cached profiles.
- [ ] Concurrent saves for one player are serialised.

## Verification

- [ ] Every check in section 13 has been executed in Studio with its result recorded.
- [ ] `docs/Sprint02Summary.md` is written, including any verification gaps.

---

# 13. Runtime Verification Plan

Sprint 01 shipped with six engine paths that ran only against an empty registry. This plan is written to close that gap and to avoid repeating it: every check below must actually execute, and any check that cannot be run is recorded as a gap rather than assumed to pass.

`PlayerDataService` is the project's first real Service, so these tests also constitute the first genuine exercise of the CrystalEngine loader, dependency resolver, and lifecycle.

## 13.1 Engine integration

Boot the server. Confirm the startup summary reports `Services : 1`, the engine reaches `Running`, and `PlayerDataService` logs through its scoped logger. **This is the first runtime proof that `Initialize` and `Start` are invoked on a real system** - a Sprint 01 gap.

## 13.2 First-time load

Join with a clean key. Confirm a default profile is created, `Version` is `CURRENT_VERSION`, all twelve sections are present, `Profile.CreatedAt` is set, and `Statistics.SessionCount` is 1.

## 13.3 Persistence round trip

Mutate a value, leave, rejoin. Confirm the value persisted and `SessionCount` is 2.

## 13.4 Additive backfill

Write a save with `Statistics` and `Settings` removed entirely. Load it. Confirm both sections are restored to defaults, every other section is untouched, and no version bump occurred.

## 13.5 Transient failure safety

Force `StorageProvider.read` to return `Transient`. Confirm the player is kicked, **no write occurs**, and the stored profile is byte-identical afterwards.

This is the most important test in the sprint. It is the difference between a bug and a catastrophe.

## 13.6 Corrupt payload safety

Store a string where a table is expected. Confirm `read` classifies it `Corrupt`, the player is kicked, and no overwrite occurs.

## 13.7 Downgrade refusal

Store a profile with `Version = 99`. Confirm the load is refused, the player is kicked, and no write occurs.

## 13.8 Migration framework

Register a synthetic `0 -> 1` migration in a test build. Load a `Version = 0` profile. Confirm the step runs, the result validates, and the profile saves at version 1. Then confirm a deliberately failing migration causes no save.

## 13.9 Lifecycle

- Autosave fires on interval; confirm via log and by reading the store.
- Leave triggers a final save.
- Studio shutdown triggers `BindToClose` and all profiles save.
- A player present before `Start` is loaded - verifiable in Studio, where the local player joins immediately.
- Leaving mid-load caches nothing and saves nothing.

## 13.10 Architectural constraint check

A mechanical grep, not a judgement call:

```bash
grep -rn "DataStoreService\|GetDataStore\|UpdateAsync\|SetAsync\|GetAsync" src/ServerScriptService/Services/PlayerDataService/
```

Every hit must be inside `StorageProvider.lua`. A hit in `init.lua` is a Definition of Done failure.

## 13.11 Recording results

Every check gets a recorded outcome: pass, fail, or **not exercised**. Sprint 01's summary was strengthened by naming its unexercised paths honestly; the same standard applies here. A check that could not be run is not a check that passed.

---

# Appendix A - Decisions

## A.1 Resolved

Settled during specification review on 29 July 2026.

**A.1.1 Currency names - deferred.** No currency names are assumed. The `Currency` section ships as an empty table until the game economy is finalised. This is safe precisely because currencies are additive fields: adding one later requires no version bump and no migration (section 10.2). Nothing in Sprint 02's Definition of Done depends on any specific currency existing.

**A.1.2 `StorageProvider` location - nested.** Stays a child module of `PlayerDataService` at `Services/PlayerDataService/StorageProvider.lua`. If it later needs to serve consumers beyond player data, promoting it becomes a deliberate future decision requiring an amendment to `Architecture.md`.

**A.1.3 World unlocks stay separate from world exploration.** `Unlocks.Worlds` holds access; `WorldExploration` holds discovery. Confirmed as specified in 9.2.

**A.1.4 Derivable data is never stored.** Confirmed as specified in 9.3. `Statistics` holds only counters that cannot be reconstructed from other sections.

**A.1.5 The read result contract stands.** `NotFound`, `Transient` and `Corrupt` remain distinct results. Confirmed as specified in 6.1.

**A.1.6 Downgrade protection stands.** A profile with `Version` above `CURRENT_VERSION` is refused, not loaded. Confirmed as specified in 10.4.

**A.1.7 Session locking and Studio memory backends - future sprints.** Both deferred. The risk in 8.6 stands and is unmitigated in Sprint 02; see A.2.1.

## A.2 Still open

**A.2.1 Cross-server session locking.** Deferred by decision, and still a genuine data-integrity gap for fast server-hopping - a player leaving one server and rejoining another quickly can have the newer session overwrite an unfinished save. Recommended for Sprint 03, either as a lock inside `StorageProvider` or by adopting ProfileStore behind the same interface. The abstraction exists precisely so this stays a contained change.

**A.2.2 In-memory Studio backend.** Deferred by decision. Note the consequence for this sprint: section 13.5, 13.6 and 13.8 require injectable read failures, which the live DataStore API cannot produce on demand. Without a switchable backend those checks must be exercised by another means - temporarily stubbing `StorageProvider.read` in a test build is the minimum - or recorded as **not exercised** per 13.11. This needs a plan before implementation begins.

**A.2.3 Readiness notification mechanism.** `onProfileLoaded` needs a callback registry, a `BindableEvent`, or a shared Signal utility. No Signal utility exists and `Packages/` is empty. A plain callback table needs no dependency and is the recommended starting point; a reusable Signal in `Shared/Utilities` is the alternative.

**A.2.4 `DevelopmentWorkflow.md` does not exist.** This specification was written for the "Design & Specification phase" as instructed, but that document is absent from the repository and from all git history. Its phase definitions and document conventions could not be followed. If it exists elsewhere, this specification should be re-checked against it.

---

# Appendix B - Design Decisions Applied

Traceability from the sprint's stated decisions to where this specification enforces them.

| Decision | Enforced in |
|---|---|
| Save ownership and progression, not calculated values | 9.2, 9.3 |
| Equipment stats never saved; only equipped IDs | 9.2 `Equipment`, 9.3 |
| Buffs not stored; equipment bonuses recalculated after load | 9.3 |
| World exploration stores discovered content, not percentages | 9.2 `WorldExploration` |
| Percentages always calculated dynamically | 9.3 |
| Inventory stores Capacity and Items only | 9.2 `Inventory` |
| Recipes, stats, drop tables belong in Config | 9.3, 4.3 |
| Saves expandable without breaking existing saves | 10.2, 13.4 |
| Versioning supports future migrations | 10, 11 |
| StorageProvider keeps PlayerDataService independent of Roblox persistence | 4.1, 4.2, 6.2, 13.10 |
| PlayerDataService contains no gameplay logic | 5.2, 7.3, 12 |
| Currency names not assumed until the economy is finalised | 9.2 `Currency`, A.1.1 |
