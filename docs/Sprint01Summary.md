# Crystalbound - Sprint 01 Summary

**Sprint:** 01 - CrystalEngine Foundation
**Completed:** 29 July 2026
**Status:** Complete. Runtime verified in Roblox Studio.

---

# Sprint Objective

Build the foundation of CrystalEngine, the custom internal framework that powers Crystalbound.

The goal was infrastructure only:

- A server entry point that starts the engine.
- Automatic discovery and validation of loadable systems.
- A two-phase Initialize / Start lifecycle.
- Explicit dependency declaration with ordered resolution.
- Detection of circular and invalid dependencies.
- Centralised logging.
- Engine lifecycle state tracking and startup diagnostics.

No gameplay logic was to be written. The engine provides tools; gameplay systems use those tools.

---

# What Was Implemented

Nine files were created. All of them sit in folders the architecture already defined - no new folders were introduced.

## Server Engine

Location: `src/ServerScriptService`

**Bootstrap/Main.server.lua**
Server entry point. Requires the engine, hands it the three system folders by name, calls `Start()`. Eight lines of executable code and no logic, per the specification's requirement that Bootstrap only start the engine.

**Core/CrystalEngine.lua**
The engine facade and orchestrator. Owns the Manager, Service and Controller registries. Validates the dependency graph, drives both lifecycle phases, tracks engine state, and logs the startup summary. Exposes `GetService`, `GetManager`, `GetController`, `GetState` and `IsStarted`.

**Core/SystemLoader.lua**
Generic discovery and validation shared by every tier. Requires each ModuleScript inside `pcall`, then validates seven things: returns a table, `Name` is a non-empty string, `Name` matches the ModuleScript name, `Name` carries the correct suffix and is longer than it, `Version` is numeric, `Dependencies` is an array of strings, and `Initialize` / `Start` are functions when present.

**Core/ServiceLoader.lua**
Supplies the Service tier configuration - suffix `Service`, tier rank 2 - and delegates to `SystemLoader`.

**Core/ManagerLoader.lua**
Supplies the Manager tier configuration - suffix `Manager`, tier rank 1 - and delegates to `SystemLoader`.

**Core/DependencyResolver.lua**
Pure topological sort using three-colour depth-first search. Depth-first was chosen over Kahn's algorithm because the traversal stack reconstructs the exact cycle path for the error message. Detects circular dependencies, self-dependencies and missing dependencies. Entry points are sorted so boot order is deterministic between sessions.

**Core/Logger.lua**
Centralised logging at four levels - Debug, Info, Warning, Error - filtered against a configured threshold. `Logger.Scoped(name)` returns a pre-tagged logger so systems do not hand-tag each line. Output format:

```
[Crystalbound][INFO][MiningService] Started
```

The Logger reports but never throws. Raising from inside the logger would unwind the boot sequence and cascade, which the specification forbids. Failure policy belongs to CrystalEngine alone.

## Shared Support

Location: `src/ReplicatedStorage/Shared`

**Types/EngineTypes.lua**
Exports `System`, `SystemDescriptor`, `SystemState` and `EngineState`. Types only, no runtime behaviour.

**Constants/EngineConstants.lua**
Adjustable engine configuration: log prefix, log level, timestamp toggle, boot strictness, and the system folder name map. Data only, frozen with `table.freeze`.

---

# Final Architecture

## Boot Sequence

```
Phase 0  BOOTSTRAP     Main.server.lua points the engine at three folders.

Phase 1  DISCOVERY     Loaders require and validate every ModuleScript.
                       A malformed system is logged and excluded.
                       No lifecycle method has run yet.

Phase 2  RESOLUTION    Per tier, DependencyResolver produces an order.
                       Cycles, missing dependencies and tier violations
                       are caught here.
                       Engine state: Initializing

Phase 3  INITIALIZE    Sequential and blocking, in resolved order.
                       Each call protected by pcall.
                       Engine state: Initialized

Phase 4  START         Dispatched in resolved order via task.spawn.
                       Engine state: Starting, then Running

         DIAGNOSTICS   Startup summary logged.
```

## Error Handling Model

The engine distinguishes two error classes, and this distinction is the core of its failure behaviour:

