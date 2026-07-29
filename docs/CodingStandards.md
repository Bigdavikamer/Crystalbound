# Crystalbound - Coding Standards

## Overview

Crystalbound follows clean, modular, and maintainable coding practices.

All code should prioritize:

- Readability
- Scalability
- Performance
- Reusability
- Clear responsibility

Code should be understandable by future developers.

---

# Luau Style Rules

Crystalbound uses Roblox Luau.

Code should follow Roblox recommended practices.

---

# Naming Conventions

## Files

Use PascalCase.

Examples:

MiningService.lua
InventoryManager.lua
CrystalConfig.lua

---

## Services

Services must end with:

Service

Examples:

MiningService
CraftingService
InventoryService

---

## Managers

Managers must end with:

Manager

Examples:

OreManager
WorldManager
SpawnManager

---

## Controllers

Controllers must end with:

Controller

Examples:

UIController
InputController
CameraController

---

## Functions

Use camelCase.

Examples:

calculateDropChance()

updateInventory()

spawnOre()

---

## Variables

Use camelCase.

Examples:

playerData

crystalAmount

currentWorld

---

# Module Structure

Modules should follow this pattern:

```lua
local Module = {}

function Module.Initialize()

end

function Module.Start()

end

return Module