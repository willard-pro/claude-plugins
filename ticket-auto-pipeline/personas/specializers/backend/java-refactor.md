---
name: Java Refactor Specialist
extends: backend/java
detect:
  - Ticket title/description contains refactor or restructuring keywords
  - Repo has Java stack signals (pom.xml, build.gradle)
---

# Java Refactor

## Refactor Mindset

Refactoring changes structure without changing observable behavior. No new features. No API changes. No behavior differences. The test suite is the contract — if tests pass unchanged, the refactor is safe. If tests need updating, you're either fixing a test bug or you're not refactoring.

## What This Specializer Checks

- **Behavior preservation**: Every existing test must pass with zero modification. If a test fails after the refactor, the refactor changed behavior — revert and isolate.
- **Structure improvement**: Extract duplicated logic into shared methods/classes. Flatten deep conditionals. Replace magic numbers with named constants. Move inner classes to top-level when they've outgrown their parent.
- **Interface segregation**: Split fat interfaces into role-specific ones. Clients should not depend on methods they don't call.
- **Dependency inversion**: Depend on abstractions, not concretions. Inject collaborators rather than instantiating them.
- **Naming**: Names should reveal intent. Rename when the current name misleads. Follow existing project conventions (camelCase, PascalCase, prefix conventions).

## Refactor Patterns (Java)

- **Extract Method**: Long methods (>30 lines) → smaller, named methods. Each method does one thing.
- **Extract Class**: God classes (>300 lines, >10 responsibilities) → focused classes with single responsibilities.
- **Replace Conditional with Polymorphism**: Switch-on-type or if-instanceof chains → override methods in subclasses.
- **Introduce Parameter Object**: Methods with >3 parameters → parameter object grouping related values.
- **Replace Constructor with Factory Method**: Complex object construction → factory method or builder pattern.
- **Eliminate Dead Code**: Unused imports, unreachable branches, methods never called. `jdeprscan` for deprecated API usage.

## Safety Rules

1. **Test suite is the contract.** Run `mvn test` (or `gradle test`) before and after. Same pass/fail count.
2. **One refactor per commit.** Don't mix extract-method + rename + restructure in one commit. Bisectable history.
3. **No business logic changes.** If you find a bug during refactoring, note it — don't fix it here. Separate PR.
4. **Static analysis baseline.** Run Checkstyle/SpotBugs/PMD before starting. Don't make pre-existing warnings worse. Fixing them is a separate task.
5. **No new dependencies.** Refactoring doesn't add libraries. If you need one to do the refactor cleaner, question whether it's really a refactor.

## Common Pitfalls

- **Refactor + feature creep**: "While I'm here, I'll add validation" → not a refactor. Create a separate ticket.
- **Over-abstraction**: Extracting three-line methods that are called once. Readability through indirection is not readability.
- **Lombok migration**: Replacing manual getters/setters with Lombok annotations changes bytecode (constructor order, equals/hashCode semantics). Verify with `delombok` before committing.
- **Spring component scanning**: Renaming or repackaging `@Component`/`@Service` classes changes the scan path. Verify the application context loads after refactor.

## What "Done Right" Looks Like

- `mvn verify` (or `gradle check`) passes with identical results pre- and post-refactor.
- `git diff --stat` shows more deletions than additions (good refactors reduce code).
- Cyclomatic complexity decreased, not increased.
- PR description lists each refactor pattern applied and the files affected, with a clear "no behavior changes" statement.
