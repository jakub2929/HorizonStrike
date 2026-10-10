using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Generated;
using ValveKeyValue;
using ValveResourceFormat.ResourceTypes.ModelAnimation2;

namespace Hzs.Cs2;

/// <summary>
/// Knife models from the player's CS2 data (sheets/systems.json knives.selection; hooks cache.knives, proto.knives):
/// cache/cs2/knives/index.json lists every knife the rule finds with its state (ok, failed + reason, pending);
/// cache/cs2/knives/&lt;id&gt;/ holds the same layout and meta.json contract as cache/cs2/weapons/&lt;id&gt;/.
/// </summary>
public static partial class Knives
{
    [System.Text.RegularExpressions.GeneratedRegex(@"^\s*""([^""]+)""\s+""((?:[^""\\]|\\.)*)""")]
    private static partial System.Text.RegularExpressions.Regex TokenLine();

    /// <summary>Output version of index.json and the knife folders; bump when they change.</summary>
    public const int Format = 1;

    private static readonly object IndexLock = new();
    private static readonly object SessionLock = new();
    private static Session? _session;

    private sealed record Rules(string PrefabChainHas, string[] RequireKeys, string ModelKey, string NameTokenKey, string AnimSkeleton,
        string GraphDir, string GraphNameContains, string Icon, string Localization, string StatsRow, string CacheDir)
    {
        public static Rules Load()
        {
            var v = JsonNode.Parse(SystemsSheet.KnivesSelection.Value)!.AsObject();
            string S(string k) => v[k]?.GetValue<string>() ?? throw new InvalidDataException($"knives.selection: {k} missing");
            return new Rules(S("prefab_chain_has"), v["require_keys"]!.AsArray().Select(x => x!.GetValue<string>()).ToArray(), S("model_key"),
                S("name_token_key"), S("anim_skeleton"), S("graph_dir"), S("graph_name_contains"), S("icon"), S("localization"), S("stats_row"), S("cache_dir"));
        }
    }

    public static string IndexPath(CachePaths cache) => Path.Combine(cache.Root, Path.Combine(Rules.Load().CacheDir.Split('/')), "index.json");

    /// <summary>
    /// Find the knives (cheap: items_game, vdata, graphs, localization) and write index.json. Entries converted by this
    /// CS2 build and format keep their state; new or outdated ones become pending; knives that cannot be converted
    /// (model or graph missing in the install) are failed with the reason.
    /// </summary>
    public static JsonObject BuildIndex(ConvContext ctx, IProgressSink progress)
    {
        if (ctx.Cs2Dir is null) throw new ArgumentException("--cs2 <dir> is required");
        using var guard = StdoutGuard.Begin(ctx.Log);
        var rules = Rules.Load();
        var build = Cs2Build.Read(ctx.Cs2Dir)?.Build ?? 0;
        progress.Report("knives-index", 0, 1);
        using var src = Cs2Source.Open(ctx.Cs2Dir);
        var data = new Cs2Data(src);
        if (data.Items is null) throw new InvalidDataException("items_game.txt could not be read");

        var tokens = Localization(src, rules.Localization, ctx.Log);
        var graphs = GraphsBySkeleton(src, rules, ctx.Log);
        var previous = ReadIndex(ctx.Cache);
        var knives = new JsonArray();
        foreach (var (defIndex, item, prefabs) in Items(data.Items))
        {
            var chain = PrefabChain(item, prefabs);
            if (!chain.Contains(rules.PrefabChainHas, StringComparer.OrdinalIgnoreCase)) continue;
            if (!rules.RequireKeys.All(k => item.ContainsKey(k))) continue;
            var classname = item["name"]?.ToString() ?? $"item_{defIndex}";
            var id = classname.StartsWith("weapon_", StringComparison.Ordinal) ? classname["weapon_".Length..] : classname;
            var model = Inherited(item, prefabs, rules.ModelKey);
            var token = Inherited(item, prefabs, rules.NameTokenKey)?.TrimStart('#');
            var skel = data.Resolve(rules.AnimSkeleton.Replace("{def_index}", defIndex)) is (true, JsonValue sv, _) ? sv.GetValue<string>() : null;
            var graph = skel is null ? null : graphs.GetValueOrDefault(Norm(skel));
            var icon = rules.Icon.Replace("{short}", id);

            var e = new JsonObject
            {
                ["id"] = id, ["classname"] = classname, ["def_index"] = int.TryParse(defIndex, out var di) ? di : -1,
                ["name_token"] = token, ["display_name"] = token is not null && tokens.TryGetValue(token, out var dn) ? dn : null,
                ["model"] = model, ["anim_skeleton"] = skel, ["graph"] = graph, ["icon"] = src.Exists(icon) ? icon : null,
                ["dir"] = $"{rules.CacheDir}/{id}", ["cs2_build"] = build, ["format"] = Format,
            };
            string? reason = model is null ? $"no {rules.ModelKey}"
                : !src.Exists(model + "_c") ? $"model {model} not in the install"
                : skel is null ? $"no anim skeleton ({rules.AnimSkeleton.Replace("{def_index}", defIndex)})"
                : graph is null ? $"no viewmodel graph animates {skel}"
                : null;
            var prev = previous.FirstOrDefault(p => p?["id"]?.GetValue<string>() == id) as JsonObject;
            if (reason is not null) { e["state"] = "failed"; e["reason"] = reason; }
            else if (prev is not null && IsCurrent(ctx, prev, build) && prev["state"]?.GetValue<string>() is "ok" or "failed")
            {
                e["state"] = prev["state"]!.GetValue<string>();
                e["reason"] = prev["reason"]?.DeepClone();
                e["clips"] = prev["clips"]?.DeepClone();
                e["bytes"] = prev["bytes"]?.DeepClone();
            }
            else e["state"] = "pending";
            knives.Add(e);
        }
        var index = new JsonObject { ["format"] = Format, ["cs2_build"] = build, ["selection"] = SystemsSheet.KnivesSelection.Id, ["knives"] = knives };
        lock (IndexLock) Atomic.WriteJson(IndexPath(ctx.Cache), index);
        progress.Report("knives-index", 1, 1);
        ctx.Log.Info($"knives index: {knives.Count} knives ({Count(index, "ok")} ok, {Count(index, "failed")} failed, {Count(index, "pending")} pending)");
        return index;
    }