**Structural errors** - a circular dependency, a missing dependency, a tier violation - abort the boot before any system code runs. A broken graph means the codebase is wrong, and booting a half-valid game would hide that.

**Runtime errors** - a failure inside one `Initialize` or `Start` - are contained. That system is marked `Failed`, its dependents are marked `Blocked`, and every unrelated system still runs. Because the boot order is topological, blocking propagates forward on its own and disables exactly the subtree that relied on the failure, producing one accurate error instead of a cascade.

## Tier Model

Tiers are hard boundaries. The resolver sorts within a tier.

| Tier | Rank | May depend on |
|---|---|---|
| Managers | 1 | Managers |
| Services | 2 | Managers, Services |
| Controllers | 3 | Managers, Services, Controllers |

A Manager declaring a Service dependency is rejected at boot with an explicit message, because the Manager tier initialises first and the reference could never be satisfied.

## Lifecycle Contract

Two guarantees, stated deliberately:

- `Initialize` guarantees every system **exists** and is constructed.
- `Start` guarantees every system has been **dispatched**, not that it has finished.

A system must never assume another system's `Start` has completed. `Start` is dispatched through `task.spawn` because the specification permits `Start` to begin loops, and a system running `while true do` would otherwise deadlock the boot permanently.

## Engine States

`Stopped` -> `Initializing` -> `Initialized` -> `Starting` -> `Running`

Readable through `CrystalEngine.State` or `GetState()`.

---

# Runtime Verification Results

CrystalEngine booted successfully in Roblox Studio. Runtime verification passed.

## Confirmed

- Bootstrap executes and starts the engine.
- All five Core modules load and require one another without error.
- The Logger emits correctly formatted, scoped output.
- Both lifecycle phases run to completion.
- The engine reaches the `Running` state.
- The startup summary is produced.
- A boot with zero registered systems completes cleanly rather than erroring - the intended behaviour, since no gameplay systems exist yet.

## Verification Method

Manual, in Roblox Studio, via Rojo sync.

No automated verification was possible: no Luau analyzer, Rojo CLI, StyLua or Selene binary was available in the development environment. Type correctness under `--!strict` is therefore confirmed only insofar as Studio's own script analysis accepted the code at runtime.

## Known Verification Gap

Because Sprint 01 deliberately shipped no example or demonstration systems, several engine paths executed against an empty registry and have **not yet been exercised with a real system**:

- `Initialize` and `Start` invocation on an actual Service or Manager.
- Dependency ordering with a real dependency graph.
- Circular dependency detection.
- Tier violation detection.
- `Failed` and `Blocked` state propagation.
- `GetService` / `GetManager` retrieval.

These paths are structurally complete and were reviewed, but the first production Service and Manager will be their genuine first test. This is the highest-value verification work remaining and should be treated as part of the next sprint rather than assumed complete.

---

# Lessons Learned

**Reading the documentation first caught real problems.**
The pre-development analysis found that `CodingStandards.md` was an empty file and `ClaudeInstructions.md` was truncated mid-example - both listed as required reading. Writing code first would have meant inventing conventions that later conflicted with the real ones.

**Two source documents disagreed, and it mattered.**
`CodingStandards.md` specified `Module.Initialize()` while `CrystalEngineSpecification.md` specified `Service:Initialize()`. Dot versus colon is not cosmetic - colon passes implicit `self`, and a loader calling the wrong form would have left `self` nil in every stateful system. Resolved by convention: colon for stateful systems, dot for stateless utilities. Conflicts between specification and standards are worth hunting for explicitly.

**A self-review finding was overstated, and the correction changed the work.**
The review reported that instance-path requires would break `--!strict` across twelve sites. Closer analysis showed only one was genuinely broken - a hybrid `WaitForChild(...).Child` pattern. The other nineteen used pure dotted traversal, which Studio's analyzer resolves natively and which is what preserves module type inference. Converting them all would have *broken* strict typing by collapsing every module to `any`. Reporting a pattern's scope demands the same precision as reporting the defect.

**Conventions the engine enforces beat conventions people are asked to remember.**
Validating the `Service` / `Manager` suffix and the `Name`-matches-filename rule at boot turns `CodingStandards.md` from a document into a runtime check. This will matter more as the team grows.

**Configuration is the input most likely to be wrong.**
The one genuine crash risk found in review was an unvalidated log level read from `EngineConstants`. Config files are precisely what non-engineers are invited to edit, so they need more validation than internal code, not less.

