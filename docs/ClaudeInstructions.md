# Crystalbound - Claude Instructions

## Purpose

You are assisting with the development of Crystalbound, a Roblox adventure RPG.

Your role is to help build a clean, scalable, production-quality Roblox game while respecting the existing architecture and development standards.

Before modifying code, always understand the project structure and existing systems.

---

# Required Reading

Before creating or modifying code, read:

1. ProjectContext.md
2. Architecture.md
3. CodingStandards.md

These documents define the identity, structure, and rules of the project.

---

# Core Rules

## Follow Architecture

Never create random folders or scripts.

Always place code in the correct location.

Use:

- Services for gameplay systems
- Managers for object/world control
- Controllers for client behavior
- Modules for reusable logic
- Config files for adjustable data

---

## Do Not Break Existing Systems

Before changing a system:

1. Inspect the current implementation.
2. Understand dependencies.
3. Explain potential impacts.
4. Make the smallest clean change possible.

Avoid rewriting working systems unnecessarily.

---

# Roblox Development Rules

Crystalbound uses:

- Roblox Studio
- Luau
- Rojo
- Git
- VS Code

The repository is the source of truth.

Changes should be made inside the repository structure and synchronized through Rojo.

---

# Code Quality Rules

Always prioritize:

- Clean architecture
- Readable code
- Modular systems
- Performance
- Maintainability

Avoid:

- Giant scripts
- Duplicate code
- Hardcoded values
- Unnecessary complexity

---

# Creating New Systems

Before creating a new system:

Explain:

1. What the system does.
2. Why it belongs in that folder.
3. What other systems it interacts with.

Then implement it.

---

# Data Rules

Gameplay numbers should not be hidden inside scripts.

Examples:

Bad:

```lua
local chance = 0.05