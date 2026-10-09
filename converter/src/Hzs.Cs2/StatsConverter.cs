using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Generated;

namespace Hzs.Cs2;

/// <summary>
/// Writes cache/cs2/weapons.json and cache/cs2/systems.json: every cs2 binding of the sheets resolved to a value,
/// shaped {"&lt;row&gt;": {"&lt;column&gt;": value|null}, "_errors": [...]} (docs/ARCHITECTURE.md, sheet conventions).
/// </summary>
internal static class StatsConverter
{
    public static string SystemsJson(CachePaths cache) => Path.Combine(cache.Cs2, "systems.json");

    public static long Write(ConvContext ctx, JsonObject weapons, JsonObject systems)
    {
        Atomic.WriteJson(ctx.Cache.Cs2WeaponsJson, weapons);
        Atomic.WriteJson(SystemsJson(ctx.Cache), systems);
        return new FileInfo(ctx.Cache.Cs2WeaponsJson).Length + new FileInfo(SystemsJson(ctx.Cache)).Length;
    }

    // Bound columns of the generated row record: properties of type Binding, column = snake_case(property).
    private static readonly (PropertyInfo Prop, string Column)[] WeaponColumns =
        typeof(WeaponsRow).GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Where(p => p.PropertyType == typeof(Binding))
            .Select(p => (p, Snake(p.Name)))
            .ToArray();

    public static JsonObject ResolveWeapons(ConvContext ctx, Cs2Data data)
    {
        var root = new JsonObject();
        var errors = new JsonArray();
        foreach (var e in data.LoadErrors) errors.Add(e);
        foreach (var row in WeaponsSheet.All)
        {
            var o = new JsonObject();
            foreach (var (prop, column) in WeaponColumns)
            {
                var b = (Binding)prop.GetValue(row)!;
                if (b.Source != "cs2" || b.Key is null) continue; // constants and unset cells are not bindings
                var (ok, value, problem) = data.Resolve(b.Key);
                o[column] = value;
                if (!ok) errors.Add($"weapons.{row.Id}.{column}: {problem}");
                else if (problem is not null) ctx.Log.Warn($"weapons.{row.Id}.{column}: {problem}");
            }
            root[row.Id] = o;
        }
        root["_errors"] = errors;
        return root;
    }

    public static JsonObject ResolveSystems(ConvContext ctx, Cs2Data data)
    {
        var root = new JsonObject();
        var errors = new JsonArray();
        foreach (var row in SystemsSheet.All)
        {
            JsonNode? cell;
            try { cell = JsonNode.Parse(row.Value); }
            catch { continue; } // plain string values are not JSON
            if (cell is not JsonObject obj || obj["cs2"] is not JsonValue key) continue;
            var (ok, value, problem) = data.Resolve(key.GetValue<string>());
            root[row.Id] = new JsonObject { ["value"] = value };
            if (!ok) errors.Add($"systems.{row.Id}.value: {problem}");
            else if (problem is not null) ctx.Log.Warn($"systems.{row.Id}.value: {problem}");
        }
        root["_errors"] = errors;
        return root;
    }

    /// <summary>Inverse of gen_sheets.py pascal(): "InaccuracyStand" -> "inaccuracy_stand".</summary>
    public static string Snake(string pascal)
    {
        var sb = new StringBuilder();
        for (var i = 0; i < pascal.Length; i++)
        {
            var c = pascal[i];
            if (char.IsUpper(c) && i > 0) sb.Append('_');
            sb.Append(char.ToLowerInvariant(c));
        }
        return sb.ToString();
    }
}
