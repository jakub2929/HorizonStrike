using System.Numerics;
using System.Text.RegularExpressions;
using Hzs.Common;
using Hzs.Decima.Assets;
using Hzs.Decima.Core;
using Hzs.Generated;

namespace Hzs.Decima.World;

/// <summary>One original machine group of a site and its variant-B replacement.</summary>
public sealed record Spawn(string Site, string OrigType, int OrigMin, int OrigMax, string? Type, int Count, Vector3 GodotPos, float Radius, string Rule, bool Populate);

/// <summary>
/// Fixed machine sites of a tile: SceneInstances in layers/scenes/robot encounters/* and layers/scenes/robot_placement/**
/// whose SceneResource holds AIBehaviorGroups. Each AIBehaviorGroupMember names a spawn setup
/// (entities/spawnsetups/robots/&lt;type&gt;/...) and an Amount range; the group's AIDefendArea.IdleRadius is the site
/// radius. Random world encounters (layers/scenes/worldencounters) are not fixed sites and are skipped.
/// Variant B (sheet site_map): group row of the site AI group first, then the type row of the original machine,
/// unknown -> watcher x1. count = clamp(round(mean(orig) * count_mult), herd_size_min, herd_size_max).
/// </summary>
public sealed partial class RobotSites(Resolver res, Log log)
{
    [GeneratedRegex(@"spawnsetups/robots/([a-z0-9_]+)/")]
    private static partial Regex RobotType();

    public static IEnumerable<string> LayerFiles(Resolver res, int x, int y)
    {
        var dir = WorldTiles.TileDir(x, y) + "/layers/scenes/";
        return res.Archive.Paths.Where(p => p.StartsWith(dir, StringComparison.Ordinal)
            && (p.Contains("robot encounters/", StringComparison.Ordinal) || p.Contains("robot_encounters/", StringComparison.Ordinal) || p.Contains("robot_placement/", StringComparison.Ordinal))
            && (p.EndsWith("_layer", StringComparison.Ordinal) || p.EndsWith("layer", StringComparison.Ordinal)));
    }

    public List<Spawn> ForTile(int x, int y)
    {
        var list = new List<Spawn>();
        var seen = new HashSet<Guid>();
        foreach (var layer in LayerFiles(res, x, y))
        {
            var file = res.TryFile(layer);
            if (file is null) continue;
            foreach (var si in file.All("SceneInstance"))
            {
                if (!seen.Add(si.Uuid)) continue;
                try { Site(si, list); }
                catch (Exception ex) { log.Warn($"site {si.Str("Name")} in {layer}: {ex.Message}"); }
            }
        }
        return list;
    }

    private void Site(Obj si, List<Spawn> list)
    {
        var world = WorldXf.Hzd(si.Struct("Orientation"));
        var name = si.Str("Name");
        var scene = res.Deref(si, si.Ref("Prefab"));
        if (scene?.Type != "SceneResource") return;
        var coll = res.Deref(scene, scene.Ref("ObjectCollection"));
        if (coll is null) return;
        if (string.IsNullOrEmpty(name)) name = Path.GetFileNameWithoutExtension(scene.File!.Path).Replace("_resource", "");
        var gi = 0;
        foreach (var r in coll.Refs("Objects"))
        {
            var target = res.Target(coll.File!, r);
            if (target?.TypeName != "AIBehaviorGroup") continue;
            var g = coll.File!.Decode(target);
            var gw = WorldXf.Hzd(g.Struct("Orientation")) * world;
            var radius = DefendRadius(g) ?? 0f;
            var site = gi == 0 ? name : $"{name}_{gi}";
            gi++;
            foreach (var mr in g.Refs("Members"))
            {
                var m = res.Deref(g, mr);
                if (m?.Type != "AIBehaviorGroupMember") continue;
                var setup = m.Ref("SpawnSetup").Path ?? "";
                var mt = RobotType().Match(setup);
                if (!mt.Success) continue; // humans, animals
                var amount = m.Struct("Amount");
                int min = amount.Int("Min"), max = Math.Max(amount.Int("Min"), amount.Int("Max"));
                var rad = radius > 0 ? radius : Math.Max(10f, m.Struct("SpawnRange").Float("Max"));
                list.Add(Map(site, mt.Groups[1].Value, min, max, Space.P(gw.Translation), rad));
            }
        }
    }

    private float? DefendRadius(Obj group)
    {
        foreach (var cr in group.Refs("SpawnCommands"))
        {
            var cmd = res.Deref(group, cr);
            if (cmd?.Type != "DefendSpawnCommand") continue;
            var set = res.Deref(cmd, cmd.Ref("DefendAreaSet"));
            if (set?.Type != "AIDefendAreaSet") continue;
            foreach (var nr in set.Refs("Nodes"))
                if (res.Deref(set, nr) is { Type: "AIDefendArea" } area) return area.Float("IdleRadius");
        }
        return null;
    }

    /// <summary>Variant B: type row of the original machine (group rows are not referenced by placements in HZD data).</summary>
    public static Spawn Map(string site, string origType, int min, int max, Vector3 pos, float radius)
    {
        // spawn setups use short names for some machines (longleg vs model folder longlegbird)
        var row = SiteMapSheet.All.FirstOrDefault(r => r.Kind == "type" && r.HzdName == origType)
                  ?? SiteMapSheet.All.FirstOrDefault(r => r.Kind == "type" && r.HzdName.StartsWith(origType, StringComparison.Ordinal));
        var rule = row?.Id ?? "unknown:watcher";
        var machineId = row?.Machine ?? "watcher";
        var populate = row?.Populate ?? true;
        var mult = row?.CountMult ?? 1.0;
        var machine = MachinesSheet.All.FirstOrDefault(m => m.Id == machineId);
        var count = 0;
        if (populate && machine is not null)
        {
            var raw = (int)Math.Round((min + max) / 2.0 * mult, MidpointRounding.AwayFromZero);
            count = row is null ? 1 : Math.Clamp(raw, machine.HerdSizeMin, machine.HerdSizeMax);
        }
        return new Spawn(site, origType, min, max, populate ? machineId : null, count, pos, radius, rule, populate);
    }
}
