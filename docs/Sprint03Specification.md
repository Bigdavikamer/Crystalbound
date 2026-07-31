# Crystalbound - Sprint 03 Specification

**Sprint:** 03 - Item, Inventory, Equipment, Crafting, Loot, World Identity
**Phase:** Design & Specification
**Type:** **Specification sprint. No implementation.**
**Status:** Awaiting final approval
**Authored:** 29 July 2026
**Revised:** 29 July 2026 - specification-only scope; Remotes deferred; Definition/Instance and World Identity elevated to architectural pillars; approved decisions recorded
**Revised:** 29 July 2026 - `ItemInstance.Metadata` reserved as a governed, sparsely stored extension point (3.9, R-13)

---

# 0. Purpose And Standing

Sprint 03 produces **design and documentation only**. No Lua file is written, no system is implemented, and no migration is run during this sprint.

This document is intended to serve as the **long-term architectural foundation** for Inventory, Equipment, Crafting, Loot Generation, World Identity, Exploration, and the gameplay systems that follow. It should be readable as a standing reference, not as a one-sprint work order.

Implementation is phased and begins only after this specification is fully approved. The roadmap is section 18.

Two sections are **architectural pillars** - concepts that outlive any single system and that later designs are expected to conform to rather than reinterpret:

- **Section 3 - ItemDefinition versus ItemInstance**
- **Section 4 - World Identity and Origin**

---

# 1. The Save-Format Evolution

## 1.1 The approved schema cannot represent rolled or evolving items

`DefaultProfile.lua` currently stores:

```lua
Inventory = {
    Capacity = 50,
    Items = {},                    -- [itemId] = count
},
Equipment = {
    Pickaxe = "pickaxe_starter",   -- an ItemId
},
```

That format assumes **every item is fungible** - identified only by Config ID, distinguished only by quantity. Sprint 02 justified it with the rule *"Equipment stats are never saved; only equipped item IDs are saved,"* because stats were derivable from Config by ID.

Affixes, loot generation, and evolution all break that assumption:

- An affix roll is **random per copy**. It is not derivable from the ItemId. Unpersisted, an item's stats change on every load.
- Evolution is **per-copy state**. Two pickaxes of the same ItemId can sit at different stages.
- Two copies of one ItemId are no longer interchangeable, so `[itemId] = count` cannot address them.

Sprint 02's design was correct for a game without rolled properties. This is genuine schema evolution.

## 1.2 The rule is refined, not abandoned

The purpose of "never save stats" was that **rebalancing in Config must apply retroactively to every existing item.** That purpose survives under a sharper rule, approved:

> **Persist the roll. Never persist the resolved value.**

An instance stores `{ Id = "affix_swift", Roll = 0.734 }` - a normalised position within the affix's range. The value is computed at runtime:

```
value = Min + (Max - Min) * Roll        -- Min/Max from Config
```

Change `Min`/`Max` and **every existing item recomputes on next load**. The player's luck is preserved; the designer's control is preserved; nothing derivable is stored.

Every design in this document follows from that rule.

## 1.3 Consequence: a v1 → v2 migration

Equipment slots must change from holding ItemIds to holding InstanceIds. Specified in section 15. **Approved in principle; not executed during Sprint 03.**

---

# 2. Scope

## 2.1 In scope for Sprint 03

Design specification for eight systems: Item, Inventory, Equipment, Crafting, Loot Generation, World Affix Pools, Equipment Evolution, Secret Recipes - plus the two architectural pillars and the migration design.

## 2.2 Out of scope

**All implementation.** No Lua, no Config authoring, no migration execution.

**The Remotes layer** - deferred by decision (R-8). Networking *considerations* are documented in section 13 because they constrain API design, but no Remote is specified as a deliverable and no system may be designed to require one.

**Trading and player-to-player transfer.**

**Cosmetic slots.** The `Cosmetic` category is defined; no equipping.

**Mining node behaviour and `OreManager` internals.** This document defines the loot *interface* only.

**Currency and economy.** `Currency = {}` stays empty pending the economy decision.

**Client UI.**

---

# 3. ★ Architectural Pillar: ItemDefinition versus ItemInstance

This separation is a **core architectural pillar of Crystalbound**. Every item-bearing system conforms to it.

## 3.1 The rule

Every item exists as exactly one of two things, and never both:

| | **ItemDefinition** | **ItemInstance** |
|---|---|---|
| Represents | An item *kind* | One unique *copy* |
| Lives in | Config (`ReplicatedStorage/Config`) | The player's save |
| Authored by | Developers | Gameplay |
| Mutable at runtime | Never | Yes |
| Identical across players | Yes | No |
| Written to a save | **Never** | Always |
| Count | One per item kind | One per copy owned |

A third layer exists but is stored nowhere:

**Resolved view** - the runtime product of Definition + Instance + player context. Computed on demand, cached in memory, **never persisted and never transmitted.**

## 3.2 Why this is a pillar

Four properties follow directly, and all four are load-bearing:

**Retroactive balance.** Definitions are Config. Changing a stat, a name, an icon, or an affix range applies to every existing item on next load, with no migration and no save write.

**Save size.** A save holds IDs and rolls. Display names, icons, descriptions, stat tables, and drop weights never consume DataStore space. A 200-item inventory is a few kilobytes rather than hundreds.

**Extensibility.** Adding an item is a Config entry. No code change, no migration, no schema change. This is the single most important extensibility guarantee in the project.

**Datamine posture.** Definitions are client-readable *by design* - the client must render them. Instances are per-player and server-authoritative. Knowing what exists in the game grants nothing, because ownership lives on the other side of the boundary.

## 3.3 ItemDefinition

Immutable game data. One per item kind.

| Field | Type | Notes |
|---|---|---|
| `Id` | string | Permanent. Never renamed, never reused. |
| `Category` | enum | `Material`, `Crystal`, `Equipment`, `Consumable`, `Cosmetic` |
| `Slot` | enum? | Equipment only: `Pickaxe`, `Bracelet`, `Hood`, `Hat`, `Mantle` |
| `Rarity` | enum | `Common`, `Uncommon`, `Rare`, `Epic`, `Legendary` |
| `Tier` | number | Progression gate, roughly world depth |
| `Stackable` | boolean | Determines storage strategy (3.5) |
| `MaxStack` | number | Ceiling per stack slot |
| `BaseStats` | map? | Equipment only. Keys from `StatKeys` Config. |
| `AffixSlots` | `{Min,Max}?` | Range rolled at generation |
| `EvolutionLine` | string? | Reference into `EvolutionLines` Config |
| `NativeOrigin` | string? | The world this item kind belongs to (section 4.4) |
| `Tags` | array | Recipe matching, loot filters, UI grouping |
| `SalvageYield` | array | Items returned on salvage |
| `Value` | number | Base sell value |
| `Display` | table | `Name`, `Icon`, `Description` |

## 3.4 ItemInstance

One unique copy, owned by one player, stored in their save.

| Field | Type | Notes |
|---|---|---|
| `InstanceId` | string | The table key. Profile-local, never reused. **Approved: strings.** |
| `ItemId` | string | Reference to the Definition |
| `Affixes` | array | `{ Id, Roll }` pairs. **Approved: explicit list, not a seed.** |
| `Stage` | number | Evolution stage |
| `Experience` | number | Evolution progress |
| `Origin` | string? | World of generation. Permanent, optional (section 4). |
| `Locked` | boolean | Blocks destructive operations |
| `Favorite` | boolean | Organisational only |
| `CreatedAt` | number | Unix seconds |
| `Metadata` | table? | **Reserved. No behaviour in any current phase.** Sparse - omitted when empty. See 3.9. |

