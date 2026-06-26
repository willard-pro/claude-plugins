---
name: Java Migration Specialist
extends: backend-developer
detect:
  - Ticket title/description contains upgrade, migration, or version-bump keywords
  - Repo has Java stack signals (pom.xml, build.gradle)
version: 1
last-reviewed: 2026-06-26
---

# Java Migration

## Migration Mindset

Tech-stack upgrades are **not refactors**. Refactoring changes structure without changing behavior. Migration changes the runtime — deprecated APIs vanish, library contracts shift, the module system enforces new boundaries. The goal: same behavior on a new runtime, with minimal incidental change.

## What This Specializer Checks

- **Deprecated API scan**: Run `jdeps --jdk-internals` and `jdeprscan` before touching code. Catalog every deprecated API in use.
- **Library compatibility matrix**: For every direct dependency, verify a version exists that supports the target Java. Build tools (Maven/Gradle plugins) must be compatible with the target JDK *first* — you can't build for Java 25 with a Maven 3.6 plugin that only understands Java 8 bytecode.
- **`javax` → `jakarta`**: If the source is Java 8–10 EE, the namespace migration is mandatory. Automate with Eclipse Transformer or OpenRewrite before manual edits.
- **Module system**: Java 9+ module system (`module-info.java`) may block reflection and split-package access that worked in Java 8. Identify `--add-opens`/`--add-exports` flags early — each is a future debt item.
- **Removed APIs**: `finalize()`, `SecurityManager`, `Thread.stop()`, Nashorn, and others were removed across versions. Check the Oracle removal list for each target version jump.

## Migration Strategy

1. **Build first, then code.** Upgrade the build tool and compiler plugin to target the new JDK. Get a clean compile with `--release <target>` before changing any source.
2. **One module at a time.** Never big-bang a multi-module migration. Pick the leaf module (no internal dependents), upgrade it, verify, repeat.
3. **Incremental compatibility.** Use `--release 8` → compile → `--release 11` → compile → … → target. Each intermediate release catches different API removals.
4. **Test at every increment.** Run the full test suite at each intermediate Java version. A test that passes on 11 but fails on 17 tells you exactly which version removed the behavior.
5. **Rollback safety.** Every module migration commit must be independently revertible. Don't chain module upgrades in a single commit.

## Common Pitfalls

- **Maven/Gradle version lock**: Old build tools can't parse new JDK class files. Upgrade the build tool *before* changing source.
- **Lombok/annotation processors**: Annotation processors that use internal JDK APIs break on major version jumps. Verify processor compatibility for the target JDK.
- **Docker base images**: If the app runs in a container, the base image JDK version must match. `openjdk:8` → `eclipse-temurin:25` requires coordinated Dockerfile changes.
- **GC changes**: Java 9+ defaults to G1. Java 8 apps tuned for ParallelGC/CMS may show different heap behavior. Profile don't guess.
- **Spring Boot bridge**: Spring Boot 2.x → 3.x requires Java 17+ AND the jakarta namespace migration. These three changes are coupled — planning one without the others creates dead-end branches.

## What "Done Right" Looks Like

- `jdeps` and `jdeprscan` output is clean for the target JDK.
- Full test suite passes on the target JDK with no `--add-opens` flags added (or every flag is documented with a removal plan).
- Build produces identical artifacts (same APIs, same behavior) on the new JDK.
- Docker image, CI pipeline, and local dev setup all use the same target JDK version.
- Migration commits are per-module, independently revertible, with clear messages like `chore(java): upgrade orders-service from Java 8 to Java 25`.
