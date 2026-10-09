using System.Diagnostics;
using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Decima.Archive;
using Hzs.Decima.Core;
using Hzs.Decima.Machines;
using Hzs.Decima.Sheets;
using Hzs.Generated;

namespace Hzs.Decima;

/// <summary>HZD side of the converter (owner: "svet"). Reads the player's HZD install, writes cache/hzd/.</summary>
public static class HzdConverter
{
    /// <summary>Bump when the HZD cache layout or conversion changes (forces re-conversion of hzd/ assets).</summary>
    public const int HzdFormat = 1;

    /// <summary>Steam build id of the HZD install (&lt;lib&gt;/steamapps/appmanifest_1151640.acf), or null.</summary>
    public static string? HzdBuild(string hzdDir)
    {
        try
        {
            var acf = Path.GetFullPath(Path.Combine(hzdDir, "..", "..", "appmanifest_1151640.acf"));
            if (!File.Exists(acf)) return null;
            foreach (var line in File.ReadLines(acf))
            {
                var parts = line.Split('"', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Where(x => x.Length > 0).ToArray();
                if (parts.Length >= 2 && parts[0] == "buildid") return parts[1];
            }
        }
        catch (IOException) { }
        return null;
    }

    /// <summary>True when the cache was converted from this HZD build with this converter format.</summary>
    private static bool Stamped(ConvContext ctx)
    {
        var m = ManifestFile.Read(ctx.Cache);
        return m["hzd_build"]?.ToString() == (HzdBuild(ctx.HzdDir!) ?? "unknown") && m["hzd_format"]?.ToString() == HzdFormat.ToString();
    }

    private static void Stamp(ConvContext ctx) => ManifestFile.Update(ctx.Cache, m =>
    {
        var b = HzdBuild(ctx.HzdDir!);
        m["hzd_build"] = long.TryParse(b, out var n) ? n : b ?? "unknown";
        m["hzd_format"] = HzdFormat;
    });

    private static HzdArchive Archive(ConvContext ctx) =>
        HzdArchive.Open(ctx.HzdDir ?? throw new ArgumentException("--hzd <dir> is required"));

    /// <summary>Optional dev filter: --only id1,id2 on the command line.</summary>
    private static HashSet<string>? Only()
    {
        var a = Environment.GetCommandLineArgs();
        var i = Array.IndexOf(a, "--only");
        return i >= 0 && i + 1 < a.Length ? a[i + 1].Split(',').ToHashSet(StringComparer.Ordinal) : null;
    }

    private static readonly HashSet<string> MachineListColumns = ["model_parts", "textures", "sound_banks", "weak_spot_bones", "leg_chains"];

    /// <summary>Watcher, Strider, Grazer: skinned models with the real skeleton, textures, meta, sounds.</summary>
    public static long ConvertMachines(ConvContext ctx, IProgressSink progress)
    {
        var arc = Archive(ctx);
        var res = new Resolver(arc);
        long bytes = 0;
        var only = Only();
        var rows = MachinesSheet.All.Where(r => only is null || only.Contains(r.Id)).ToList();
        var force = Environment.GetCommandLineArgs().Contains("--force");
        if (!force && Stamped(ctx) && File.Exists(Path.Combine(ctx.Cache.Hzd, "machines.json"))
            && rows.All(r => File.Exists(Path.Combine(ctx.Cache.Machine(r.Id), "model.glb")) && File.Exists(Path.Combine(ctx.Cache.Machine(r.Id), "meta.json"))))
        {
            ctx.Log.Info($"hzd machines up to date ({HzdBuild(ctx.HzdDir!)})");
            progress.Report("machines", rows.Count, rows.Count);
            return 0;
        }

        // resolved sheet bindings (hzd/machines.json, hzd/systems.json)
        var resolved = HzdBindings.ResolveRows(res, MachinesSheet.All, r => r.Id, MachineListColumns);
        foreach (var e in resolved["_errors"]!.AsArray()) ctx.Log.Warn($"machines binding: {e}");
        Atomic.WriteJson(Path.Combine(ctx.Cache.Hzd, "machines.json"), resolved);
        var systems = HzdBindings.ResolveSystems(res, SystemsSheet.All);
        Atomic.WriteJson(Path.Combine(ctx.Cache.Hzd, "systems.json"), systems);

        var i = 0;
        foreach (var row in rows)
        {
            ctx.Ct.ThrowIfCancellationRequested();
            progress.Report("machines", i++, rows.Count);
            var sw = Stopwatch.StartNew();
            var target = ctx.Cache.Machine(row.Id);
            var tmp = Atomic.BeginDir(target);
            var builder = new MachineBuilder(res, row, resolved[row.Id] as JsonObject, ctx.Log);
            var result = builder.Build();
            // leg chains are derived from the bound skeleton + bind pose: the resolved value is the derived list
            if (resolved[row.Id] is JsonObject rr)
                rr["leg_chains"] = new JsonArray(builder.LegChains().Select(c => (JsonNode)string.Join(">", c)).ToArray());
            File.WriteAllBytes(Path.Combine(tmp, "model.glb"), result.Glb);
            var meta = result.Meta;
            if (resolved[row.Id] is JsonObject rv)
            {
                meta["hzd_health"] = rv["hzd_health"]?.DeepClone();
                meta["perception"] = new JsonObject
                {
                    ["sight_range_m"] = rv["sight_range_m"]?.DeepClone(),
                    ["sight_half_angle_deg"] = rv["sight_fov_deg"]?.DeepClone(),
                    ["peripheral_range_m"] = rv["peripheral_range_m"]?.DeepClone(),
                    ["hearing_range_m"] = rv["hearing_range_m"]?.DeepClone(),
                    ["immediate_suspicion_m"] = rv["immediate_suspicion_m"]?.DeepClone(),
                    ["immediate_alert_m"] = rv["immediate_alert_m"]?.DeepClone(),
                };
            }
            Atomic.WriteJson(Path.Combine(tmp, "meta.json"), meta);
            Atomic.CommitDir(tmp, target);
            Atomic.WriteJson(Path.Combine(ctx.Cache.Hzd, "machines.json"), resolved);
            var size = Sizes.DirBytes(target);
            bytes += size;
            ctx.Log.Info($"machine {row.Id}: {result.Vertices} vertices, {result.Joints} joints, height {result.HeightM:F2} m, {size} bytes, {sw.ElapsedMilliseconds} ms");
        }
        Stamp(ctx);
        progress.Report("machines", rows.Count, rows.Count);
        return bytes;
    }

    /// <summary>World index: cell grid, start cell, campfires, spawn sites (hzd/index.json).</summary>
    public static long BuildIndex(ConvContext ctx, IProgressSink progress) =>
        throw new NotImplementedException("svet: BuildIndex");

    /// <summary>Start cell from hzd/index.json (after BuildIndex).</summary>
    public static (int X, int Y) StartCell(ConvContext ctx) =>
        throw new NotImplementedException("svet: StartCell");

    /// <summary>One world cell: terrain, instances, vegetation, campfires, spawns (hzd/cells/X_Y/).</summary>
    public static long ConvertCell(ConvContext ctx, int x, int y, IProgressSink progress) =>
        World.CellConverter.Convert(ctx, new Resolver(Archive(ctx)), x, y, progress);

    /// <summary>Horizon music and ambience used by the game.</summary>
    public static long ConvertAudio(ConvContext ctx, IProgressSink progress) =>
        throw new NotImplementedException("svet: ConvertAudio");
}