```lua
Instances = {
    ["7"] = {
        ItemId = "pick_ironclad",
        Affixes = {
            { Id = "affix_swift",       Roll = 0.734 },
            { Id = "affix_voidtouched", Roll = 0.112 },
        },
        Stage = 2,
        Experience = 340,
        Origin = "world_deep_hollow",
        Locked = true,
        Favorite = true,
        CreatedAt = 1753800000,
        -- Metadata is absent, which is the normal case. It exists in the
        -- schema only as a reserved extension point (3.9).
    },
}
```

**Instance IDs must be strings.** Roblox DataStore serialisation converts numeric table keys to strings on write, so a numeric key returns as a string and every subsequent lookup silently misses. Generating them as strings avoids a bug class that only appears after the first rejoin.

## 3.5 Locked versus Favorite

Two fields, deliberately not one:

**`Locked`** is protective and **server-enforced**. Salvage, sell, consume, and any destructive operation refuses a locked instance.

**`Favorite`** is organisational and **presentational only**. The server stores it so it persists across sessions but never acts on it.

They are separate because a player will favourite thirty good items while locking the three that are irreplaceable. Collapsing them forces one behaviour onto both intents.

## 3.6 Storage strategy follows Category

| Kind | Categories | Storage | Rationale |
|---|---|---|---|
| **Stackable** | Material, Crystal, Consumable | `Inventory.Items[itemId] = count` | Fungible. One `mat_azure_shard` is any other. |
| **Unique** | Equipment | `Inventory.Instances[instanceId] = {...}` | Carries rolls, evolution, lock state, provenance. |

An item is one or the other, never both. Cosmetics are undecided - **O-1**.

## 3.7 Invariants

These are the rules that keep the pillar intact.

**Never in an ItemDefinition:**
- Anything player-specific
- Any rolled or random value
- Any runtime state

**Never in an ItemInstance:**
- Display text, icons, descriptions
- Stat ranges, or any resolved stat value
- Rarity, category, or slot - all derivable from `ItemId`
- Anything else derivable from the Definition

**Never in any persisted form:**
- A resolved stat value

**Never in `Metadata` (3.9):**
- A resolved value - the derivability test in 3.8 applies to it unchanged
- Anything a typed field should hold; if it is core, promote it
- Anything the client is trusted for
- Unbounded or historical data

## 3.8 The derivability test

Before adding a field to `ItemInstance`, ask:

> **Can this be computed from `ItemId` plus Config?**

If **yes** → it belongs in the Definition. Storing it duplicates a source of truth, and the two will drift.

If **no**, because it is random or player-mutated → it belongs in the Instance.

If it can be computed from the Definition *and* the Instance → it is a **resolved value**, and it belongs in neither.

## 3.9 Reserved extension point: Metadata

`ItemInstance.Metadata` is an optional, reserved table for per-instance data that a future system needs and that no typed field covers - seasonal event tags, fishing weights, crafted-by attribution, skin references, signatures.

**It has no behaviour in any phase of the current roadmap. Phases I through VI must not read or write it.**

### 3.9.1 What the reservation actually buys

The benefit is a **governed name, not a shipped field**.

Instances are plain Lua tables, and every optional instance field is already read nil-tolerantly by convention - `Origin` and every equipment slot work that way. A future system could therefore add a key with no reservation at all, and no migration would be required either way.

What the reservation prevents is the **ungoverned** version of that: three systems inventing three different bags, or a resolved value being parked in an instance because no rule said otherwise. Sections 3.7 and 3.8 are where this pillar's value lives, and an untyped bag is precisely what erodes them.

The value is the contract below. It is not the empty table.

### 3.9.2 Sparse storage

**`Metadata` is omitted when empty. It is never written as `{}`.**

An instance carrying no metadata has no `Metadata` key at all.

Writing an empty table on every instance would cost roughly 15 bytes of JSON each - negligible against the 4 MB key limit, so size is not the argument. The real problem is that a key present on every instance *implies it is guaranteed present*, and code written on that assumption breaks the first time an instance appears without it. Keeping it sparse makes nil-tolerance the only possible read pattern, which is the correct one:

```lua
local weight = instance.Metadata and instance.Metadata.fishing and instance.Metadata.fishing.Weight
```

### 3.9.3 Rules

1. **Namespaced by owning system.** `Metadata.fishing = { Weight = 4.2 }`. One system owns one namespace, which prevents silent key collisions between features written a year apart.
2. **Never a resolved value.** The derivability test applies unchanged. `Metadata` is not a cache.
3. **Never a substitute for a typed field.** If data is core to items, it gets a real field. `Metadata` is for the genuinely peripheral or system-specific, not a way to skip designing a field.
4. **Never client-trusted.** Server-written only, like every other instance field.
5. **Bounded.** Not a log, not a history, not an append-only list.
6. **Documented on introduction.** When a system first writes a namespace, this specification records which system owns which keys. An undocumented namespace is a defect.

### 3.9.4 Promotion path

If a `Metadata` namespace becomes universal - present on essentially every instance and read by multiple systems - it is **promoted to a typed field** through a migration, and the namespace is removed in the same step.

`Metadata` is a staging area for shapes that are still uncertain. It is not a permanent home for settled ones.

---

# 4. ★ Architectural Pillar: World Identity and Origin

A world is an **identity**, not a difficulty tier. Two worlds should differ in what is *obtainable*, *craftable*, *discoverable*, and *completable* - not merely in how large the numbers are.

## 4.1 WorldDefinition

Config, `ReplicatedStorage/Config/Worlds`.

| Field | Notes |
|---|---|
| `Id` | Permanent. Referenced by saves. |
| `Display` | `Name`, `Icon`, `Theme`, `Palette` |
| `Tier` | Depth and progression position |
| `UnlockRequirements` | Gates access; grants `Unlocks.Worlds[id]` |
| `AffixPoolId` | The world's affix pool (section 9) |
| `NativeMaterials` | ItemIds that originate here |
| `EvolutionPaths` | Evolution lines available or gated here |
| `Collectibles` | The world's collection set - the completion denominator |
| `ExplorationSet` | `{ Areas, Landmarks }` - the exploration denominator |
| `SecretCount` | **A count only. Never recipe IDs.** |

`SecretCount` deserves emphasis: a world definition lives in `ReplicatedStorage` and is therefore client-readable. Listing secret recipe IDs there would publish every secret in the game. The count lets the UI show *"3 of 7 secrets discovered"* while the world→recipe mapping stays in `ServerStorage` (section 12.4).

## 4.2 Origin semantics

`Origin` records **where a thing came from**. Its rules:

- **Set once, at creation** - when an item is generated by a drop or produced by a craft.
- **Permanent.** Never rewritten. It survives evolution, including a `BecomesItemId` change.
- **Optional.** `nil` is legitimate and means *no meaningful origin*: starter equipment, items migrated from v1, system or mission grants.
- **Never an error.** Code reading `Origin` must handle `nil` as "unknown", never as corruption.

## 4.3 Origin is not CurrentWorld

Two distinct concepts, easily conflated:

| Concept | Stored in | Means |
|---|---|---|
| `WorldExploration.CurrentWorld` | Save, mutable | Where the player **is** |
| `ItemInstance.Origin` | Save, permanent | Where an item **came from** |
| `ItemDefinition.NativeOrigin` | Config, immutable | Where an item kind **belongs** |

