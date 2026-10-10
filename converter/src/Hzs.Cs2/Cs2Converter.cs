using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Generated;

namespace Hzs.Cs2;

/// <summary>Options of the `cs2` command (the serve bootstrap uses the defaults).</summary>
/// <param name="OnlyStats">write only cs2/weapons.json + cs2/systems.json (no models, sounds, icons, manifest)</param>
/// <param name="Force">convert even when the cache is up to date</param>
/// <param name="Only">restrict the per-weapon conversion to these sheet ids (dev); stats always cover every row</param>
/// <param name="BootstrapOnly">only what bootstrap converts: stats of every row, UI, start loadout weapons</param>
public sealed record Cs2Options(bool OnlyStats = false, bool Force = false, IReadOnlyList<string>? Only = null, bool BootstrapOnly = false)
{
    public static Cs2Options Parse(string[] args)
    {
        string? only = null;
        var i = Array.IndexOf(args, "--only");
        if (i >= 0 && i + 1 < args.Length) only = args[i + 1];
        return new Cs2Options(args.Contains("--only-stats"), args.Contains("--force"),
            only?.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries), args.Contains("--bootstrap"));
    }
}

/// <summary>
/// CS2 side of the converter (owner: "cs2"). Reads the player's CS2 install, writes cache/cs2/.
/// Bootstrap part (<see cref="ConvertBootstrap"/>): cs2/weapons.json + cs2/systems.json (stats of every weapons row),
/// cs2/ui/, and the weapons of the start loadout (sheet column start_loadout). Every other weapon converts on its own
/// (<see cref="ConvertWeapon"/>; serve op "weapons"); cs2/weapons/state.json records each weapon's state.
/// </summary>
public static class Cs2Converter
{
    /// <summary>
    /// Version of the cache/cs2 output layout written by this code; bump it whenever the output changes so caches
    /// made by an older converter from the same CS2 build are converted again. Stored as manifest.json cs2_format
    /// (stamp of the bootstrap part) and per weapon in cs2/weapons/state.json.
    /// </summary>
    public const int Format = 4; // 2: meta.json (content contract); 3: cs2/ui/snd feedback sounds; 4: per-weapon state.json

    private static readonly object StateLock = new();

    public static string StatePath(CachePaths cache) => Path.Combine(cache.Cs2, "weapons", "state.json");

    /// <summary>Weapons rows of the start loadout (given at start and after death): converted during bootstrap.</summary>
    public static IReadOnlyList<string> StartLoadoutIds() => WeaponsSheet.All.Where(r => r.StartLoadout).Select(r => r.Id).ToList();

    /// <summary>Every weapons row id (sheet order).</summary>
    public static IReadOnlyList<string> AllIds() => WeaponsSheet.All.Select(r => r.Id).ToList();

    /// <summary>Serve bootstrap: stats + UI + start loadout (see the class summary).</summary>
    public static long ConvertWeapons(ConvContext ctx, IProgressSink progress) => ConvertBootstrap(ctx, progress, force: false);

    /// <summary>CLI `cs2`: the bootstrap part, then every other weapon (or --only ids) one at a time.</summary>
    public static long ConvertWeapons(ConvContext ctx, IProgressSink progress, Cs2Options opt)
    {
        if (ctx.Cs2Dir is null) throw new ArgumentException("--cs2 <dir> is required");
        if (opt.OnlyStats)
        {
            var b = Cs2Session.Run(ctx, s => Stats(ctx, s.Src).Bytes);
            ctx.Log.Info($"cs2 stats: {ctx.Cache.Cs2WeaponsJson}");
            return b;
        }
        var bytes = ConvertBootstrap(ctx, progress, opt.Force);
        if (opt.BootstrapOnly) return bytes;
        var ids = AllIds().Where(i => opt.Only is null || opt.Only.Contains(i)).ToList();
        for (var i = 0; i < ids.Count; i++)
        {
            ctx.Ct.ThrowIfCancellationRequested();
            progress.Report("weapons", i, ids.Count);
            bytes += ConvertWeapon(ctx, ids[i], opt.Force).Bytes;
        }
        progress.Report("weapons", ids.Count, ids.Count);
        var states = ReadState(ctx.Cache);
        ctx.Log.Info($"cs2 weapons: {states.Count(kv => kv.Value?["state"]?.GetValue<string>() == "ok")} ok, " +
                     $"{states.Count(kv => kv.Value?["state"]?.GetValue<string>() == "failed")} failed of {AllIds().Count}");
        return bytes;
    }

