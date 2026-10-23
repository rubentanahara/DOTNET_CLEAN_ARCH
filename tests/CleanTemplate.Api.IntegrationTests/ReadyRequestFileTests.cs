namespace CleanTemplate.Api.IntegrationTests;

public class ReadyRequestFileTests
{
    private const string RelativePath = "requests/Ready/Ready.http";

    [Fact]
    public void ReadyHttp_DeclaresHost()
    {
        ReadLines().ShouldContain("@host = http://localhost:5001");
    }

    [Fact]
    public void ReadyHttp_HoldsGetHealthRequest()
    {
        ReadLines().ShouldContain("GET {{host}}/health");
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