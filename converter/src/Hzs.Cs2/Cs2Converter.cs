using System.Text.Json.Nodes;
using Hzs.Common;

namespace Hzs.Cs2;

/// <summary>Options of the `cs2` command (the serve bootstrap uses the defaults).</summary>
/// <param name="OnlyStats">write only cs2/weapons.json + cs2/systems.json (no models, sounds, icons, manifest)</param>
/// <param name="Force">convert even when the cache is up to date</param>
/// <param name="Only">restrict asset conversion to these sheet ids (dev); stats always cover every row</param>
public sealed record Cs2Options(bool OnlyStats = false, bool Force = false, IReadOnlyList<string>? Only = null)
{
    public static Cs2Options Parse(string[] args)
    {
        string? only = null;
        var i = Array.IndexOf(args, "--only");
        if (i >= 0 && i + 1 < args.Length) only = args[i + 1];
        return new Cs2Options(args.Contains("--only-stats"), args.Contains("--force"),
            only?.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
    }
}

/// <summary>CS2 side of the converter (owner: "cs2"). Reads the player's CS2 install, writes cache/cs2/.</summary>
public static class Cs2Converter
{
    /// <summary>
    /// Version of the cache/cs2 output layout written by this code; bump it whenever the output changes so caches
    /// made by an older converter from the same CS2 build are converted again. Stored as manifest.json cs2_format.
    /// </summary>
    public const int Format = 1;

    /// <summary>Weapons (stats, world + view models, sounds, icons) for every row of sheets/weapons.json.</summary>
    public static long ConvertWeapons(ConvContext ctx, IProgressSink progress) =>
        ConvertWeapons(ctx, progress, new Cs2Options());

    public static long ConvertWeapons(ConvContext ctx, IProgressSink progress, Cs2Options opt)
    {
        if (ctx.Cs2Dir is null) throw new ArgumentException("--cs2 <dir> is required");
        var build = Cs2Build.Read(ctx.Cs2Dir);
        if (!opt.OnlyStats && !opt.Force && build is { } b0 && IsUpToDate(ctx, b0.Build))
        {
            ctx.Log.Info($"cs2 up to date ({b0.Build})");
            progress.Report("weapons", 1, 1);
            return 0;
        }
        var full = !opt.OnlyStats && opt.Only is null;
        // an interrupted full conversion must not look complete: drop the cs2 stamp first
        if (full) ManifestFile.Update(ctx.Cache, m => { m.Remove("cs2_build"); m.Remove("cs2_format"); });

        using var guard = StdoutGuard.Begin(ctx.Log);
        using var src = Cs2Source.Open(ctx.Cs2Dir);
        var data = new Cs2Data(src);
        var weapons = StatsConverter.ResolveWeapons(ctx, data);
        var bytes = StatsConverter.Write(ctx, weapons, StatsConverter.ResolveSystems(ctx, data));
        ctx.Log.Info($"cs2 stats: {ctx.Cache.Cs2WeaponsJson}");
        if (opt.OnlyStats) return bytes;

        var rows = Hzs.Generated.WeaponsSheet.All.Where(r => opt.Only is null || opt.Only.Contains(r.Id)).ToList();
        var sounds = new SoundExport(src, ctx.Log);
        var assets = new WeaponAssets(ctx, src, sounds);
        var problems = UiAssets.Convert(ctx, src, sounds).Count;
        bytes += Sizes.DirBytes(UiAssets.Dir(ctx.Cache));
        for (var i = 0; i < rows.Count; i++)
        {
            ctx.Ct.ThrowIfCancellationRequested();
            progress.Report("weapons", i, rows.Count);
            var sw = System.Diagnostics.Stopwatch.StartNew();
            problems += assets.Convert(rows[i], weapons[rows[i].Id] as System.Text.Json.Nodes.JsonObject).Count;
            var dirBytes = Sizes.DirBytes(ctx.Cache.Cs2Weapon(rows[i].Id));
            bytes += dirBytes;
            ctx.Log.Info($"{rows[i].Id}: {dirBytes / 1024} KiB in {sw.Elapsed.TotalSeconds:F1} s");
        }
        progress.Report("weapons", rows.Count, rows.Count);
        ctx.Log.Info($"cs2 assets: {rows.Count} items, {problems} problems (see warnings above)");
        if (full && build is { } b1)
        {
            ManifestFile.Update(ctx.Cache, m => { m["cs2_build"] = b1.Build; m["cs2_format"] = Format; });
            ctx.Log.Info($"manifest cs2_build {b1.Build} (from {b1.Source})");
        }
        else if (full) ctx.Log.Warn("CS2 build id not found (appmanifest_730.acf, steam.inf): the cache will be converted again next time");
        return bytes;
    }

    /// <summary>True when the cache already holds weapons converted from this CS2 build.</summary>
    public static bool IsUpToDate(ConvContext ctx) =>
        ctx.Cs2Dir is not null && Cs2Build.Read(ctx.Cs2Dir) is { } b && IsUpToDate(ctx, b.Build);

    private static bool IsUpToDate(ConvContext ctx, long build)
    {
        var m = ManifestFile.Read(ctx.Cache);
        if (m["cs2_build"] is not JsonValue mb || !mb.TryGetValue<long>(out var have) || have != build) return false;
        if (m["cs2_format"] is not JsonValue mf || !mf.TryGetValue<int>(out var fmt) || fmt != Format) return false;
        if (!File.Exists(ctx.Cache.Cs2WeaponsJson) || !File.Exists(StatsConverter.SystemsJson(ctx.Cache))) return false;
        if (!Directory.Exists(UiAssets.Dir(ctx.Cache))) return false;
        foreach (var row in Hzs.Generated.WeaponsSheet.All)
        {
            var dir = ctx.Cache.Cs2Weapon(row.Id);
            if (!File.Exists(Path.Combine(dir, "world.glb"))) return false;
            if (row.ViewAnimGraph != "none" && !File.Exists(Path.Combine(dir, "view.glb"))) return false;
        }
        return true;
    }
}
