---
name: tdd
description: Test-driven development for this .NET repo. One acceptance criterion at a time, a failing xUnit test at the HTTP seam first, then the least code that passes it. Use when building a story, fixing a bug test-first, or when asked for red-green-refactor or integration tests.
---

# Test-driven development

The red to green loop, applied to this repo. The goal is tests that state behavior, survive refactors, and prove each acceptance criterion.

## Seams: where tests go
A seam is the public boundary where behavior is observed. Test there, never against internals.

| Seam | Test project | Use for |
|---|---|---|
| HTTP endpoint | `tests/CleanTemplate.Api.IntegrationTests`, through `WebAppFactory` | Every acceptance criterion. This is the default. |
| Handler | `tests/CleanTemplate.Application.UnitTests/Features/<Feature>/`, repository substituted with NSubstitute | Branching logic that is slow or awkward to reach over HTTP |
| Entity | the same unit test project | Rules inside a domain entity: state transitions, invariants |

When working a story, the seams are already agreed: each acceptance criterion gets at least one test at the HTTP seam, in the class the story's `test_filter` selects. Outside a story, agree the seams with the user before writing tests.

## The loop
For each acceptance criterion, in order:
1. **Red.** Write one test for the criterion. Add only the types it needs to compile, so it fails on its assertion, not on the build. Run it alone and read the failure:
   `dotnet test --filter "FullyQualifiedName~<Class>.<Method>"`
   A test that passes before the change proves nothing. Fix the test until it fails for the reason the criterion states.
2. **Green.** Write the least code that makes it pass, following `docs/agents/add-feature.md` and the Notes slice. Do not build ahead for a later criterion.
3. Run the story's whole filter so earlier criteria stay green. Then take the next criterion.

After the last criterion: `make format`, then `make check`. Refactoring belongs after `make check` passes, never inside the loop.

## What a good test looks like here
```csharp
[Fact]
public async Task Submit_AlreadySubmitted_ReturnsConflict()
{
    factory.ResetDatabase();
    var client = factory.CreateClient();
    var draft = await CreateDraft(client);
    await client.PostAsync($"/achievements/{draft.Id}/submit", null);

    var response = await client.PostAsync($"/achievements/{draft.Id}/submit", null);

    response.StatusCode.ShouldBe(HttpStatusCode.Conflict);
}
```
- Name: `Action_Condition_Result`, as in `Update_MissingNote_ReturnsNotFound`. The name reads as the criterion.
- One behavior per test. Arrange, act and assert are separated by blank lines.
- Assert with Shouldly. Expected values come from the criterion or a literal, never recomputed the way the code computes them.
- The class has `[Collection(WebAppFactoryCollection.CollectionName)]`. Call `factory.ResetDatabase()` when the test needs empty tables.

## Anti-patterns
- **Implementation-coupled:** querying the database to check a write, asserting how often a substitute was called, testing private methods. Check through the API instead: create, then `GET`.
- **Tautological:** the expected value is computed the same way as the code, so the test can never disagree with it.
- **Horizontal slicing:** writing every test first and then all the code. Work one criterion at a time; each test responds to what the last cycle taught you.
- **Changing a test to make it pass.** `AGENTS.md` forbids it. Change a test only when the requirement changed, and say so.

## Substitutes
Substitute only boundaries: the repository interface in handler tests, `TimeProvider` for time, and external services. Never substitute your own handlers, entities or `ISender`.
