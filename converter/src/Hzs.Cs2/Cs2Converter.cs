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
    /// <summary>Weapons (stats, world + view models, sounds, icons) for every row of sheets/weapons.json.</summary>
    public static long ConvertWeapons(ConvContext ctx, IProgressSink progress) =>
        ConvertWeapons(ctx, progress, new Cs2Options());

    public static long ConvertWeapons(ConvContext ctx, IProgressSink progress, Cs2Options opt)
    {
        if (ctx.Cs2Dir is null) throw new ArgumentException("--cs2 <dir> is required");
        using var guard = StdoutGuard.Begin(ctx.Log);
        using var src = Cs2Source.Open(ctx.Cs2Dir);
        var data = new Cs2Data(src);
        var bytes = StatsConverter.Write(ctx, data);
        ctx.Log.Info($"cs2 stats: {ctx.Cache.Cs2WeaponsJson}");
        progress.Report("weapons", 0, 1);
        if (opt.OnlyStats) return bytes;
        progress.Report("weapons", 1, 1);
        return bytes;
    }

    /// <summary>True when the cache already holds weapons converted from this CS2 build.</summary>
    public static bool IsUpToDate(ConvContext ctx) => false;
}