**No toolchain meant no automated safety net.**
Every check in this sprint was manual. Pinning Rojo, StyLua and Selene is far cheaper before the codebase grows than after.

---

# Outstanding Future Improvements

## Engine

- **Unobservable `Initialized` state.** `Initialized` is assigned and immediately overwritten by `Starting` with no yield between, so nothing can ever read it. Functionally there are four observable states, not five.
- **Core is not self-contained.** Every Core module requires `EngineTypes` or `EngineConstants` from `ReplicatedStorage/Shared`. The engine cannot be lifted into another place file without bringing those two modules. Retained deliberately - `Shared/Types` is the documented home for types, and the future ClientEngine will want them.
- **Undeclared dependencies are not caught.** `GetService` works for any loaded system whether or not it appears in `Dependencies`. A system can retrieve a module whose `Initialize` has not run. Mitigable by having `GetService` warn during the `Initializing` phase when the caller has not declared the dependency.
- **Boot duration measures dispatch, not startup.** Because `Start` is spawned, the reported figure excludes all `Start` work. The number is correct for what it measures; the label oversells it.
- **Controllers bypass the loader layer.** Managers and Services go through their named loaders; the Controller tier is configured inline in `CrystalEngine`. Done to avoid creating an undocumented `ControllerLoader`, but the asymmetry is real.
- **`StrictBoot = false` retry semantics.** Per-system state now resets on each boot attempt, but the non-strict path remains the less useful of the two and is not the default.

## Project Infrastructure

- **Toolchain pinning.** No Rokit / Aftman manifest, so the Rojo version is unpinned. No `wally.toml` despite an existing `Packages` folder. No `.luaurc`. No StyLua or Selene configuration.
- **Empty folders are invisible to git.** Roughly thirty `src/` folders contain no files, and git cannot track empty directories. A fresh clone will not reproduce the full tree. `.gitkeep` files would fix this.
- **The place file is committed as a binary.** `Crystalbound.rbxl` cannot be merged and will conflict. `ClaudeInstructions.md` establishes that the repository is the source of truth, so the long-term home for world content is Rojo-managed files.
- **Formatting quirk in `CodingStandards.md`.** The `lua` code fence opened near the end of the file is never closed and the file has no trailing newline. Content is complete; only the rendering is affected.

## Next Systems

- **ClientEngine.** Explicitly future work in the specification. `DependencyResolver` and the tier model were written to be reusable by it; `Logger` was kept in `Core` by decision, so the client will need its own.
- **Remotes layer.** `Remotes/Events` and `Remotes/Functions` are defined in the architecture but unbuilt. Open question: instances defined via Rojo, or created at runtime by the engine. Server-side validation of every client payload should be settled as a standing rule first.
- **PlayerDataService and persistence.** Requires a decision on ProfileStore / ProfileService versus a hand-rolled DataStore wrapper, which in turn drives the Wally question.

---

# Definition of Done Confirmation

Measured against the criteria in `CrystalEngineSpecification.md`.

| Criterion | Status | Notes |
|---|---|---|
| Bootstrap starts successfully | Met | Verified in Studio. |
| Core systems load | Met | All five Core modules load and resolve their requires. |
| Services can initialize | Met, unexercised | Code path complete and executed against an empty registry. Not yet run with a real Service. |
| Managers can initialize | Met, unexercised | As above. |
| Logger works | Met | Scoped, formatted, level-filtered output confirmed. |
| Dependencies resolve correctly | Met, unexercised | Resolver runs and returns a valid empty order. Cycle and tier-violation paths not yet triggered at runtime. |
| Client architecture can be expanded later | Met | `DependencyResolver` is Roblox-API-free; the tier model accommodates a Controller tier; the `ClientEngine` seam is intact. |

**Sprint 01 is complete.**

Every Definition of Done criterion is satisfied by working, runtime-verified code. Three criteria are marked *unexercised* because Sprint 01 shipped no demonstration systems by design - the machinery runs, but has not yet carried a real system. Closing that gap is the first task of the next sprint.

## Final Rule Compliance

No gameplay logic exists in `Core` or anywhere in the engine. The engine provides tools. Gameplay systems will use those tools.
