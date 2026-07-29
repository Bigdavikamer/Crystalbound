# CrystalEngine Specification

## Overview

CrystalEngine is the custom internal framework that powers Crystalbound.

Its purpose is to provide a clean foundation for all game systems by managing:

- System initialization
- Service loading
- Manager loading
- Dependency handling
- Logging
- Shared utilities

CrystalEngine should remain independent from gameplay.

The engine provides tools.
Gameplay systems use those tools.

---

# Core Philosophy

CrystalEngine follows a modular architecture.

Systems should:

- Have one clear responsibility.
- Communicate through defined interfaces.
- Avoid unnecessary dependencies.
- Be easy to expand.

The engine should support future growth without requiring major rewrites.

---

# Lifecycle

All major systems follow a two-phase lifecycle.

## Initialize Phase

Purpose:

Prepare systems.

During Initialize:

- Create references.
- Load configurations.
- Prepare dependencies.
- Set up internal state.

Gameplay should not begin during this phase.

---

## Start Phase

Purpose:

Activate systems.

During Start:

- Connect events.
- Begin loops.
- Enable gameplay behavior.
- Allow systems to interact.

---

# System Loading Order

The loading order is:

1. Bootstrap
2. Core systems
3. Managers
4. Services
5. Controllers

Bootstrap starts the engine.

Core prepares the framework.

Managers prepare world systems.

Services enable gameplay.

Controllers handle player/client behavior.

---

# Bootstrap

Location:

ServerScriptService/Bootstrap

Main file:

Main.server.lua

Responsibilities:

- Start CrystalEngine.
- Load required systems.
- Begin initialization.
- Begin startup sequence.

Bootstrap should contain minimal logic.

It should only start the engine.

---

# Services

Services contain gameplay systems.

Examples:

- MiningService
- InventoryService
- CraftingService
- EquipmentService
- MissionService
- CrystalService
- PlayerDataService

A service should:

- Own its gameplay logic.
- Expose clear methods.
- Communicate with other systems through defined interfaces.

A service should not control unrelated systems.

---

# Service Structure

Standard format:

local Service = {}

Service.Name = "ExampleService"

function Service:Initialize()

end

function Service:Start()

end

return Service

---

# Dependencies

Systems should declare dependencies explicitly.

Example:

Service.Dependencies = {
    "PlayerDataService"
}

The engine should load dependencies before starting dependent systems.

Circular dependencies should produce warnings or errors.

---

# Managers

Managers control collections and world objects.

Examples:

- OreManager
- WorldManager
- SpawnManager
- NPCManager

Managers are responsible for organization and control of objects.

They should not contain unrelated gameplay logic.

---

# Logger

CrystalEngine contains a centralized Logger system.

Logger provides:

- Info messages
- Warning messages
- Error messages
- Debug messages

Example:

Logger.Info("MiningService started")

The Logger exists to:

- Improve debugging.
- Standardize output.
- Make errors easier to track.

---

# Client Architecture

Crystalbound will have a client-side equivalent.

Future structure:

ClientEngine

Controllers

Shared modules

The client engine will follow similar principles:

- Initialize
- Start
- Load controllers
- Manage client systems

---

# Configuration

CrystalEngine supports configuration-driven design.

Gameplay values should exist outside code.

Examples:

- Drop rates
- Item statistics
- Equipment values
- Crystal rarity

Configuration should contain data only.

---

# Communication

Preferred communication flow:

Client

↓

Remote

↓

Service

↓

Manager / Data

↓

Response

↓

Client Update

The server remains authoritative.

---

# Error Handling

Systems should fail safely.

The engine should:

- Provide useful warnings.
- Avoid silent failures.
- Prevent cascading errors where possible.

---

# Performance Goals

CrystalEngine should prioritize:

- Efficient loading.
- Minimal unnecessary loops.
- Clean memory management.
- Scalable systems.

---

# Definition of Done

CrystalEngine Foundation is complete when:

- Bootstrap starts successfully.
- Core systems load.
- Services can initialize.
- Managers can initialize.
- Logger works.
- Dependencies resolve correctly.
- Client architecture can be expanded later.

---

# Final Rule

CrystalEngine is the foundation of Crystalbound.

Do not add gameplay into the engine.

Keep the engine clean, modular, and reusable.