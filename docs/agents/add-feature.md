# Adding a feature slice

Read this before adding an endpoint, entity, or use case.
Notes is the reference slice: open the matching Notes file at each step and copy its shape.
Work inside out, and make each layer build before starting the next.

## 0. Before coding
- `scripts/agent/feature.sh add <id> "<behavior>" "FullyQualifiedName~<Feature>EndpointTests"`, then `scripts/agent/feature.sh start <id>`.

## 1. Domain: `src/CleanTemplate.Domain/Models/<Feature>/`
- `<Entity>.cs`: a `sealed` class that inherits `Entity`, with a private constructor and static factories that call `Raise(...)` for each domain event. Add `Rehydrate(...)` for loading without events. Reference: `Note.cs`.
- `Errors/<Entity>Errors.cs`: `Error.NotFound` and `Error.Validation` with codes such as `Note.NotFound`. Reference: `NoteErrors.cs`.
- `Events/<Entity><PastTense>.cs`: `sealed record ... : IDomainEvent`. Reference: `Events/NoteCreated.cs`.

## 2. Application: `src/CleanTemplate.Application/Features/<Feature>/`
- `I<Feature>Repository.cs`: only the operations the handlers need, returning domain entities. Reference: `INotesRepository.cs`.
- One record per use case: `sealed record <Verb><Entity>Command(...) : IRequest<ErrorOr<T>>`, or `...Query` for reads.
- One handler per use case: `sealed class <Name>Handler(...) : IRequestHandler<<Name>, ErrorOr<T>>`.
  Validate the input, call the repository, then `publisher.Publish(entity, cancellationToken)` to dispatch the entity's domain events.
  Reference: `CreateNoteCommandHandler.cs`.
- Side effects of domain events go in an `IDomainEventHandler<TEvent>`. Reference: `NoteEventLogger.cs`.
- Handlers register automatically. Do not add them to DI by hand.

## 3. Infrastructure: `src/CleanTemplate.Infrastructure/`
- Schema: add a `DROP TABLE IF EXISTS` and a `CREATE TABLE` to `Common/Persistence/DatabaseInitializer.cs`. Integration tests reset the database through it.
- `Dapper/<Feature>/<Feature>Repository.cs` implements the interface, using `CommandDefinition` with the cancellation token. Reference: `Dapper/Notes/NotesRepository.cs`.
- `Dapper/<Feature>/<Entity>Row.cs`: an `internal sealed record` matching the table columns.
- Register the repository in `DependencyInjection.cs`: `services.AddScoped<I<Feature>Repository, <Feature>Repository>();`.

## 4. Contracts: `src/CleanTemplate.Contracts/<Feature>/`
- `<Verb><Entity>Request` and `<Entity>Response` as `sealed record`s. No domain types here.

## 5. Api: `src/CleanTemplate.Api/Features/<Feature>/<Feature>Module.cs`
- Implement `ICarterModule`. Use one `MapGroup("/<route>")`, send commands and queries through `ISender`, and map results with `MatchFirst`.
- Map `ErrorType.NotFound` to 404 and `ErrorType.Validation` to 400, as `NotesModule.Problem` does. Carter finds modules automatically.

## 6. Tests
- Integration: `tests/CleanTemplate.Api.IntegrationTests/<Feature>EndpointTests.cs` with `[Collection(WebAppFactoryCollection.CollectionName)]`.
  Call `factory.ResetDatabase()` when a test needs empty tables. Cover the success path and each error the module maps. Reference: `NotesEndpointTests.cs`.
- Unit: handlers with real logic get tests under `tests/CleanTemplate.Application.UnitTests/Features/<Feature>/`, using NSubstitute for the repository.

## 7. Finish
- Add `requests/<Feature>/<Feature>.http` for manual calls.
- Run `make format`, then `make check`, then `scripts/agent/feature.sh done <id>`.
