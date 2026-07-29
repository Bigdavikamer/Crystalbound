# Crystalbound - Architecture

## Overview

Crystalbound uses a modular service-oriented architecture designed for scalability, maintainability, and collaboration.

The project is organized around clear responsibilities:

- Services handle gameplay systems.
- Managers control collections of objects and world systems.
- Controllers handle player/client behavior.
- Shared modules contain reusable code.
- Configurations contain editable data.

Each system should only be responsible for its intended purpose.

---

# Project Structure

Crystalbound uses Rojo to synchronize the local repository with Roblox Studio.

Main structure:

src/

├── Workspace
├── ReplicatedStorage
├── ServerScriptService
├── ServerStorage
├── StarterGui
└── StarterPlayer

These folders mirror Roblox services.

---

# Server Architecture

Location:

src/ServerScriptService

---

## Bootstrap

Purpose:

Starts the CrystalEngine.

Responsibilities:

- Initialize the game framework.
- Load required systems.
- Start services and managers.

Example:

Bootstrap/
└── Main.server.lua

---

## Core

Purpose:

Contains the foundation of CrystalEngine.

Core systems include:

- Service loading
- Manager loading
- Dependency management
- Logging
- Internal utilities

Core should not contain gameplay logic.

Example:

Core/

- ServiceLoader
- ManagerLoader
- DependencyResolver
- Logger

---

## Services

Purpose:

Contains the main gameplay systems.

Examples:

- MiningService
- InventoryService
- CraftingService
- CrystalService
- MissionService
- EquipmentService
- PlayerDataService

Services:

- Handle gameplay logic.
- Communicate with other systems.
- Manage player interactions.

Services should not directly control unrelated systems.

---

## Managers

Purpose:

Controls groups of objects and world systems.

Examples:

- OreManager
- NPCManager
- SpawnManager
- WorldManager

Managers organize and control collections of things.

Example:

OreManager controls all mineable resource nodes.

---

## Controllers

Purpose:

Handles additional server controllers when necessary.

Controllers should not replace Services.

---

# ReplicatedStorage Architecture

Location:

src/ReplicatedStorage

Contains content shared between server and client.

---

## Assets

Contains shared assets.

Examples:

- Icons
- Effects
- Animations
- Shared models

---

## Config

Contains editable data.

Examples:

- Drop rates
- Item values
- Crystal rarity
- Equipment statistics
- Mission rewards

Config files store data only.

They should not contain gameplay logic.

---

## Modules

Contains reusable modules.

Examples:

- Utility functions
- Calculations
- Helpers

---

## Packages

Contains external libraries and dependencies.

---

## Remotes

Handles communication between client and server.

Structure:

Remotes/

- Events
- Functions

Events:
One-way communication.

Functions:
Request and response communication.

---

## Shared

Contains code usable by both server and client.

Structure:

Shared/

- Constants
- Types
- Utilities

---

## UI

Contains shared interface resources.

---

# ServerStorage Architecture

Location:

src/ServerStorage

Contains server-only content.

Players cannot directly access this.

Examples:

- Maps
- Resource templates
- Equipment models
- NPC templates
- Crystal objects

---

# Client Architecture

Location:

src/StarterPlayer

Client-side systems are stored here.

Structure:

StarterPlayerScripts/

└── Controllers

Examples:

- UIController
- InputController
- CameraController
- SoundController

---

# Workspace Architecture

Location:

src/Workspace

Contains active game world objects.

Structure:

Workspace/

- Map
- Ores
- NPCs
- Interactables
- Dynamic
- Effects
- SpawnLocations
- Ignore

Workspace contains things currently active in the world.

---

# Communication Flow

Preferred system communication:

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

---

# Development Rules

Before creating a new system:

1. Decide its responsibility.
2. Place it in the correct folder.
3. Avoid duplicate systems.
4. Keep code modular.
5. Prefer reusable solutions.

---

# Golden Rule

Crystalbound must remain modular and organized.

Any developer should be able to understand where code belongs without searching through unrelated scripts.