Several mechanics need both at once - "evolve an item from the Deep Hollow *while standing in* the Deep Hollow" reads `Origin` and `CurrentWorld` together.

## 4.4 Stackables carry Origin at the Definition level

This resolves a genuine problem that only appears once Origin is formalised.

Stackable materials are stored as `[itemId] = count`. **They have no instance, so they cannot carry a per-copy `Origin`.** A recipe requiring "a crystal from the Deep Hollow" therefore cannot inspect an instance field.

Two possible resolutions:

| Approach | Verdict |
|---|---|
| Split stacks by origin: `Items[itemId][origin] = count` | Rejected. Multiplies save size, complicates every stack operation, and makes capacity accounting ambiguous. |
| **`Definition.NativeOrigin`** - origin is a property of the item *kind* | **Adopted.** |

`mat_void_shard` is *inherently* a Deep Hollow material. Its origin is intrinsic to what it is, not to which copy you hold. So:

- **Stackable items** carry origin through `Definition.NativeOrigin` - **item-kind level, in Config**
- **Unique instances** carry origin through `Instance.Origin` - **copy level, in the save**

This is precisely why *"not every item must have an Origin"* is the correct architecture: a generic material like `mat_iron_scrap` has no `NativeOrigin` and needs none.

## 4.5 The six foundations

Each with its concrete mechanism.

**1 · World-specific affix pools.** `Origin` records which world's pool produced an item's affixes. Enables provenance display and goals such as *"obtain an item bearing a Deep Hollow exclusive affix."* Section 9.

**2 · Evolution paths.** An evolution stage may declare `RequiresOrigin` (the item must be *from* a world) or `RequiresWorld` (the player must be *in* a world). Two distinct gates, both enabled by 4.3. `WorldDefinition.EvolutionPaths` declares which lines a world supports. Section 10.

**3 · Crafting materials.** `NativeMaterials` declares a world's materials. A recipe input may require `{ Tag = "crystal", Origin = "world_deep_hollow" }`, resolved against `NativeOrigin` for stackables and `Origin` for instances. Section 11.

**4 · Secret recipes.** Discovery conditions may require presence in a world, or possession of items with a given Origin. The world→secret mapping lives in `ServerStorage`. Section 12.

**5 · Collectibles.** `WorldDefinition.Collectibles` is the denominator; `Collection` in the save is the numerator. Per-world completion is computed dynamically, never stored - consistent with Sprint 02 §9.3.

**6 · Exploration completion.** `ExplorationSet` is the denominator; `DiscoveredAreas` and `DiscoveredLandmarks` are the numerator. Percentages are always computed and never stored, per Sprint 02's rule that discovered content is saved and percentages are not.

## 4.6 Origin as a general architectural rule

Origin generalises beyond items:

> **Anything permanently tied to a place records that place at creation.**

Future systems - missions, achievements, NPCs, cosmetics - should record Origin where a permanent tie to a world exists. The field is optional everywhere, and its absence always means "unknown", never "invalid".

---

# 5. Item System

## 5.1 Identifiers

Stable strings, prefixed by category, **never renamed or reused** - a save may reference an ID years later.

| Prefix | Category | Example |
|---|---|---|
| `mat_` | Material | `mat_azure_shard` |
| `cry_` | Crystal | `cry_veiled_prism` |
| `pick_` | Equipment (Pickaxe) | `pick_ironclad` |
| `brac_` | Equipment (Bracelet) | `brac_stoneheart` |
| `hood_` | Equipment (Hood) | `hood_prospector` |
| `hat_` | Equipment (Hat) | `hat_lantern_crown` |
| `mant_` | Equipment (Mantle) | `mant_deepwarden` |
| `csm_` | Cosmetic | `csm_azure_trail` |
| `cons_` | Consumable | `cons_luck_draught` |

## 5.2 ItemRegistry

A **Shared** module, not a Service - both sides need definition lookup, and it holds no state.

```lua
ItemRegistry.get(itemId): ItemDefinition?
ItemRegistry.getOrError(itemId): ItemDefinition
ItemRegistry.isStackable(itemId): boolean
ItemRegistry.findByTag(tag): { ItemDefinition }
ItemRegistry.findBySlot(slot): { ItemDefinition }
ItemRegistry.findByOrigin(worldId): { ItemDefinition }
```

At load it aggregates every Config item file and **validates each definition**, following the precedent set by `SystemLoader`. Boot fails loudly on: unknown category, missing `Slot` on equipment, `Stackable = true` with `MaxStack = 1`, unknown stat keys, unknown `EvolutionLine`, unknown `NativeOrigin`, or a duplicate `Id`.

Machine-checked Config is what makes "adding an item is a Config entry" safe rather than merely convenient.

### 5.2.1 Registries are strictly read-only

A registry answers **"what is defined?"** and nothing else. `ItemRegistry` must never contain:

| Prohibited here | Belongs to |
|---|---|
| Stat resolution | `StatResolver` (Phase II) |
| Equipment calculations | `EquipmentService` (Phase II) |
| Affix resolution | `AffixResolver` (Phase III) |
| Loot generation | `LootService` (Phase III) |
| Evolution logic | `EquipmentService` (Phase V) |
| Item instance handling | `InventoryService` (Phase I) |
| Any player or instance state | The player's save |

Enforced mechanically, not by convention: every registered entry is **deep frozen**, so no consumer can mutate Config through a lookup. A single stray `ItemRegistry.get(id).Value = 0` would otherwise corrupt that definition for every player on the server until it restarted.

The one computation permitted is over the taxonomy a registry itself owns - `compareRarity` orders a Config-defined enum, consumes no player state, and produces no gameplay value. The alternative is every caller reimplementing rarity order.

## 5.3 The registry pattern

Every Config registry in Crystalbound follows one shape. `WorldRegistry`, `RecipeRegistry`, `AffixRegistry` and `EvolutionRegistry` are expected to conform rather than reinvent.

The mechanics live in `ReplicatedStorage/Modules/Registry.lua`:

```lua
Registry.build({
    Name = "ItemRegistry",
    Sources = ItemSources,                  -- map of source name to entries
    Validate = validateDefinition,          -- per-entry, appends to problems
    ValidateReferences = validateReferences, -- optional whole-set second pass
}) -> RegistryHandle
```

The handle exposes `get`, `getOrError`, `exists`, `all`, `where`, `count`, `sourceOf`.

`Registry` owns: source aggregation, duplicate detection across sources, problem collection, deep freezing, error formatting, and the lookup surface. A registry module supplies only its sources and its validator, so a new one is roughly thirty lines.

Three guarantees it provides to every registry:

1. **Read-only by construction** - deep frozen entries (5.2.1).
2. **All problems at once** - a malformed Config fails the boot with a complete list, so one boot surfaces every error rather than one per fix cycle.
3. **Deterministic messages** - sources and keys are iterated in sorted order, so error output is identical between boots instead of following hash order.

An index module should return a **map of source name to entries** rather than a pre-merged table. That is what lets the registry report *"duplicate Id 'pick_starter' in Equipment (already defined in Materials)"* instead of just *"duplicate Id."*

---

# 6. Inventory System

`InventoryService` - Service tier, depends on `PlayerDataService`.

## 6.1 Responsibilities

**`InventoryService` is the sole long-term owner of item instances.** Instance creation, lookup, insertion, removal, equipping and domain validation belong here and are not duplicated anywhere else.

Owns `Inventory.Items` and `Inventory.Instances`. Adds and removes stackables, creates and destroys instances, enforces capacity, performs salvage.