    public static int Count(JsonObject index, string state) =>
        index["knives"]!.AsArray().Count(k => k?["state"]?.GetValue<string>() == state);

    /// <summary>Ids in index.json (def index order) with model and graph found and not failed (unless retryFailed).</summary>
    public static List<string> ConvertibleIds(ConvContext ctx, bool retryFailed = false) =>
        ReadIndex(ctx.Cache).OfType<JsonObject>()
            .Where(k => k["graph"] is not null && k["model"] is not null && (retryFailed || k["state"]?.GetValue<string>() != "failed"))
            .Select(k => k["id"]!.GetValue<string>()).ToList();

    /// <summary>
    /// Convert one knife listed in index.json (index must exist). Up-to-date knives are skipped (cached). Knives are
    /// converted one at a time (the VRF file loader is not thread-safe) through a session kept for the process.
    /// </summary>
    public static (string State, string? Reason, bool Cached, long Bytes) ConvertKnife(ConvContext ctx, string id, bool force = false)
    {
        if (ctx.Cs2Dir is null) throw new ArgumentException("--cs2 <dir> is required");
        var entry = ReadIndex(ctx.Cache).OfType<JsonObject>().FirstOrDefault(k => k["id"]?.GetValue<string>() == id)
            ?? throw new ArgumentException($"knife '{id}' is not in {IndexPath(ctx.Cache)} (run the knives index first)");
        var build = Cs2Build.Read(ctx.Cs2Dir)?.Build ?? 0;
        if (!force && IsCurrent(ctx, entry, build) && entry["state"]?.GetValue<string>() is "ok" or "failed")
            return (entry["state"]!.GetValue<string>(), entry["reason"]?.GetValue<string>(), true, 0);
        if (entry["graph"] is null || entry["model"] is null)
            return (entry["state"]?.GetValue<string>() ?? "failed", entry["reason"]?.GetValue<string>(), true, 0);

        var rules = Rules.Load();
        var stats = WeaponsSheet.All.FirstOrDefault(r => r.Id == rules.StatsRow);
        var spec = new AssetSpec(id, rules.CacheDir, entry["model"]!.GetValue<string>(), entry["graph"]!.GetValue<string>(),
            entry["icon"]?.GetValue<string>() ?? rules.Icon.Replace("{short}", id), "none",
            stats is null ? [] : AssetSpec.ParseList(stats.SndEvents), false, true, null);

        string state;
        string? reason = null;
        List<string> clips = [];
        long bytes = 0;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        lock (SessionLock)
        {
            using var guard = StdoutGuard.Begin(ctx.Log);
            var session = SessionFor(ctx);
            try
            {
                var result = session.Assets.Convert(spec);
                clips = result.Clips;
                // a knife must be usable in hand: draw + idle + light attack + inspect
                var missing = new[] { "draw", "idle", "fire", "inspect" }.Where(c => !clips.Contains(c)).ToList();
                state = missing.Count == 0 ? "ok" : "failed";
                if (missing.Count > 0) reason = $"clips missing: {string.Join(", ", missing)}";
                bytes = Sizes.DirBytes(session.Assets.TargetDir(spec));
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                state = "failed";
                reason = ex.Message;
                ctx.Log.Warn($"knife {id}: {ex}");
            }
        }
        ctx.Log.Info($"knife {id}: {state}{(reason is null ? "" : $" ({reason})")}, {bytes / 1024} KiB in {sw.Elapsed.TotalSeconds:F1} s, clips {string.Join(" ", clips)}");
        UpdateEntry(ctx, id, e =>
        {
            e["state"] = state;
            e["reason"] = reason;
            e["clips"] = new JsonArray(clips.Select(c => (JsonNode)JsonValue.Create(c)!).ToArray());
            e["bytes"] = bytes;
            e["cs2_build"] = build;
            e["format"] = Format;
        });
        return (state, reason, false, bytes);
    }

