namespace CleanTemplate.Api.IntegrationTests;

public class SwaggerRequestFileTests
{
    private const string RelativePath = "requests/Swagger/Swagger.http";

    [Fact]
    public void SwaggerHttp_DeclaresHost()
    {
        ReadLines().ShouldContain("@host = http://localhost:5001");
    }

    [Fact]
    public void SwaggerHttp_HoldsGetSwaggerIndexRequest()
    {
        ReadLines().ShouldContain("GET {{host}}/swagger/index.html");
    }

    private static string[] ReadLines()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, RelativePath)))
        {
            directory = directory.Parent;
        }

        directory.ShouldNotBeNull($"{RelativePath} not found above {AppContext.BaseDirectory}");
        return File.ReadAllLines(Path.Combine(directory.FullName, RelativePath))
            .Select(line => line.Trim())
            .ToArray();
    }
}