Does **not** decide what items are worth, generate loot, resolve stats, or know about worlds.

### 6.1.1 The two sanctioned exceptions

Both are narrow, and neither is a precedent.

**The v1→v2 migration constructs instances inline.** It has to: it runs during profile load, before any Service is reachable, and it must keep working unchanged forever. A migration that called `InventoryService.addInstance` would silently change behaviour the first time that method was revised - years after the migration was reviewed. The migration therefore does the **minimum** conversion work and nothing more: it creates instances for equipped items and stops. It never reads, filters, equips, salvages, or validates beyond the existence check §15.4 requires.

**`ProfileValidator` performs schema validation.** This is a different concern from domain validation, not a duplicate of it:

| | Validates | Example |
|---|---|---|
| `ProfileValidator` | **Schema** - is this shaped like an instance? | Is `Roll` a number within `[0,1]`? |
| `InventoryService` | **Domain** - is this instance legal? | Does the `ItemId` exist? Is it valid in that slot? Should a malformed instance be pruned? |

The split is forced as well as principled. `PlayerDataService` declares no dependencies and `InventoryService` depends on it, so validating domain rules during profile load would invert the dependency and the engine would reject the cycle at boot.

Everything outside these two exceptions goes through `InventoryService`.

## 6.2 Indicative API

```lua
-- Stackables
addItem(player, itemId, count): (boolean, string?)
removeItem(player, itemId, count): (boolean, string?)
getCount(player, itemId): number
hasItems(player, { [itemId]: count }): boolean

-- Instances
addInstance(player, instance): (string?, string?)      -- returns instanceId
removeInstance(player, instanceId): (boolean, string?)
getInstance(player, instanceId): ItemInstance?
listInstances(player, filter?): { [string]: ItemInstance }
setLocked(player, instanceId, locked): boolean
setFavorite(player, instanceId, favorite): boolean

-- Capacity
getUsage(player): { StackSlots: number, InstanceSlots: number }
hasRoomFor(player, itemId, count): boolean

-- Salvage
salvage(player, instanceId): (boolean, string?)         -- refuses if Locked
```

These signatures are **indicative**, not frozen. Per R-8, the public API is expected to settle during implementation, and the Remotes layer is designed only afterwards.

## 6.3 Capacity model

Two independent pools, because materials and equipment grow at completely different rates:

| Pool | Field | Counts |
|---|---|---|
| Stack slots | `Inventory.Capacity` (existing) | One per distinct stackable ItemId |
| Instance slots | `Inventory.InstanceCapacity` (new, additive) | One per instance |

A stack of 900 `mat_azure_shard` occupies one slot; exceeding `MaxStack` opens a second. `Inventory.Capacity` remains the **owned** count - effective capacity including bonuses is resolved at runtime and never saved. Alternatives are **O-2**.

## 6.4 Full inventory blocks the pickup

**Approved.** When inventory is full, the drop is **blocked with explicit feedback**. Loot is never silently destroyed and never queued into an invisible buffer.

In an RNG collection game, losing a rare drop without knowing is the worst possible outcome - strictly worse than being told to clear space.

## 6.5 Transactional guarantee

Any operation touching more than one item is **all-or-nothing**.

Implementation rule: **validate everything, build the result in memory, then apply with no yields.** The profile is a plain Lua table, so a single synchronous block cannot be interrupted. Instance ID generation, capacity checks, and Config lookups all happen before the block.

This is a correctness requirement, not an optimisation.

## 6.6 The mutation funnel

Every write to `Inventory.Items` or `Inventory.Instances` passes through one private function. Public methods validate and *describe* the change they want; they never touch the profile.

```
applyMutations(player, mutations) -> (ok, reasonCode?, changes?)

  Phase 1  VALIDATE   invariants checked against a projection; nothing is written
  Phase 2  APPLY      mutate, collecting change descriptors while data still exists
  Phase 3  NOTIFY     fire observers, only once state is consistent
```

**This ordering is a standing architectural pattern for every transactional system** - crafting, salvage, loot application - and not an InventoryService detail. Three properties follow from it:

**Atomicity.** Because Phase 1 writes nothing, a batch that fails on its third entry leaves the profile untouched. That is what makes multi-item operations all-or-nothing without any rollback machinery.

**Observers never see partial state.** Notification is deferred to Phase 3, so a subscriber cannot read an inventory mid-batch.

**One place for cross-cutting concerns.** Dirty flags, replication, analytics and last-line invariant checks all attach here rather than to each public method.

The funnel takes a **list** even when every current caller passes one entry. Salvage and crafting will pass several, and the transactional guarantee belongs in one place rather than in each of them.

Two rules that make the pattern hold:

- **Everything the mutation needs must be allocated inside Phase 2.** InventoryService's instance-ID allocator originally ran before the funnel, so a rejected mutation would still have advanced the counter - a write outside the transaction boundary. Allocation belongs inside the apply phase.
- **Invariant failures are bugs, not player errors.** Public methods own player-facing validation and return specific codes. Anything reaching the funnel malformed is a programming error, so it logs at Error and returns a distinct `InvariantViolation` code.

---

# 7. Equipment System

`EquipmentService` - depends on `PlayerDataService`, `InventoryService`.

## 7.1 Slots hold InstanceIds

**Approved.** `Equipment.<Slot>` changes from ItemId to InstanceId - the breaking part of the v1→v2 migration.

```lua
Equipment = {
    Pickaxe = "7",      -- instanceId
    Bracelet = nil,     -- absent = empty
}
```

An equipped instance remains in `Instances`. Equipping is a **reference**, not a move.

## 7.2 Stat resolution

**Approved: one shared `StatResolver`.** A Shared module used by both server and client, so resolved stats never cross the wire and there is exactly one implementation of the formula.

```
per stat key k:

  1. flat    = StatKeys[k].Default
  2. flat   += sum over equipped instances of
                  BaseStats[k] * evolutionMultiplier(instance)
  3. flat   += flat affix contributions      Min + (Max - Min) * Roll
     percent += percent affix contributions  same formula
  4. flat   += Flat modifiers supplied in the context
     percent += Percent modifiers supplied in the context
  5. value   = flat * (1 + percent)
  6. value   = clamp(value, StatKeys[k].Min, StatKeys[k].Max)
```

**Step 5 is the single canonical combination and must exist in exactly one place.** Additive-before-multiplicative versus per-source multiplication produce wildly different balance, and two implementations drifting is a bug class that is nearly undiagnosable from player reports.

`Default` participating in the flat term is what lets one formula serve every stat: `MiningPower` starts at 0 and accumulates, `MiningSpeed` starts at 1 so a `+0.2` flat and a `+10%` modifier resolve to `(1 + 0.2) * 1.1 = 1.32`.

**Evolution scales flat contributions only** (II-6). Scaling percent contributions as well compounds multiplicatively in a way that is very hard to balance.

**`Progression.Upgrades` is NOT read here.** An earlier revision of this pipeline had `StatResolver` reading it directly. That contradicted II-2 - the resolver may depend on read-only Config registries, never on Service-owned state - and II-4, which names the accessor `getEquipmentStats` precisely because upgrades and buffs are not equipment.

Upgrades, buffs, debuffs, world modifiers and event bonuses all arrive the same way: as **normalised `StatModifier`s supplied by whichever service owns them**, in step 4. That keeps one rule rather than a rule plus an exception, and it is why adding a new contribution source needs no change to `StatResolver` at all.

Resolved blocks are cached per player by `EquipmentService`, never by `StatResolver`, and never persisted.

