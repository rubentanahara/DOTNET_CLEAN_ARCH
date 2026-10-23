using CleanTemplate.Contracts.Notes;

namespace CleanTemplate.Api.IntegrationTests;

[Collection(WebAppFactoryCollection.CollectionName)]
public class NotesEndpointTests(WebAppFactory factory)
{
    [Fact]
    public async Task Crud_RoundTrip_Succeeds()
    {
        factory.ResetDatabase();
        var client = factory.CreateClient();

        var createResponse = await client.PostAsJsonAsync("/notes", new CreateNoteRequest("groceries", "milk"));
        createResponse.StatusCode.ShouldBe(HttpStatusCode.Created);

        var created = await createResponse.Content.ReadFromJsonAsync<NoteResponse>();
        created.ShouldNotBeNull();
        created.Title.ShouldBe("groceries");

        var fetched = await client.GetFromJsonAsync<NoteResponse>($"/notes/{created.Id}");
        fetched.ShouldNotBeNull();
        fetched.Content.ShouldBe("milk");

        var listed = await client.GetFromJsonAsync<List<NoteResponse>>("/notes");
        listed.ShouldNotBeNull();
        listed.ShouldHaveSingleItem().Id.ShouldBe(created.Id);

        var updateResponse = await client.PutAsJsonAsync($"/notes/{created.Id}", new UpdateNoteRequest("errands", "bread"));
        updateResponse.StatusCode.ShouldBe(HttpStatusCode.OK);

        var updated = await updateResponse.Content.ReadFromJsonAsync<NoteResponse>();
        updated.ShouldNotBeNull();
        updated.Title.ShouldBe("errands");
        updated.Content.ShouldBe("bread");

        var deleteResponse = await client.DeleteAsync($"/notes/{created.Id}");
        deleteResponse.StatusCode.ShouldBe(HttpStatusCode.NoContent);

        var deletedResponse = await client.GetAsync($"/notes/{created.Id}");
        deletedResponse.StatusCode.ShouldBe(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task ResetDatabase_ClearsNotes()
    {
        var client = factory.CreateClient();
        await client.PostAsJsonAsync("/notes", new CreateNoteRequest("stale", "row"));

        factory.ResetDatabase();

        var listed = await client.GetFromJsonAsync<List<NoteResponse>>("/notes");
        listed.ShouldNotBeNull();
        listed.ShouldBeEmpty();
    }

    [Fact]
    public async Task Update_MissingNote_ReturnsNotFound()
    {
        var client = factory.CreateClient();

        var response = await client.PutAsJsonAsync("/notes/999999", new UpdateNoteRequest("gone", "gone"));

        response.StatusCode.ShouldBe(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task Create_BlankTitle_ReturnsBadRequest()
    {
        var client = factory.CreateClient();

        var response = await client.PostAsJsonAsync("/notes", new CreateNoteRequest("   ", "body"));

        response.StatusCode.ShouldBe(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Get_ExistingNote_ReturnsOk()
    {
        var client = factory.CreateClient();
        var created = await CreateNote(client);

        var response = await client.GetAsync($"/notes/{created.Id}");

        response.StatusCode.ShouldBe(HttpStatusCode.OK);
    }

    [Fact]
    public async Task List_ReturnsOk()
    {
        var client = factory.CreateClient();

        var response = await client.GetAsync("/notes");

        response.StatusCode.ShouldBe(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Update_BlankTitle_ReturnsBadRequest()
    {
        var client = factory.CreateClient();
        var created = await CreateNote(client);

        var response = await client.PutAsJsonAsync($"/notes/{created.Id}", new UpdateNoteRequest("   ", "body"));

        response.StatusCode.ShouldBe(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task Delete_MissingNote_ReturnsNotFound()
    {
        var client = factory.CreateClient();

        var response = await client.DeleteAsync("/notes/999999");

        response.StatusCode.ShouldBe(HttpStatusCode.NotFound);
    }

    private static async Task<NoteResponse> CreateNote(HttpClient client)
    {
        var response = await client.PostAsJsonAsync("/notes", new CreateNoteRequest("title", "content"));
        var note = await response.Content.ReadFromJsonAsync<NoteResponse>();
        note.ShouldNotBeNull();
        return note;
    }
}