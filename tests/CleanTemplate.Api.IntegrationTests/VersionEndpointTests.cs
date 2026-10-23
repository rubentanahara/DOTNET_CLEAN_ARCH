using System.Reflection;

using CleanTemplate.Contracts.Version;

namespace CleanTemplate.Api.IntegrationTests;

[Collection(WebAppFactoryCollection.CollectionName)]
public class VersionEndpointTests(WebAppFactory factory)
{
    [Fact]
    public async Task Get_Anonymous_ReturnsApiInformationalVersion()
    {
        var expected = typeof(Program).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            .ShouldNotBeNull()
            .InformationalVersion;
        var client = factory.CreateClient();

        var response = await client.GetAsync("/version");

        response.StatusCode.ShouldBe(HttpStatusCode.OK);
        var body = await response.Content.ReadFromJsonAsync<VersionResponse>();
        body.ShouldNotBeNull().Version.ShouldBe(expected);
    }

    [Fact]
    public async Task Get_Version_ReturnsJsonContentType()
    {
        var client = factory.CreateClient();

        var response = await client.GetAsync("/version");

        response.Content.Headers.ContentType.ShouldNotBeNull().MediaType.ShouldBe("application/json");
    }
}