## 7.3 Stat keys

Config-defined in `StatKeys.lua`, so a new stat is a Config entry: `MiningPower`, `MiningSpeed`, `Luck`, `CrystalFind`, `StackCapacity`, `InstanceCapacity`, `ExperienceGain`.

`Luck` feeding back into loot generation is the mechanism behind `ProjectContext.md`'s *"luck should improve through gameplay."*

---

# 8. Loot Generation

`LootService` - depends on `PlayerDataService`. Pure generation; never writes to inventory.

## 8.1 Boundary and the tier rule

```
Player interaction
    → MiningService          (tier 2, validates)
    → OreManager             (tier 1, node state)
    → LootService.roll(ctx)  (tier 2, generates)
    → InventoryService       (tier 2, stores)
```

**`OreManager` must never call `LootService`.** Managers are tier 1 and initialise first, so the reference could not be satisfied - the engine rejects it as a tier violation at boot. `MiningService` is the tier-2 coordinator.

## 8.2 Loot context

```lua
{
    WorldId = "world_deep_hollow",     -- becomes the item's Origin
    NodeType = "node_void_vein",
    NodeTier = 3,
    Luck = 1.42,                        -- resolved
    CrystalFind = 0.15,
    PlayerLevel = 17,
}
```

## 8.3 Pipeline

```
1. Select drop table    (Config, by NodeType, scoped to WorldId)
2. Roll drop count
3. Per drop:
     a. Roll rarity     (weights adjusted by Luck)
     b. Select item
     c. If Equipment:   roll affix count, generate affixes (section 9)
     d. Set Origin = context.WorldId
     e. Emit a stackable delta or a new instance
4. Update pity counters (if O-4 approved)
```

## 8.4 How luck applies

Luck scales the **weight of entries at or above a rarity threshold**, leaving common weights untouched:

```
adjustedWeight = baseWeight * (rarity >= LuckThreshold and Luck or 1)
```

Chosen over extra roll attempts or a rarity floor shift because it is monotonic, tunable per rarity, and free of the discontinuities a floor shift creates at breakpoints. Alternatives are **O-3**.

## 8.5 Server authority

All generation is server-side. The client is told **what it received**, never how it was chosen.

Drop tables live in `ReplicatedStorage/Config` and are client-readable - acceptable for displayed odds, but it means **no secret content may live in a drop table** (section 12.4).

One `Random` instance per server, created at `Initialize`. `Random.new()` seeded from the clock in a tight loop can correlate.

---

# 9. World Affix Pools

The primary mechanism of world identity in items.

## 9.1 Affix definition

```lua
{
    Id = "affix_voidtouched",
    StatKey = "CrystalFind",
    Mode = "Percent",
    Min = 0.05,
    Max = 0.18,
    Tier = 3,
    AllowedSlots = { "Pickaxe", "Mantle" },
    IncompatibleWith = { "affix_lightbound" },
    Tags = { "void", "cavern" },
    Display = { Name = "Voidtouched", Format = "+%s%% Crystal Find" },
}
```

An instance stores only `{ Id, Roll }`. `Min`/`Max` remaining in Config is what preserves retroactive rebalancing.

## 9.2 World pool

```lua
{
    WorldId = "world_deep_hollow",
    Pools = {
        [1] = { { Id = "affix_sturdy", Weight = 100 }, ... },
        [3] = { { Id = "affix_voidtouched", Weight = 20 }, ... },
    },
    Exclusive = { "affix_voidtouched" },
    Forbidden = { "affix_sunlit" },
}
```

## 9.3 Generation

```
1. Roll affix count from AffixSlots (weighted by rarity)
2. Build the candidate pool:
     world pool for the rolled tier
     ∩ affixes whose AllowedSlots includes this slot
     − Forbidden
     − already selected
     − IncompatibleWith of already selected
3. Weighted pick
4. Roll each Roll as a float in [0, 1]
```

Exclusivity is enforced by **absence from other worlds' pools**, not by a flag - a boolean would still let a mis-authored pool leak an affix. The registry validates that every affix in `Exclusive` appears in exactly one world's pools.

## 9.4 Extensibility

Adding a world is one world Config entry, one affix pool, and optional new affixes and items. **No code changes.**

---

# 10. Equipment Evolution

Per-instance progression: an item carried a long time becomes measurably the player's own.

## 10.1 Evolution line

```lua
{
    Id = "evo_ironclad",
    Stages = {
        [1] = { StatMultiplier = 1.00 },
        [2] = {
            StatMultiplier = 1.15,
            Requirements = {
                Experience = 1000,
                Items = { { ItemId = "mat_iron_scrap", Count = 25 } },
            },
            GrantsAffixSlot = true,
        },
        [3] = {
            StatMultiplier = 1.35,
            Requirements = {
                Experience = 4000,
                RequiresOrigin = "world_deep_hollow",   -- item must be FROM there
                RequiresWorld = "world_deep_hollow",    -- player must be IN there
            },
            BecomesItemId = "pick_ironclad_awakened",
        },
    },
}
```

`RequiresOrigin` and `RequiresWorld` are the concrete expression of World Identity in evolution (section 4.5, foundation 2).

## 10.2 Design positions

| Question | Position | Why |
|---|---|---|
| Preserve affixes? | **Yes, always** | Destroying a good roll punishes the player who invested most. |
| Grant affix slots? | **Yes, at specific stages** | Makes an old item worth keeping over a fresh drop. |
| Mutate in place or new instance? | **Mutate in place** | Preserves `InstanceId`, so equipped state, lock, favourite, and Origin survive. A new instance would silently unequip the item. |
| May `ItemId` change? | **Yes, via `BecomesItemId`** | Lets a fully evolved item earn a new name and model. Registry validates the target exists. |
| Does Origin change? | **Never** | Origin is permanent by definition (4.2). |
| Reversible? | **No** | Reversal implies refunding materials and re-rolling slots. |

## 10.3 Experience source

Deliberately unspecified - **O-5**. Mining while equipped, feeding duplicates, or a dedicated material each produce a very different play pattern. That choice belongs to game design.

## 10.4 Placement

Evolution is instance mutation plus stat implications, both already owned by `EquipmentService`. Recommend it live there; a separate service for one operation adds a dependency edge without reducing complexity. **O-6.**

---

# 11. Crafting System

`CraftingService` - depends on `PlayerDataService`, `InventoryService`, `LootService`.

## 11.1 Recipe definition

```lua
{
    Id = "recipe_stoneheart_bracelet",

    Inputs = {
        { ItemId = "mat_iron_scrap", Count = 12 },
        { Tag = "crystal", Count = 3, MinRarity = "Rare" },
        { Tag = "crystal", Count = 1, Origin = "world_deep_hollow" },
    },

    Output = { ItemId = "brac_stoneheart", Count = 1, RollAffixes = true },

    Requirements = {
        Level = 10,
        RequiresWorld = "world_crystal_caverns",
        RequiresStation = "station_forge",
    },

    Discoverable = false,
}
```

**Tag-based inputs are the main extensibility feature.** `{ Tag = "crystal", Count = 3, MinRarity = "Rare" }` accepts any qualifying crystal, so a crystal added two sprints later works in every existing recipe automatically. Enumerating IDs would mean editing every recipe forever.

The `Origin` input constraint resolves against `Definition.NativeOrigin` for stackables and `Instance.Origin` for instances, per 4.4.

## 11.2 Craft flow

