# Architecture

Read this before you add, move or rename code, or when a build or architecture test fails on a reference.
For the step-by-step recipe of a new slice, read `docs/agents/add-feature.md`. Notes is the reference slice.

## Layers
| Project | Holds | May reference |
|---|---|---|
| `src/CleanTemplate.Domain` | Entities, `ErrorOr` errors, domain events, under `Models/<Feature>/` | nothing |
| `src/CleanTemplate.Contracts` | HTTP request and response records, under `<Feature>/` | nothing |
| `src/CleanTemplate.Application` | Commands, queries, handlers, repository interfaces, under `Features/<Feature>/`; messaging under `Common/Messaging/` | Domain |
| `src/CleanTemplate.Infrastructure` | Dapper repositories under `Dapper/<Feature>/`, persistence under `Common/Persistence/` | Application |
| `src/CleanTemplate.Api` | Carter modules under `Features/<Feature>/`, `Program.cs`, DI wiring | Application, Infrastructure, Contracts |
| `tests/` | Integration, unit and architecture tests, see Tests below | |

## Request flow
1. A Carter module in `Api/Features/<Feature>/` maps the route inside one `MapGroup("/<route>")` and sends a command or query through `ISender`.
2. `Sender` resolves the one `IRequestHandler<TRequest, TResponse>` for it. The handler validates, calls the repository interface and returns `ErrorOr<T>`.
3. The Dapper repository in Infrastructure runs the SQL and returns domain entities.
4. The handler calls `IPublisher.Publish(entity)`. It sends each domain event the entity raised to every `IDomainEventHandler<TEvent>`, then clears the events.
5. A module whose use case returns `ErrorOr` maps it with `MatchFirst`, as `NotesModule` does: success to 200, 201 or 204; `ErrorType.NotFound` to 404; `ErrorType.Validation` to 400 (`NotesModule.Problem`). New modules copy that mapping. An unhandled exception becomes a 500 problem response through `UseExceptionHandler` and `AddProblemDetails`.

## Composition
- `Program.cs` adds Serilog, then `AddPresentation()` (Carter, Swagger, problem details), `AddApplication()` and `AddInfrastructure()`, and maps the Carter modules and `/health`.
- Handlers and domain event handlers register themselves by reflection in `src/CleanTemplate.Application/DependencyInjection.cs`. Do not add them to DI by hand.
- Repositories are registered by hand in `src/CleanTemplate.Infrastructure/DependencyInjection.cs`.
- Carter finds modules on its own.

## Persistence
- One shared SQLite connection, `Data Source=:memory:`, opened at startup. All data is lost when the process stops.
- The schema lives in `src/CleanTemplate.Infrastructure/Common/Persistence/DatabaseInitializer.cs`: a `DROP TABLE IF EXISTS` and a `CREATE TABLE` per table, plus its indexes. Integration tests reset the database through it with `factory.ResetDatabase()`.
- Repositories use Dapper with `CommandDefinition` and the cancellation token. `AppDbContext` (EF Core) is registered on the same connection, but no repository uses it.
- `/health` runs `DatabaseHealthCheck`.

## Conventions
- Expected failures are returned as `ErrorOr<T>`, not thrown, and mapped to HTTP status codes in the Carter module.
- Commands, queries, events and DTOs are `sealed record`s. Services use primary constructors.
- Entities are `sealed` classes that inherit `Entity`, with a private constructor, static factories that raise the domain events, and `Rehydrate(...)` for loading without events.
- Contracts hold no domain types. Mapping between them is written by hand in the module.
- C# files use CRLF and no final newline. Files you create are usually LF: run `make format` after creating them.
- StyleCop and Sonar analyzers run in every build, and warnings are errors.

## Tests
| Project | Seam | Tools |
|---|---|---|
| `tests/CleanTemplate.Api.IntegrationTests` | HTTP, through `WebAppFactory` with `[Collection(WebAppFactoryCollection.CollectionName)]`. Every acceptance criterion is tested here. | xUnit, Shouldly |
| `tests/CleanTemplate.Application.UnitTests` | Handlers and entities, for logic that is awkward to reach over HTTP | xUnit, Shouldly, NSubstitute for repositories |
| `tests/CleanTemplate.ArchitectureTests` | The reference column of the Layers table | NetArchTest |
| `tests/TestCommon` | Helpers shared by the test projects | |

How to write them: the `tdd` skill.

## Rules, their reasons and when they can go
| Rule | Why | Enforced by | Remove when |
|---|---|---|---|
| References follow the Layers table | Domain and Application stay free of web and database code, so they test without either | `tests/CleanTemplate.ArchitectureTests/LayerDependencyTests.cs` in `make check`. If it fails, move the code, not the rule. | never |
| Namespaces match folders | Types are found by path | IDE0130 fails the build | never |
| One folder per feature in each layer | A story owns its folders, so the runner can build stories in parallel (`docs/agents/backlog.md`) | `feature.sh waves` and `done` through each story's `owns` | never |
| No MediatR, AutoMapper or EF migrations | Hard rule 6 in `AGENTS.md` | review | the template drops the rule |
| `DatabaseInitializer.cs` and `Infrastructure/DependencyInjection.cs` are edited by every slice | Schema and repository registration are central | listed in `shared` in `feature_list.json`; they conflict on merge (`docs/agents/harness.md` section 4) | schema and registration move per feature, after a decision record |
| In-memory SQLite | Nothing external is needed to build, test or run | `DependencyInjection.cs` | a real database is chosen (blocks deploy, `docs/agents/harness.md` section 6) |