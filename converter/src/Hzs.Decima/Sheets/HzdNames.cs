using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hzs.Generated;

namespace Hzs.Decima.Sheets;

/// <summary>
/// Typed access to sheets/hzd_content.json (HZD paths and names; D32: none of them are literals in code).
/// String cells arrive as the raw string, other cells as JSON text.
/// </summary>
public static class HzdNames
{
    private static readonly Dictionary<string, string> Values =
        HzdContentSheet.All.ToDictionary(r => r.Id, r => r.Value, StringComparer.Ordinal);

    private static string Raw(string id) =>
        Values.TryGetValue(id, out var v) ? v : throw new KeyNotFoundException($"sheet hzd_content has no row '{id}'");

    public static string Str(string id) => Raw(id);

    public static double Num(string id) => double.Parse(Raw(id), CultureInfo.InvariantCulture);

    public static int Int(string id) => (int)Num(id);

    public static string[] List(string id) => JsonSerializer.Deserialize<string[]>(Raw(id)) ?? [];

    public static JsonNode Json(string id) => JsonNode.Parse(Raw(id)) ?? throw new InvalidDataException($"hzd_content {id} is empty");

    /// <summary>A path template with {name} placeholders filled from <paramref name="args"/> (name, value pairs).</summary>
    public static string Fill(string id, params (string Name, string Value)[] args)
    {
        var s = Raw(id);
        foreach (var (n, v) in args) s = s.Replace("{" + n + "}", v, StringComparison.Ordinal);
        return s;
    }

    /// <summary>Strips the stream data-source prefix ("cache:") from a location.</summary>
    public static string StripStream(string loc)
    {
        var p = Raw("archive.stream_prefix");
        return loc.StartsWith(p, StringComparison.Ordinal) ? loc[p.Length..] : loc;
    }
}