```
1. Recipe known?        Unlocks.Recipes[recipeId] == true
2. Requirements met?    level, world, station
3. Inputs available?    resolve tag and origin constraints
4. Room for output?     capacity check BEFORE consuming
5. Build output         generate instance, roll affixes, set Origin
6. Apply atomically     consume inputs and add output, no yields
```

Steps 4 and 5 before step 6 is the transactional requirement from 6.5. Checking capacity *after* consuming would destroy the inputs and drop the result.

## 11.3 Crafted items carry Origin

`RollAffixes = true` routes through the **same** section 9 pipeline used for drops, using the **crafting world's** affix pool, and sets `Origin` to the crafting world.

This makes crafting *location* a meaningful decision rather than a formality, and it keeps Origin semantics uniform: an item's Origin is always the world it came into existence in. **O-7** if you would rather crafted items use a fixed pool.

## 11.4 Tag resolution is player-driven

When a tag-based input can be satisfied several ways, the **player chooses** - the request carries explicit selections and the server validates them. Auto-selecting will eventually consume something the player was saving, and no confirmation dialog fully undoes that.

---

# 12. Secret Recipe System

Recipes discovered through play. `Unlocks.Recipes` already stores discovery state, so the core feature needs no schema change.

## 12.1 Discovery methods

| Method | Trigger |
|---|---|
| **Combination** | Player submits an input set matching a hidden recipe |
| **Condition** | A profile state is reached - e.g. full exploration of a world |
| **Hint item** | A consumable grants knowledge |

Condition triggers may reference World Identity: *"discover every landmark in the Deep Hollow"*, or *"own three items with Deep Hollow Origin."*

## 12.2 Combination discovery

`CraftingService` receives an input set matching no *known* recipe and checks it against the **full** table including undiscovered entries. On a match it sets `Unlocks.Recipes[recipeId] = true`, performs the craft, and notifies the player.

## 12.3 Anti-brute-force

Combination discovery is scriptable. Two mitigations, both recommended: **rate limiting** per player per interval, and a **material cost per failed attempt**. Cost matters more - it makes brute-forcing expensive rather than merely slow. **O-8.**

## 12.4 Replication - the part that must not be got wrong

**Approved: secret recipes live in `ServerStorage`.**

Anything in `ReplicatedStorage` is readable by an exploiter, and one dump publishes every secret permanently.

| Content | Location | Client-readable |
|---|---|---|
| Public recipes | `ReplicatedStorage/Config/Recipes` | Yes |
| **Secret recipes** | **`ServerStorage/Config/SecretRecipes`** | **No** |
| Hints and flavour | `ReplicatedStorage/Config/RecipeHints` | Yes |
| World secret **counts** | `ReplicatedStorage/Config/Worlds` | Yes |
| World→secret **mapping** | **`ServerStorage`** | **No** |

This is the one deliberate exception to `Architecture.md`'s convention that Config is shared. Hint text replicates; the recipe it points to does not. A discovered secret is sent to that player individually.

## 12.5 Partial knowledge

`Unlocks.RecipeHints[recipeId] = tier` (additive) lets a player know a recipe exists and roughly what it needs. **O-9.**

---

# 13. Networking Considerations

**No Remotes are specified as deliverables and no system may be designed to require one.** Per R-8, the networking layer is deferred until the Inventory, Equipment, and Crafting APIs have stabilised through implementation.

This section records the **constraints those APIs must satisfy**, so the eventual Remotes layer is a thin translation rather than a redesign.

## 13.1 Design constraints

**1 · Config never crosses the wire.** The client already holds `ReplicatedStorage/Config`. APIs must be expressible in terms of IDs, not definitions. Any API that would need to send a definition is mis-shaped.

**2 · Resolved stats never cross the wire.** Both sides run the shared `StatResolver`. No API returns a stat block for transmission.

**3 · Every mutation must be expressible as a delta.** A full inventory snapshot on every pickup is the classic performance failure in this genre. `InventoryService` must be able to report *what changed*, not only *current state* - which is a constraint on its internal design, not on a Remote.

**4 · Drops must be batchable.** Mining produces frequent small drops. The loot path must tolerate accumulating results and applying them together.

**5 · Server authority is absolute.** A client-supplied instanceId is a **claim**, never a fact. Every future entry point validates against the profile. This holds regardless of when Remotes arrive.

## 13.2 Indicative future contract

Recorded for direction only. **Not a Sprint 03 deliverable, and not binding.**

| Event | Direction | Payload |
|---|---|---|
| `InventorySync` | S→C | Full inventory, once on load |
| `InventoryDelta` | S→C | Changed stackables, added/removed instances |
| `EquipmentChanged` | S→C | Slot, instanceId |
| `RecipeDiscovered` | S→C | recipeId |
| `RequestEquip` / `RequestCraft` / `RequestSalvage` | C→S | Explicit IDs and selections |

Affix rolls are floats in `[0,1]`. Quantising to one byte on the wire would cut affix payload roughly 4x. **Approved position: full float in saves** - the save is the record of the player's luck and must not be lossy. Wire quantisation stays open until Remotes are designed - **O-10**.

---

# 14. Architecture And Dependencies

## 14.1 Placement

```
ServerScriptService/Services/
├── InventoryService/          { "PlayerDataService" }
├── EquipmentService/          { "PlayerDataService", "InventoryService" }   + evolution (O-6)
├── CraftingService/           { "PlayerDataService", "InventoryService", "LootService" }
├── LootService/               { "PlayerDataService" }
└── MiningService/             { "InventoryService", "LootService", "OreManager" }

ServerScriptService/Managers/
├── WorldManager               {}                     world state, current world context
└── OreManager                 { "WorldManager" }     node state (interface only)

ReplicatedStorage/Modules/          Architecture.md 190: reusable modules
├── Registry.lua                    shared registry foundation (5.3)
├── ItemRegistry.lua                definition lookup + boot validation
├── StatResolver.lua                THE stat formula, one implementation
├── AffixResolver.lua               roll → value
└── WorldRegistry.lua               world definition lookup

ReplicatedStorage/Shared/           Architecture.md 227: shared server/client code
├── Types/ItemTypes.lua             ItemDefinition, ItemInstance, StatBlock
└── Utilities/TableUtil.lua         deepCopy, deepFreeze, frozenCopy

ReplicatedStorage/Config/
├── Items/                     per-category files + index
├── Affixes.lua
├── StatKeys.lua
├── Recipes/                   public recipes only
├── RecipeHints.lua
├── EvolutionLines.lua
├── DropTables/                per node type
└── Worlds/                    world definitions + affix pools

ServerStorage/Config/
├── SecretRecipes.lua          NEVER replicated
└── WorldSecrets.lua           world→secret mapping, NEVER replicated
```

Config is split into folders with index modules. A single `Items.lua` reaching several thousand lines becomes a merge-conflict magnet the first time two people add items in one sprint.

## 14.2 Dependency graph

```
Tier 1   WorldManager        {}
         OreManager          { "WorldManager" }

Tier 2   PlayerDataService   {}                                              [Sprint 02]
         InventoryService    { "PlayerDataService" }
         LootService         { "PlayerDataService" }
         EquipmentService    { "PlayerDataService", "InventoryService" }
         CraftingService     { "PlayerDataService", "InventoryService", "LootService" }
         MiningService       { "InventoryService", "LootService", "OreManager" }
```

No cycles. No Manager depends on a Service. This will be the **first non-trivial exercise of the dependency resolver** - Sprint 01 verified it against an empty registry, Sprint 02 against one service with no dependencies.

---

