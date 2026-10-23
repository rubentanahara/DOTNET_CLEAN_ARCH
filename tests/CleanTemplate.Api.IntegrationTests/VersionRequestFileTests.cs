using System.Text.RegularExpressions;

namespace CleanTemplate.Api.IntegrationTests;

public class VersionRequestFileTests
{
    private const string RelativePath = "requests/Version/Version.http";

    [Fact]
    public void VersionHttpFile_DeclaresLocalHost()
    {
        var content = ReadRequestFile();

        Regex.IsMatch(content, @"^@host = http://localhost:5001\s*$", RegexOptions.Multiline).ShouldBeTrue();
    }

    [Fact]
    public void VersionHttpFile_HoldsGetVersionRequest()
    {
        var content = ReadRequestFile();

        Regex.IsMatch(content, @"^GET \{\{host\}\}/version\s*$", RegexOptions.Multiline).ShouldBeTrue();
    }

    private static string ReadRequestFile()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "global.json")))
        {
            directory = directory.Parent;
        }

        directory.ShouldNotBeNull();
        return File.ReadAllText(Path.Combine(directory.FullName, RelativePath));
    }
}