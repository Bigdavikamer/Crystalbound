# Crystalbound - Claude Instructions

## Purpose

You are assisting with the development of Crystalbound, a Roblox adventure RPG.

Your goal is to help create a clean, scalable, production-quality Roblox game while respecting the project architecture and standards.

Never write code before understanding the existing systems.

---

# Required Reading

Before creating or modifying anything, read:

- docs/ProjectContext.md
- docs/Architecture.md
- docs/CodingStandards.md
- docs/ClaudeInstructions.md

These documents define the project rules.

---

# Architecture Rules

Never create random folders or scripts.

Use the correct layer:

Services:
Gameplay systems.

Managers:
World objects and collections.

Controllers:
Client behavior.

Modules:
Reusable logic.

Config:
Adjustable data only.

Core:
Engine foundation only. No gameplay logic.

---

# Development Rules

The repository is the source of truth.

Use:

- Roblox Studio
- Luau
- Rojo
- Git
- VS Code

Make changes inside the repository and synchronize through Rojo.

Do not make the Studio place file the main source of code.

---

# Code Quality Rules

Prioritize:

- Clean architecture
- Readability
- Modularity
- Performance
- Maintainability

Avoid:

- Giant scripts
- Duplicate systems
- Random folders
- Hardcoded gameplay values
- Unnecessary complexity

---

# New System Process

Before creating a new system, explain:

1. What it does.
2. Where it belongs.
3. What systems it interacts with.

Only implement after the plan is understood.

---

# Data Rules

Gameplay values must be stored in Config modules.

Examples:

- Drop rates
- Crystal rarity
- Item values
- Equipment stats
- Mission rewards

Do not hide important balancing values inside gameplay scripts.

---

# Security Rules

Never trust the client.

The server controls:

- Rewards
- Currency
- Items
- Drops
- Progression
- Crafting results

The client only requests actions.

---

# Communication Rules

When making changes, always explain:

- What changed.
- Which files changed.
- Why the change was needed.
- Any risks or testing required.

---

# Git Rules

Recommend commits before major changes.

Use clear commit messages.

Examples:

- Add CrystalEngine bootstrap system
- Implement mining foundation
- Create inventory framework

---

# Workflow

Follow this order:

1. Understand the request.
2. Inspect existing code.
3. Explain the approach.
4. Implement.
5. Test.
6. Summarize.

Do not rush implementation.

---

# Design Philosophy

Crystalbound should be:

- Rewarding
- Fair
- Discoverable
- Expandable

Core loop:

Explore → Mine → Discover → Upgrade → Progress

Every feature should strengthen this loop.

---

# Final Rule

Quality is more important than speed.

Build Crystalbound as a long-term Roblox project with a clean and scalable foundation.