    /// <summary>
    /// What the game needs before play: stats of every weapon (buy wheel prices), cs2/systems.json, cs2/ui/ and the
    /// start loadout weapons. Skipped when manifest.json stamps this CS2 build + format and the start loadout is current.
    /// </summary>
    public static long ConvertBootstrap(ConvContext ctx, IProgressSink progress, bool force)
    {
        if (ctx.Cs2Dir is null) throw new ArgumentException("--cs2 <dir> is required");
        var build = Cs2Build.Read(ctx.Cs2Dir);
        if (!force && build is { } b0 && IsUpToDate(ctx, b0.Build))
        {
            ctx.Log.Info($"cs2 up to date ({b0.Build})");
            progress.Report("weapons", 1, 1);
            return 0;
        }
        // an interrupted bootstrap must not look complete: drop the cs2 stamp first
        ManifestFile.Update(ctx.Cache, m => { m.Remove("cs2_build"); m.Remove("cs2_format"); });
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var bytes = Cs2Session.Run(ctx, s =>
        {
            var b = Stats(ctx, s.Src).Bytes;
            ctx.Log.Info($"cs2 stats: {ctx.Cache.Cs2WeaponsJson} ({sw.Elapsed.TotalSeconds:F1} s)");
            // the parsed items_game / vdata are garbage now: give them back before the models
            ProcessMemory.CollectNow();
            LogPeak(ctx, "stats");
            var problems = UiAssets.Convert(ctx, s.Src, s.Sounds).Count;
            if (problems > 0) ctx.Log.Warn($"cs2 ui: {problems} problems");
            return b + Sizes.DirBytes(UiAssets.Dir(ctx.Cache));
        });
        var start = StartLoadoutIds();
        for (var i = 0; i < start.Count; i++)
        {
            progress.Report("weapons", i, start.Count);
            bytes += ConvertWeapon(ctx, start[i], force).Bytes;
        }
        progress.Report("weapons", start.Count, start.Count);
        if (build is { } b1)
        {
            ManifestFile.Update(ctx.Cache, m => { m["cs2_build"] = b1.Build; m["cs2_format"] = Format; });
            ctx.Log.Info($"cs2 bootstrap ({string.Join(", ", start)}) in {sw.Elapsed.TotalSeconds:F1} s; manifest cs2_build {b1.Build} (from {b1.Source})");
        }
        else ctx.Log.Warn("CS2 build id not found (appmanifest_730.acf, steam.inf): the cache will be converted again next time");
        return bytes;
    }

    /// <summary>
    /// Convert one weapons row (world.glb, view.glb, meta.json, anim events, icon, sounds). Up-to-date weapons are
    /// skipped (cached). Needs cs2/weapons.json (stats); writes it first when missing.
    /// </summary>
    public static (string State, string? Reason, bool Cached, long Bytes) ConvertWeapon(ConvContext ctx, string id, bool force = false)
    {
        if (ctx.Cs2Dir is null) throw new ArgumentException("--cs2 <dir> is required");
        var row = WeaponsSheet.All.FirstOrDefault(r => r.Id == id) ?? throw new ArgumentException($"weapon '{id}' is not a weapons sheet row");
        var build = Cs2Build.Read(ctx.Cs2Dir)?.Build ?? 0;
        if (!force && Current(ctx, row, build) is { } done) return (done.State, done.Reason, true, 0);

        var state = "failed";
        string? reason = null;
        long bytes = 0;
        var sw = new System.Diagnostics.Stopwatch();
        var cached = Cs2Session.Run(ctx, s =>
        {
            sw.Start(); // conversion time, without waiting for the session
            // another caller may have converted it while this one waited for the session
            if (!force && Current(ctx, row, build) is { } now) { state = now.State; reason = now.Reason; return true; }
            try
            {
                if (!File.Exists(ctx.Cache.Cs2WeaponsJson)) Stats(ctx, s.Src);
                var stats = JsonNode.Parse(File.ReadAllText(ctx.Cache.Cs2WeaponsJson))?[id] as JsonObject;
                var problems = s.Assets.Convert(row, stats);
                state = "ok";
                reason = problems.Count > 0 ? string.Join("; ", problems) : null;
                bytes = Sizes.DirBytes(ctx.Cache.Cs2Weapon(id));
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                reason = ex.Message;
                ctx.Log.Warn($"weapon {id}: {ex}");
            }
            finally
            {
                // one item at a time: decoded textures (native SkiaSharp bitmaps VRF leaves to the finalizer), GLB
                // buffers and resources of this item are freed before the next one starts
                ModelExport.ClearCache();
                ProcessMemory.CollectNow();
            }
            return false;
        });
        if (cached) return (state, reason, true, 0);
        ctx.Log.Info($"{id}: {state}, {bytes / 1024} KiB in {sw.Elapsed.TotalSeconds:F1} s{(reason is null ? "" : $" ({reason})")}");
        LogPeak(ctx, id);
        lock (StateLock)
        {
            var all = ReadState(ctx.Cache);
            all[id] = new JsonObject { ["state"] = state, ["reason"] = reason, ["bytes"] = bytes, ["cs2_build"] = build, ["format"] = Format };
            Atomic.WriteJson(StatePath(ctx.Cache), new JsonObject { ["format"] = Format, ["cs2_build"] = build, ["weapons"] = all });
        }
        return (state, reason, false, bytes);
    }

