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
        throw new NotImplementedException("svet: ConvertCell");

    /// <summary>Horizon music and ambience used by the game.</summary>
    public static long ConvertAudio(ConvContext ctx, IProgressSink progress) =>
        throw new NotImplementedException("svet: ConvertAudio");
}
