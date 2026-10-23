using System.Reflection;

using Carter;

using CleanTemplate.Contracts.Version;

namespace CleanTemplate.Api.Features.Version;

public class VersionModule : ICarterModule
{
    private static readonly VersionResponse RunningVersion = new(
        typeof(VersionModule).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? string.Empty);

    public void AddRoutes(IEndpointRouteBuilder app)
    {
        app.MapGet("/version", () => RunningVersion);
    }
}