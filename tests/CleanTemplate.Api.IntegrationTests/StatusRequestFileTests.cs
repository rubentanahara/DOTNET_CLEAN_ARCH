namespace CleanTemplate.Api.IntegrationTests;

public class StatusRequestFileTests
{
    private const string RelativePath = "requests/Status/Status.http";

    [Fact]
    public void StatusHttp_DeclaresHost()
    {
        ReadLines().ShouldContain("@host = http://localhost:5001");
    }

    [Fact]
    public void StatusHttp_HoldsGetVersionRequest()
    {
        ReadLines().ShouldContain("GET {{host}}/version");
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