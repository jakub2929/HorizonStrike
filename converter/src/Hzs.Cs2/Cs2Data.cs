using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using ValveKeyValue;
using ValveResourceFormat.ResourceTypes;

namespace Hzs.Cs2;

/// <summary>
/// Resolves sheet bindings "&lt;alias&gt;:&lt;key path&gt;" against the player's CS2 data (aliases from sheets/hooks.json):
/// vdata = scripts/weapons.vdata_c (KV3), items = scripts/items/items_game.txt (KV1), cfg = game/csgo/cfg/gamemode_competitive.cfg.
/// </summary>
internal sealed class Cs2Data
{
    public const string VdataPath = "scripts/weapons.vdata_c";
    public const string ItemsPath = "scripts/items/items_game.txt";
    public const string CfgRelPath = "cfg/gamemode_competitive.cfg";

    private readonly KVObject? _vdata;
    private readonly KVDocument? _items;
    private readonly Dictionary<string, string>? _cfg;
    private readonly HashSet<string> _pairKeys = new(StringComparer.Ordinal);
    private readonly List<string> _loadErrors = [];

    public IReadOnlyList<string> LoadErrors => _loadErrors;

    /// <summary>items_game.txt (KV1), or null when it could not be read.</summary>
    public KVDocument? Items => _items;

    public Cs2Data(Cs2Source src)
    {
        try
        {
            using var res = src.Load(VdataPath);
            if (res?.DataBlock is BinaryKV3 kv3) _vdata = kv3.Data.Root;
            else _loadErrors.Add($"{VdataPath}: not found or not KV3");
        }
        catch (Exception ex) { _loadErrors.Add($"{VdataPath}: {ex.Message}"); }

        if (_vdata is not null)
            // A key is a [mode0, mode1] pair key when any weapon block stores it as an array; scalars of such keys
            // are normalized to [v, v] (sheets/weapons.json desc).
            foreach (var (_, block) in _vdata.Children)
                if (block.IsCollection)
                    foreach (var (k, v) in block.Children)
                        if (k is not null && v.IsArray && v.Count == 2 && v.Values.All(IsNumber)) _pairKeys.Add(k);

        try
        {
            var raw = src.ReadRaw(ItemsPath);
            if (raw is null) _loadErrors.Add($"{ItemsPath}: not found");
            else
            {
                using var ms = new MemoryStream(raw, false);
                _items = KVSerializer.Create(KVSerializationFormat.KeyValues1Text).Deserialize(ms);
            }
        }
        catch (Exception ex) { _loadErrors.Add($"{ItemsPath}: {ex.Message}"); }

        try
        {
            var cfgPath = Path.Combine(src.CsgoDir, CfgRelPath);
            _cfg = ParseCfg(File.ReadAllText(cfgPath, Encoding.UTF8));
        }
        catch (Exception ex) { _loadErrors.Add($"game/csgo/{CfgRelPath}: {ex.Message}"); }
    }

    /// <summary>Raw vdata block of a weapon class (e.g. weapon_ak47), or null.</summary>
    public KVObject? VdataBlock(string name) =>
        _vdata is not null && _vdata.TryGetValue(name, out var b) && b.IsCollection ? b : null;

    /// <summary>
    /// Resolve one binding. Returns (found, value, problem): found=false with problem = error (bad alias, missing
    /// file/block); found=true, value=null with problem = warning (key absent: the game applies the column default).
    /// </summary>
    public (bool Ok, JsonNode? Value, string? Problem) Resolve(string binding)
    {
        var colon = binding.IndexOf(':');
        if (colon <= 0) return (false, null, $"binding '{binding}' has no alias");
        var alias = binding[..colon];
        var path = binding[(colon + 1)..];
        return alias switch
        {
            "vdata" => ResolveVdata(path),
            "items" => ResolveItems(path),
            "cfg" => ResolveCfg(path),
            _ => (false, null, $"unknown alias '{alias}' in '{binding}'"),
        };
    }

    private (bool, JsonNode?, string?) ResolveVdata(string path)
    {
        if (_vdata is null) return (false, null, $"{VdataPath} not loaded");
        var segs = SplitPath(path);
        var block = VdataBlock(segs[0]);
        if (block is null) return (false, null, $"vdata block '{segs[0]}' not found");
        var node = block;
        for (var i = 1; i < segs.Count; i++)
        {
            var next = Child(node, segs[i]) ?? InheritedChild(block, segs, i);
            if (next is null) return (true, null, $"vdata key '{path}' absent (column default applies)");
            node = next;
        }
        var value = ToJson(node);
        if (segs.Count == 2 && _pairKeys.Contains(segs[1]) && value is JsonValue)
            value = new JsonArray(value, value.DeepClone());
        return (true, value, null);
    }

    // vdata blocks are already flattened by the compiler; follow _base only as a fallback for a missing key.
    private KVObject? InheritedChild(KVObject block, List<string> segs, int depth)
    {
        var seen = new HashSet<string>();
        var cur = block;
        while (Child(cur, "_base") is { } b && b.ValueType == KVValueType.String && seen.Add(b.ToString()!))
        {
            cur = VdataBlock(b.ToString()!);
            if (cur is null) return null;
            KVObject? n = cur;
            for (var i = 1; i <= depth && n is not null; i++) n = Child(n, segs[i]);
            if (n is not null) return n;
        }
        return null;
    }