    /// <summary>CLI: index + every knife (or the listed ones).</summary>
    public static long ConvertAll(ConvContext ctx, IProgressSink progress, IReadOnlyList<string>? only, bool force)
    {
        BuildIndex(ctx, progress);
        var ids = ConvertibleIds(ctx, force).Where(i => only is null || only.Contains(i)).ToList();
        long bytes = 0;
        for (var i = 0; i < ids.Count; i++)
        {
            ctx.Ct.ThrowIfCancellationRequested();
            progress.Report("knives", i, ids.Count);
            bytes += ConvertKnife(ctx, ids[i], force).Bytes;
        }
        progress.Report("knives", ids.Count, ids.Count);
        var index = new JsonObject { ["knives"] = ReadIndex(ctx.Cache).DeepClone() };
        ctx.Log.Info($"knives: {Count(index, "ok")} ok, {Count(index, "failed")} failed, {Count(index, "pending")} pending");
        foreach (var k in index["knives"]!.AsArray().OfType<JsonObject>().Where(k => k["state"]?.GetValue<string>() == "failed"))
            ctx.Log.Warn($"knife {k["id"]} failed: {k["reason"]}");
        return bytes;
    }

    private sealed class Session(Cs2Source src, WeaponAssets assets, string cs2Dir, CachePaths cache)
    {
        public Cs2Source Src { get; } = src;
        public WeaponAssets Assets { get; } = assets;
        public string Cs2Dir { get; } = cs2Dir;
        public CachePaths Cache { get; } = cache;
    }

    private static Session SessionFor(ConvContext ctx)
    {
        if (_session is { } s && s.Cs2Dir == ctx.Cs2Dir && s.Cache.Root == ctx.Cache.Root) return s;
        _session?.Src.Dispose();
        var src = Cs2Source.Open(ctx.Cs2Dir!);
        _session = new Session(src, new WeaponAssets(ctx, src, new SoundExport(src, ctx.Log)), ctx.Cs2Dir!, ctx.Cache);
        return _session;
    }

    private static bool IsCurrent(ConvContext ctx, JsonObject e, long build)
    {
        if (e["cs2_build"]?.GetValue<long>() != build || e["format"]?.GetValue<int>() != Format) return false;
        if (e["state"]?.GetValue<string>() != "ok") return true;
        var dir = Path.Combine(ctx.Cache.Root, Path.Combine(e["dir"]!.GetValue<string>().Split('/')));
        return File.Exists(Path.Combine(dir, "meta.json")) && File.Exists(Path.Combine(dir, "view.glb"));
    }

    private static JsonArray ReadIndex(CachePaths cache)
    {
        lock (IndexLock)
        {
            try
            {
                var p = IndexPath(cache);
                return File.Exists(p) ? JsonNode.Parse(File.ReadAllText(p))?["knives"]?.AsArray().DeepClone().AsArray() ?? [] : [];
            }
            catch (Exception) { return []; }
        }
    }

    private static void UpdateEntry(ConvContext ctx, string id, Action<JsonObject> change)
    {
        lock (IndexLock)
        {
            var p = IndexPath(ctx.Cache);
            var index = JsonNode.Parse(File.ReadAllText(p))!.AsObject();
            if (index["knives"]!.AsArray().OfType<JsonObject>().FirstOrDefault(k => k["id"]?.GetValue<string>() == id) is { } e) change(e);
            Atomic.WriteJson(p, index);
        }
    }