    /// <summary>Close the CS2 install and drop cached state (idle server; no CS2 job may run).</summary>
    public static void ReleaseCaches() => Cs2Session.Release();

    private sealed record Done(string State, string? Reason);

    // state.json says converted by this build + format and the files are there
    private static Done? Current(ConvContext ctx, WeaponsRow row, long build)
    {
        var e = ReadState(ctx.Cache)[row.Id] as JsonObject;
        if (e is null || e["cs2_build"]?.GetValue<long>() != build || e["format"]?.GetValue<int>() != Format) return null;
        var st = e["state"]?.GetValue<string>();
        if (st == "ok")
        {
            var dir = ctx.Cache.Cs2Weapon(row.Id);
            if (!File.Exists(Path.Combine(dir, "world.glb")) || !File.Exists(Path.Combine(dir, "meta.json"))) return null;
            if (row.ViewAnimGraph != "none" && !File.Exists(Path.Combine(dir, "view.glb"))) return null;
        }
        return st is "ok" or "failed" ? new Done(st, e["reason"]?.GetValue<string>()) : null;
    }

    private static JsonObject ReadState(CachePaths cache)
    {
        lock (StateLock)
        {
            try
            {
                var p = StatePath(cache);
                return File.Exists(p) ? JsonNode.Parse(File.ReadAllText(p))?["weapons"]?.DeepClone() as JsonObject ?? [] : [];
            }
            catch (Exception) { return []; }
        }
    }

    // separate method: the parsed CS2 data (items_game is large) is unreachable once the stats are written
    private static (JsonObject Weapons, long Bytes) Stats(ConvContext ctx, Cs2Source src)
    {
        var data = new Cs2Data(src);
        var weapons = StatsConverter.ResolveWeapons(ctx, data);
        return (weapons, StatsConverter.Write(ctx, weapons, StatsConverter.ResolveSystems(ctx, data)));
    }

    private static void LogPeak(ConvContext ctx, string what)
    {
        if (ProcessMemory.ProbeEnabled)
            ctx.Log.Info($"mem {what}: peak private {ProcessMemory.TakePeakMb()} MB, now {ProcessMemory.PrivateBytes() >> 20} MB, collect total {ProcessMemory.CollectMs} ms");
    }

    /// <summary>True when the cache holds the bootstrap part (stats, UI, start loadout) of this CS2 build.</summary>
    public static bool IsUpToDate(ConvContext ctx) =>
        ctx.Cs2Dir is not null && Cs2Build.Read(ctx.Cs2Dir) is { } b && IsUpToDate(ctx, b.Build);

    private static bool IsUpToDate(ConvContext ctx, long build)
    {
        var m = ManifestFile.Read(ctx.Cache);
        if (m["cs2_build"] is not JsonValue mb || !mb.TryGetValue<long>(out var have) || have != build) return false;
        if (m["cs2_format"] is not JsonValue mf || !mf.TryGetValue<int>(out var fmt) || fmt != Format) return false;
        if (!File.Exists(ctx.Cache.Cs2WeaponsJson) || !File.Exists(StatsConverter.SystemsJson(ctx.Cache))) return false;
        if (!Directory.Exists(UiAssets.Dir(ctx.Cache))) return false;
        return WeaponsSheet.All.Where(r => r.StartLoadout).All(r => Current(ctx, r, build) is { State: "ok" });
    }
}
