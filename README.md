# Crystalbound Project Context

## Project Philosophy

Crystalbound is a commercial-quality Roblox adventure RPG built with long-term maintainability as the highest priority.

The project follows a service-oriented architecture.

Every feature must be modular, scalable, and independently replaceable.

Never sacrifice architecture for speed.

---

## Architecture

Player

↓

Controller

↓

Remote

↓

Service

↓

Manager

↓

Profile

↓

Save

---

## Rules

1. Never trust the client.

2. Never hardcode values.

3. Every configurable value belongs inside Config.

4. Every gameplay feature belongs inside its own Service.

5. Managers only manage world objects.

6. Controllers never contain gameplay logic.

7. Shared utilities belong inside ReplicatedStorage.

8. Use strict Luau typing.

9. Every module must have documentation.

10. Every service must be independently testable.

11. Never create circular dependencies.

12. Optimize for StreamingEnabled.

13. Optimize for mobile.

14. Explain architecture before code.

15. Produce production-quality Luau only.

---

## Folder Responsibilities

Services

Game logic.

Managers

World state.

Controllers

InputUI.

Config

Data only.

Shared

Utilities.

Modules

Reusable code.

---

## Coding Style

Readable.

Typed.

Documented.

Professional.

No shortcuts.

No monolithic scripts.
