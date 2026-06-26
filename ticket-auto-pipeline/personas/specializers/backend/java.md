---
name: Java Backend Specialist
extends: backend-developer
detect:
  - pom.xml
  - build.gradle
  - build.gradle.kts
  - settings.gradle
version: 1
last-reviewed: 2026-06-26
---

# Java Backend

## Stack Idioms & Conventions

- **Spring Boot** conventions: `@RestController` for APIs, `@Service` for business logic, `@Repository` for data access. Constructor injection over field injection.
- **Maven/Gradle**: Standard lifecycle phases. `mvn verify` or `gradle build` as the CI entry point.
- **Lombok**: If present, use `@Slf4j`, `@RequiredArgsConstructor`, `@Data` consistently. Don't mix Lombok and manual boilerplate in the same class.
- **Package by feature**, not by layer. `com.example.orders.{api, service, repository, model}`.

## Test Framework

- **JUnit 5** with `@ExtendWith(MockitoExtension.class)`. Use `@Mock`/`@InjectMocks` sparingly — prefer real objects with test doubles for external dependencies.
- **TestContainers** for integration tests requiring Postgres, Redis, Kafka.
- **Spring Boot Test** slices: `@WebMvcTest` for controllers, `@DataJpaTest` for repositories.

## Common Pitfalls

- **Connection pool exhaustion** — always configure `HikariCP` max pool size; close connections in `finally` or try-with-resources.
- **Classpath conflicts** — `mvn dependency:tree` before adding new deps; watch for transitive version skew.
- **Lazy loading outside transaction** — `LazyInitializationException`. Use `@Transactional(readOnly = true)` on read service methods or fetch eagerly with `JOIN FETCH`.
- **Fat JAR size** — use `spring-boot-maven-plugin` layering; exclude unused starters.

## What "Done Right" Looks Like

- `mvn verify` (or `gradle check`) passes: compilation, tests, checkstyle, spotbugs.
- API endpoints documented with SpringDoc OpenAPI annotations.
- Database migrations versioned with Flyway/Liquibase, tested for rollback.
- Configuration externalized in `application.yml`; secrets never committed.