# 15. Save Schema Changes

Designed here. **Not executed during Sprint 03.**

## 15.1 Requires migration v1 → v2

| Change | Why breaking |
|---|---|
| `Equipment.<Slot>`: ItemId → InstanceId | Existing values are ItemIds; reading them as InstanceIds would silently empty every slot |

## 15.2 Additive - no version bump

Backfilled automatically by `ProfileValidator` per Sprint 02 §10.2:

| Field | Default |
|---|---|
| `Inventory.Instances` | `{}` |
| `Inventory.InstanceCapacity` | `50` |
| `Profile.NextInstanceId` | `1` |
| `Unlocks.RecipeHints` | `{}` |
| `Collection.Affixes` | `{}` (O-9) |
| `Progression.PityCounters` | `{}` (O-4) |
| `Statistics.ItemsSalvaged`, `ItemsEvolved` | `0` |

## 15.3 Instance ID generation

**Approved: profile-local counter, stored as strings.**

`Profile.NextInstanceId` increments on each instance creation. IDs are never reused within a profile. Chosen over `HttpService:GenerateGUID` because a GUID is 36 characters and instance IDs appear in every inventory payload.

## 15.4 The migration

```
1 → 2, for each equipped slot holding a non-nil value:
    a. Treat the value as an ItemId; look it up in ItemRegistry
    b. If unknown, clear the slot and log (the item was removed from the game)
    c. Otherwise create an instance:
         ItemId      = the old value
         Affixes     = {}                  -- pre-affix items get none
         Stage       = 1
         Experience  = 0
         Origin      = nil                 -- unknown, and legitimately so
         Locked      = false
         Favorite    = false
         CreatedAt   = Profile.CreatedAt
    d. Insert into Inventory.Instances under a fresh instanceId
    e. Replace the slot value with that instanceId
    f. Set Version = 2
```

Satisfies all four Sprint 02 §11.4 requirements: pure, total, transfers before overwriting, frozen once shipped.

**Three deliberate choices.** Pre-affix items migrate with **zero affixes** - retroactively rolling would hand veteran players free power based on nothing. `Origin` is **nil**, which is exactly the case section 4.2 requires code to handle. And an unknown ItemId **clears the slot rather than failing**, because a removed item must never lock a player out of their account permanently.

---

# 16. Design Decisions

## 16.1 Resolved

Approved and settled. Recorded here as the standing position.

| # | Decision |
|---|---|
| **R-1** | **Persist the roll, never the resolved value.** The refined form of Sprint 02's "never save stats" rule. |
| **R-2** | **Migrate equipment slots from ItemId to InstanceId** via a v1→v2 migration. |
| **R-3** | **Affixes stored as an explicit `{ Id, Roll }` list**, not an RNG seed. A seed would be more compact, but any future change to the generation algorithm or a world's pool would silently rewrite every existing item. |
| **R-4** | **Instance IDs are profile-local counters stored as strings.** Never reused within a profile. |
| **R-5** | **A full inventory blocks the pickup** with explicit feedback. Loot is never silently destroyed. |
| **R-6** | **Secret recipes live in `ServerStorage`**, unreachable by datamining `ReplicatedStorage`. |
| **R-7** | **One shared `StatResolver`** used by both server and client. One formula, one implementation. |
| **R-8** | **The Remotes layer is deferred.** Networking depends on stable public APIs, and those APIs should emerge from implementing Inventory, Equipment, and Crafting. Considerations documented in section 13; nothing built. |
| **R-9** | **`ItemDefinition` versus `ItemInstance` is an architectural pillar** (section 3). |
| **R-10** | **World Identity and `Origin` is an architectural pillar** (section 4). Origin is optional; absence means unknown, never invalid. |
| **R-11** | **Stackables carry origin at the Definition level** via `NativeOrigin`; instances carry it per copy via `Origin`. |
| **R-12** | **Affix rolls stay full floats in saves.** The save is the record of the player's luck. |
| **R-13** | **`ItemInstance.Metadata` is reserved but unused** (section 3.9). Stored sparsely - omitted when empty, never written as `{}`. Governed by the rules in 3.9.3. No phase of the current roadmap reads or writes it. |
| **R-14** | **`InventoryService` is the sole long-term owner of item instances** (6.1). Two sanctioned exceptions only, both narrow: the frozen v1→v2 migration, and `ProfileValidator`'s schema-level validation (6.1.1). |
| **R-15** | **Registries are strictly read-only** (5.2.1). Entries are deep frozen. No stat resolution, evolution, loot generation, affix resolution, equipment calculation, instance handling, or player state. |
| **R-16** | **All registries follow one pattern** (5.3), with mechanics shared in `Modules/Registry.lua`. Future registries supply a validator and their sources; nothing else. |
| **R-17** | **Migration steps are pure transformations.** A step returns `(profile, warnings?)` and never logs. `PlayerDataService` logs the warnings after the migration completes, including on failure. Supersedes the `(profile) -> profile` signature in Sprint02Specification 11.1. |
| **R-18** | **Services may read any persisted profile data when necessary for validation, but only the owning service may mutate that section.** Ownership is defined by write authority, not read exclusivity. This generalises the per-section table in Sprint02Specification 7.3 into a principle, replacing the need for case-by-case exceptions - it is what lets `InventoryService` consult `Equipment` slots to refuse destroying an equipped instance without depending on `EquipmentService`. |
| **R-19** | **Transactional systems follow validate → apply → notify** (6.6). One private mutation path per owned dataset. Phase 1 writes nothing, so failures are atomic; notification is deferred to Phase 3, so observers never see partially applied state. Applies to crafting, salvage and loot application, not only inventory. |
| **R-20** | **Every system validates the objects it produces; downstream consumers assume trusted inputs.** See 16.3. |
| **R-21** | **Derived-state caches invalidate wholly, never incrementally.** An incremental cache must model every dependency correctly forever; a whole-entry cache only has to know *that* something changed. Correctness and simplicity outweigh micro-optimising recomputation. Applies to every cache, not only equipment stats. |
| **R-22** | **Cached accessors return ephemeral snapshots.** A cached table is valid at the moment of the call and must be consumed immediately, never retained across a change - invalidation drops the entry rather than mutating the table a caller holds, so a retained reference goes silently stale. The corresponding change event is the signal to re-read. |
| **R-23** | **Prefer the owner's API over a raw profile-section read when one exists.** A refinement of R-18: raw reads are for cases where no API exists, or where calling one would create a dependency cycle - which is exactly why `InventoryService` reads `Equipment` slots directly rather than calling `EquipmentService:isEquipped`. |

## 16.2 Open

Each has a recommendation. None is settled, and none blocks approval of this specification.

| # | Decision | Recommendation |
|---|---|---|
| **O-1** | Are cosmetics stackable or unique? | **Stackable** - no rolls, no evolution, so instances buy nothing today |
| **O-2** | Capacity model: two pools, one shared pool, or weight-based? | **Two pools** (6.3) |
| **O-3** | Luck formula: weight scaling, extra attempts, or rarity floor shift? | **Weight scaling above a threshold** (8.4) |
| **O-4** | Pity / bad-luck protection? | **Yes**, as a soft weight boost growing with misses, not a hard guarantee. Needs `Progression.PityCounters`. |
| **O-5** | Evolution experience source? | **No recommendation** - a core play-pattern decision for game design |
| **O-6** | Evolution inside `EquipmentService` or its own service? | **Inside `EquipmentService`** (10.4) |
| **O-7** | Crafted affixes: crafting world's pool or a fixed pool? | **Crafting world's pool** - makes location meaningful (11.3) |
| **O-8** | Secret attempt policy: rate limit, material cost, or both? | **Both**, with cost as the primary deterrent |
| **O-9** | Track discovered affixes and recipe hints? | **Affixes yes**; hints only if secrets ship in the same phase |
| **O-10** | Quantise affix rolls on the wire? | **Defer** until Remotes are designed |
| **O-11** | Localisation layer for `Display` text? | **Defer**, with the caveat that extracting it later touches every Config file |

