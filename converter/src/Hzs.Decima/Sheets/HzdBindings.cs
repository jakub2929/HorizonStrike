using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hzs.Decima.Core;
using Hzs.Generated;

namespace Hzs.Decima.Sheets;

/// <summary>
/// Resolves sheet cells bound to HZD (<c>{"hzd": "&lt;core path or {a,b} brace list&gt;[#Type.member.path]"}</c>)
/// against the player's install. Path bindings resolve to the expanded path(s) (checked to exist); member
/// bindings resolve to the member value.
/// </summary>
public static partial class HzdBindings
{
    [GeneratedRegex(@"\{([^{}]*)\}")]
    private static partial Regex Brace();

    /// <summary>Expands the first {a,b,c} group recursively.</summary>
    public static List<string> Expand(string pattern)
    {
        var m = Brace().Match(pattern);
        if (!m.Success) return [pattern];
        var result = new List<string>();
        foreach (var alt in m.Groups[1].Value.Split(','))
            result.AddRange(Expand(pattern[..m.Index] + alt + pattern[(m.Index + m.Length)..]));
        return result;
    }

    /// <summary>All paths named by a path binding (a single pattern or a JSON list of patterns).</summary>
    public static List<string> Paths(Binding b)
    {
        if (!b.IsBound || b.Key is null) return [];
        var key = b.Key.Trim();
        var patterns = key.StartsWith('[') ? JsonSerializer.Deserialize<string[]>(key)! : [key];
        return patterns.SelectMany(Expand).ToList();
    }

    public static string? Path(Binding b) => Paths(b).FirstOrDefault();

    /// <summary>Resolves one binding; throws with a readable message when the data is missing.</summary>
    public static JsonNode? Resolve(Resolver res, string key)
    {
        key = key.Trim();
        if (key.StartsWith('[')) return new JsonArray(JsonSerializer.Deserialize<string[]>(key)!.SelectMany(Expand).Select(p => (JsonNode?)CheckPath(res, p)).ToArray());
        var hash = key.IndexOf('#');
        if (hash < 0)
        {
            var all = Expand(key);
            return all.Count == 1 ? CheckPath(res, all[0]) : new JsonArray(all.Select(p => (JsonNode?)CheckPath(res, p)).ToArray());
        }
        var keys = Expand(key);
        if (keys.Count > 1) return new JsonArray(keys.Select(k => Resolve(res, k)).ToArray());
        var file = res.File(key[..hash]);
        return ToJson(Members.Evaluate(res, file, key[(hash + 1)..]));
    }

    private static JsonNode CheckPath(Resolver res, string p) =>
        res.Archive.Exists(p) ? JsonValue.Create(p) : throw new FileNotFoundException($"not in the HZD archives: {p}");

    public static JsonNode? ToJson(object? v) => v switch
    {
        null => null,
        float f => JsonValue.Create(Math.Round((double)f, 6)),
        double d => JsonValue.Create(d),
        bool b => JsonValue.Create(b),
        string s => JsonValue.Create(s),
        int or long or short or byte or sbyte or ushort or uint or ulong => JsonValue.Create(Convert.ToInt64(v)),
        Ref r => JsonValue.Create(r.ToString()),
        Obj o => new JsonObject(o.Fields.Select(kv => KeyValuePair.Create(kv.Key, ToJson(kv.Value)))),
        Array a => new JsonArray(a.Cast<object?>().Select(ToJson).ToArray()),
        _ => JsonValue.Create(v.ToString()),
    };

    /// <summary>
    /// Resolves every HZD-bound cell of the given rows into the cache shape <c>{row: {col: value|null}, _errors: [...]}</c>.
    /// </summary>
    public static JsonObject ResolveRows<TRow>(Resolver res, IEnumerable<TRow> rows, Func<TRow, string> id, IReadOnlySet<string>? listColumns = null)
    {
        var o = new JsonObject();
        var errors = new JsonArray();
        foreach (var row in rows)
        {
            var cols = new JsonObject();
            foreach (var p in typeof(TRow).GetProperties())
            {
                if (p.PropertyType != typeof(Binding)) continue;
                var b = (Binding)p.GetValue(row)!;
                if (b.Source != "hzd") continue;
                var col = Snake(p.Name);
                try
                {
                    var v = Resolve(res, b.Key!);
                    cols[col] = listColumns?.Contains(col) == true && v is not JsonArray && v is not null ? new JsonArray(v) : v;
                }
                catch (Exception ex) { cols[col] = null; errors.Add($"{id(row)}.{col}: {ex.Message}"); }
            }
            o[id(row)] = cols;
        }
        o["_errors"] = errors;
        return o;
    }

    /// <summary>Systems rows hold their value as JSON text; bound values are objects with an "hzd" key.</summary>
    public static JsonObject ResolveSystems(Resolver res, IEnumerable<SystemsRow> rows)
    {
        var o = new JsonObject();
        var errors = new JsonArray();
        foreach (var row in rows)
        {
            JsonNode? v;
            try { v = JsonNode.Parse(row.Value); } catch { continue; }
            if (v is not JsonObject obj || obj["hzd"] is not JsonValue key) continue;
            try { o[row.Id] = new JsonObject { ["value"] = Resolve(res, key.GetValue<string>()) }; }
            catch (Exception ex) { o[row.Id] = new JsonObject { ["value"] = null }; errors.Add($"{row.Id}.value: {ex.Message}"); }
        }
        o["_errors"] = errors;
        return o;
    }

    private static string Snake(string pascal) => Regex.Replace(pascal, "(?<=[a-z0-9])([A-Z])", "_$1").ToLowerInvariant();
}