    /// <summary>Every item of every "items" section with the prefab table of the document.</summary>
    private static IEnumerable<(string DefIndex, KVObject Item, Dictionary<string, KVObject> Prefabs)> Items(KVDocument doc)
    {
        var prefabs = new Dictionary<string, KVObject>(StringComparer.OrdinalIgnoreCase);
        foreach (var (k, v) in doc.Root.Children)
            if (string.Equals(k, "prefabs", StringComparison.OrdinalIgnoreCase) && v.IsCollection)
                foreach (var (pk, pv) in v.Children)
                    if (pk is not null && pv.IsCollection) prefabs.TryAdd(pk, pv);
        foreach (var (k, v) in doc.Root.Children)
            if (string.Equals(k, "items", StringComparison.OrdinalIgnoreCase) && v.IsCollection)
                foreach (var (ik, iv) in v.Children)
                    if (ik is not null && iv.IsCollection) yield return (ik, iv, prefabs);
    }

    private static List<string> PrefabChain(KVObject item, Dictionary<string, KVObject> prefabs)
    {
        var chain = new List<string>();
        var todo = new Queue<KVObject>([item]);
        while (todo.Count > 0 && chain.Count < 64)
        {
            var cur = todo.Dequeue();
            if (!cur.TryGetValue("prefab", out var p)) continue;
            foreach (var name in (p.ToString() ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries))
            {
                if (chain.Contains(name, StringComparer.OrdinalIgnoreCase)) continue;
                chain.Add(name);
                if (prefabs.TryGetValue(name, out var next)) todo.Enqueue(next);
            }
        }
        return chain;
    }

    private static string? Inherited(KVObject item, Dictionary<string, KVObject> prefabs, string key)
    {
        if (item.TryGetValue(key, out var v) && v.ValueType == KVValueType.String) return v.ToString();
        foreach (var name in PrefabChain(item, prefabs))
            if (prefabs.TryGetValue(name, out var p) && p.TryGetValue(key, out var pv) && pv.ValueType == KVValueType.String) return pv.ToString();
        return null;
    }

    /// <summary>Localization tokens (KV1 lang/Tokens), case-insensitive; empty when the file is missing.</summary>
    private static Dictionary<string, string> Localization(Cs2Source src, string path, Log log)
    {
        var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            var raw = src.ReadRaw(path);
            if (raw is null) { log.Warn($"localization {path} not found: knives keep their token as name"); return d; }
            // line-based: the file is KV1 "key" "value" pairs with \" escapes the KV1 parser rejects in some values
            foreach (var line in System.Text.Encoding.UTF8.GetString(raw).Split('\n'))
            {
                var m = TokenLine().Match(line);
                if (m.Success) d.TryAdd(m.Groups[1].Value, m.Groups[2].Value.Replace("\\\"", "\"").Replace("\\n", "\n"));
            }
        }
        catch (Exception ex) { log.Warn($"localization {path}: {ex.Message}"); }
        return d;
    }

    /// <summary>
    /// Anim skeleton -> viewmodel graph: every graph below graph_dir whose name contains graph_name_contains, keyed
    /// by the secondary skeleton its draw clip animates; when several graphs animate one skeleton the largest wins.
    /// </summary>
    private static Dictionary<string, string> GraphsBySkeleton(Cs2Source src, Rules rules, Log log)
    {
        var best = new Dictionary<string, (string Graph, int Clips)>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in src.List(rules.GraphDir).Where(p => p.EndsWith(".vnmgraph_c", StringComparison.OrdinalIgnoreCase)
                     && Path.GetFileName(p).Contains(rules.GraphNameContains, StringComparison.OrdinalIgnoreCase)))
        {
            try
            {
                var clips = ViewModel.GraphClips(src, path);
                var draw = clips.FirstOrDefault(c => Path.GetFileName(c).StartsWith("draw", StringComparison.OrdinalIgnoreCase));
                if (draw is null) continue;
                using var res = src.Load(draw + "_c");
                if (res?.DataBlock is not AnimationClip clip || clip.SecondaryAnimations.Length == 0) continue;
                var skel = Norm(clip.SecondaryAnimations[0].SkeletonName);
                if (!best.TryGetValue(skel, out var cur) || clips.Count > cur.Clips) best[skel] = (path, clips.Count);
            }
            catch (Exception ex) { log.Warn($"knife graph {path}: {ex.Message}"); }
        }
        return best.ToDictionary(kv => kv.Key, kv => kv.Value.Graph, StringComparer.OrdinalIgnoreCase);
    }

    private static string Norm(string p)
    {
        p = p.Replace('\\', '/');
        return p.EndsWith("_c", StringComparison.OrdinalIgnoreCase) ? p[..^2] : p;
    }
}