## 16.3 Validation ownership (R-20)

> **Every system validates the objects it produces. Downstream consumers assume trusted inputs.**

Validation belongs at the boundary where an object is **constructed**, not where it is used.

A malformed object arriving at a consumer is a bug in its producer, and the consumer is the worst possible place to diagnose it: it can report that something was wrong, but not *who sent it* or *which line built it*. Detecting a typo at the point of construction gives a stack trace at the mistake, in the system that owns it.

### Corollaries

**A consumer discovering bad input should not start validating.** The producer gets fixed. Adding a check downstream duplicates the rule and hides the real fault.

**Ownership of validation follows ownership of construction.** A consumer must not provide a constructor for the objects it consumes, even one that validates - that inverts the ownership this rule exists to establish, and forces every producer into a dependency on its consumer. `StatResolver` deliberately provides no modifier constructor for exactly this reason.

**Defence-in-depth at an ownership boundary is compatible.** `InventoryService`'s mutation funnel re-checks invariants even though its public methods already validate. That does not contradict R-20 because it treats failure as a *producer bug*: it logs at Error and returns a distinct `InvariantViolation` code, rather than silently coping.

### The client is never a trusted producer

**R-20 governs server-internal boundaries only.**

Every value crossing a Remote is validated server-side regardless of what any client-side system claims to have checked. A client-supplied instanceId, count, or recipe selection is a **claim**, never a fact. Nothing in this rule softens the security position in `ClaudeInstructions.md`, and R-20 must never be cited to justify trusting a payload.

### Where the rule already holds

| Producer boundary | Validates |
|---|---|
| `ItemRegistry` | Every item definition, at boot |
| `SystemLoader` | Every service module's shape, at load |
| `ProfileValidator` | Profile schema, at load |
| `InventoryService.createInstance` | Options and item kind, at construction |
| `Migrations.run` | That each step advanced `Version` |
| `StatResolver` | Nothing - a trusted consumer by design |

---

# 17. Sprint 03 Acceptance Criteria

Sprint 03 is a specification sprint. Its Definition of Done is documentary.

- [x] All eight systems specified.
- [x] `ItemDefinition` versus `ItemInstance` documented as a dedicated architectural pillar with field tables, invariants, and a decision rule.
- [x] World Identity and `Origin` documented as a dedicated architectural pillar covering all six foundations.
- [x] The save-format conflict identified, and the refined rule documented.
- [x] The v1→v2 migration designed against Sprint 02 §11.4's four requirements.
- [x] Additive schema changes distinguished from breaking ones.
- [x] Networking constraints recorded without requiring Remotes.
- [x] Dependency graph specified and checked against the engine's tier rules.
- [x] Config layout specified, including the `ServerStorage` exception for secrets.
- [x] Resolved decisions separated from open ones.
- [x] `ItemInstance.Metadata` reserved as a governed extension point, with rules and a promotion path, and explicitly unused.
- [ ] **Specification reviewed and approved.**

No Lua file is created. No existing file is modified. No migration is executed.

---

# 18. Future Implementation Roadmap

Scheduled as their own sprints **after** this specification is approved. Previously labelled 3.1-3.5.

| Phase | Delivers | Depends on |
|---|---|---|
| **I** | Item model, `ItemRegistry`, migration v1→v2, `InventoryService` | PlayerDataService |
| **II** | `EquipmentService`, `StatResolver` | I |
| **III** | `LootService`, affix generation, World Affix Pools, `WorldManager` | I, II |
| **IV** | `CraftingService`, Secret Recipes | I, III |
| **V** | Equipment Evolution | II, IV |
| **VI** | Remotes layer and client replication, once the APIs above have stabilised | I-V |

**Phase I carries the migration and should land alone, verified, before anything is built on top of it.** It is the highest-risk item in the entire roadmap: it is the first migration the project has ever run, and a mistake in it is permanent.

Phase VI is the deferred networking layer from R-8.

## 18.1 Per-phase acceptance criteria

**Phase I** - Registry validates every definition at boot and fails loudly on malformed Config. Migration converts equipped ItemIds to instances, tolerating absent slots and unknown IDs. A pre-migration profile loads, migrates, and saves at v2. Instance IDs are strings surviving a round trip. Multi-item operations are atomic. **`Metadata` is neither read nor written** - its presence anywhere in Phase I code is a review failure.

**Phase II** - Equip validates slot compatibility and ownership. `StatResolver` is the only implementation of the formula. Resolved stats never reach the profile. Stats recompute after load.

**Phase III** - Drops are server-generated. Affixes respect `AllowedSlots`, `Forbidden`, `IncompatibleWith`. A world-exclusive affix cannot appear elsewhere. `Origin` is set on every generated instance. Changing an affix `Min`/`Max` in Config changes existing items with no migration.

**Phase IV** - Tag inputs resolve; a newly added matching item works in existing recipes without edits. A failed craft consumes nothing. Capacity checked before consumption. Undiscovered secrets absent from `ReplicatedStorage`, verified by grep. Discovery persists across rejoin.

**Phase V** - Evolution preserves affixes, `InstanceId`, lock, favourite, and `Origin`. `BecomesItemId` validated against the registry. Multipliers apply through `StatResolver`.

---

# 19. Future Runtime Verification Plan

For the implementation phases. Recorded here so the specification and its verification stay together.

Sprint 02 recorded two checks as **Not Exercised** because forcing DataStore failures needs deferred infrastructure. That constraint is respected: nothing below requires a mock storage provider.

| # | Check | Phase |
|---|---|---|
| 1 | Startup summary reports full Service and Manager counts; resolution succeeds on a non-trivial graph | I |
| 2 | **Tier violation detection** - temporarily give `OreManager` a `LootService` dependency; the engine must refuse to boot | III |
| 3 | **Circular dependency detection** - temporarily create a Service cycle; the cycle path must be reported | III |
| 4 | Malformed item definition fails at boot with a useful message | I |
| 5 | Migration converts a v1 profile; an unknown ItemId clears the slot without failing | I |
| 6 | Instance round trip - affix rolls byte-identical after rejoin | I |
| 7 | **Retroactive rebalance** - change an affix `Max`, rejoin, resolved stats change and the save does not | III |
| 8 | Atomicity - force a craft to fail at output; no inputs consumed | IV |
| 9 | Affix constraints hold across a large sample | III |
| 10 | World exclusivity - large sample in a forbidding world yields zero occurrences | III |
| 11 | **Secret leakage** - `grep -rn` for secret recipe IDs across `src/ReplicatedStorage` returns nothing | IV |
| 12 | Luck distribution shifts as intended across two luck values | III |
| 13 | `Origin` survives evolution, including a `BecomesItemId` change | V |
| 14 | `Origin = nil` is handled as unknown everywhere it is read | I |

Checks 2 and 3 close the last of the **Sprint 01 unexercised paths** - a real multi-service graph finally makes tier violations and cycles reproducible.

Any check that cannot be run is recorded as **Not Exercised**, never assumed to pass.