    private (bool, JsonNode?, string?) ResolveItems(string path)
    {
        if (_items is null) return (false, null, $"{ItemsPath} not loaded");
        var segs = SplitPath(path);
        var start = 0;
        if (segs.Count > 0 && string.Equals(segs[0], _items.Name, StringComparison.OrdinalIgnoreCase)) start = 1;
        IEnumerable<KVObject> current = [_items.Root];
        for (var i = start; i < segs.Count; i++)
        {
            var (key, selKey, selValue) = ParseSelector(segs[i]);
            // KV1 allows repeated keys (items_game has several "items" sections): search all of them.
            var matches = current.SelectMany(n => n.Children.Where(c => string.Equals(c.Key, key, StringComparison.OrdinalIgnoreCase)).Select(c => c.Value));
            if (selKey is not null)
                matches = matches.SelectMany(n => n.Children.Select(c => c.Value))
                    .Where(c => c.IsCollection && Child(c, selKey) is { } s && string.Equals(s.ToString(), selValue, StringComparison.OrdinalIgnoreCase));
            current = matches.ToList();
            if (!current.Any())
                return selKey is not null
                    ? (false, null, $"items: '{segs[i]}' not found in '{path}'")
                    : (true, null, $"items key '{path}' absent (column default applies)");
        }
        return (true, ToJson(current.First(), kv1: true), null);
    }

    private (bool, JsonNode?, string?) ResolveCfg(string name)
    {
        if (_cfg is null) return (false, null, $"game/csgo/{CfgRelPath} not loaded");
        if (!_cfg.TryGetValue(name, out var v)) return (true, null, $"cfg cvar '{name}' absent (fallback applies)");
        return (true, ParseScalar(v), null);
    }

    private static Dictionary<string, string> ParseCfg(string text)
    {
        var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine;
            var c = line.IndexOf("//", StringComparison.Ordinal);
            if (c >= 0) line = line[..c];
            line = line.Trim();
            if (line.Length == 0) continue;
            var parts = line.Split((char[])[' ', '\t'], 2, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2) continue;
            d[parts[0].Trim('"')] = parts[1].Trim().Trim('"');
        }
        return d;
    }

    private static List<string> SplitPath(string path)
    {
        // '.' separates keys, except inside a [k=v] selector
        var segs = new List<string>();
        var sb = new StringBuilder();
        var depth = 0;
        foreach (var ch in path)
        {
            if (ch == '[') depth++;
            if (ch == ']') depth--;
            if (ch == '.' && depth == 0) { segs.Add(sb.ToString()); sb.Clear(); continue; }
            sb.Append(ch);
        }
        segs.Add(sb.ToString());
        return segs;
    }

    private static (string Key, string? SelKey, string? SelValue) ParseSelector(string seg)
    {
        var b = seg.IndexOf('[');
        if (b < 0 || !seg.EndsWith(']')) return (seg, null, null);
        var inner = seg[(b + 1)..^1];
        var eq = inner.IndexOf('=');
        return eq < 0 ? (seg, null, null) : (seg[..b], inner[..eq], inner[(eq + 1)..]);
    }

    private static KVObject? Child(KVObject node, string key) =>
        node.IsCollection && node.TryGetValue(key, out var v) ? v : null;

    private static bool IsNumber(KVObject v) => v.ValueType is KVValueType.Int16 or KVValueType.Int32 or KVValueType.Int64
        or KVValueType.UInt16 or KVValueType.UInt32 or KVValueType.UInt64 or KVValueType.FloatingPoint or KVValueType.FloatingPoint64;

    /// <summary>KV value -> JSON. KV1 text values are strings: numbers/bools are parsed back.</summary>
    public static JsonNode? ToJson(KVObject v, bool kv1 = false)
    {
        switch (v.ValueType)
        {
            case KVValueType.Null: return null;
            case KVValueType.Boolean: return JsonValue.Create(v.ToBoolean());
            case KVValueType.Int16 or KVValueType.Int32 or KVValueType.UInt16: return JsonValue.Create(v.ToInt32());
            case KVValueType.Int64 or KVValueType.UInt32: return JsonValue.Create(v.ToInt64());
            case KVValueType.UInt64: return JsonValue.Create(v.ToUInt64());
            // float32 -> shortest round-trip text -> double, so 0.0006f stays 0.0006 in JSON
            case KVValueType.FloatingPoint: return JsonValue.Create(double.Parse(v.ToSingle().ToString("R", CultureInfo.InvariantCulture), CultureInfo.InvariantCulture));
            case KVValueType.FloatingPoint64: return JsonValue.Create(v.ToDouble());
            case KVValueType.String: return kv1 ? ParseScalar(v.ToString()!) : JsonValue.Create(v.ToString());
            case KVValueType.Array:
                var a = new JsonArray();
                foreach (var e in v.Values) a.Add(ToJson(e, kv1));
                return a;
            case KVValueType.Collection:
                var o = new JsonObject();
                foreach (var (k, c) in v.Children) if (k is not null) o[k] = ToJson(c, kv1);
                return o;
            default: return JsonValue.Create(v.ToString());
        }
    }

    private static JsonNode ParseScalar(string s)
    {
        if (long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var l))
            return l is >= int.MinValue and <= int.MaxValue ? JsonValue.Create((int)l) : JsonValue.Create(l);
        if (double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d)) return JsonValue.Create(d);
        if (s is "true" or "false") return JsonValue.Create(s == "true");
        return JsonValue.Create(s);
    }
}
