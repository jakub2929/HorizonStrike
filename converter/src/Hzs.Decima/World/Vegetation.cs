using Hzs.Common;
using Hzs.Decima.Assets;
using Hzs.Decima.Core;

namespace Hzs.Decima.World;

/// <summary>One procedural vegetation species of a cell (the game scatters it from the density map).</summary>
public sealed record VegSpecies(string Channel, string MeshFile, Guid MeshUuid, string Name, float Footprint, float Scale, float ScaleVariance, float MaxSlope, int Layers);

/// <summary>
/// HZD places most vegetation procedurally on the GPU. What the data gives us per tile:
/// <c>worlddata/worlddata_placement_trees_blockbush_undergrowth_stealthplants.core</c> = a 512 x 512 RGBA density map
/// (R trees, G blockbush, B undergrowth, A stealthplants; north up like the heights) and
/// <c>placement.core</c> = PlacementLayers -> PlacementProceduralData.Placement -> ecotopes/placement_nodes/&lt;category&gt;/...
/// (PlacementSet children / MeshPlacement with Mesh, Footprint (spacing, m), Scale, MaxSlope). Category folders map to
/// channels: trees + destructibles -> trees, vision_blockers + bushes -> blockbush, ground_cover -> undergrowth,
/// cover -> stealthplants (rocks / pickups / wildlife layers are not vegetation).
/// </summary>
public sealed class Vegetation(Resolver res, Log log)
{
    public static readonly string[] Channels = ["trees", "blockbush", "undergrowth", "stealthplants"];

    public static string DensityPath(int x, int y) => $"{WorldTiles.TileDir(x, y)}/worlddata/worlddata_placement_trees_blockbush_undergrowth_stealthplants";
    public static string PlacementPath(int x, int y) => $"{WorldTiles.TileDir(x, y)}/placement";

    public Image? Density(int x, int y)
    {
        var file = res.TryFile(DensityPath(x, y));
        var texObj = file?.FirstObj("Texture");
        if (texObj is null) return null;
        var tex = HzdTexture.Parse(texObj);
        return tex.Decode(res.Archive, 0);
    }

    private static string? ChannelOf(string placementPath)
    {
        var parts = placementPath.Split('/');
        if (parts.Length < 4 || parts[1] != "placement_nodes") return null;
        return parts[2] switch
        {
            "trees" or "destructibles" => "trees",
            "vision_blockers" or "bushes" or "shrubs" => "blockbush",
            "ground_cover" or "grass" or "flowers" => "undergrowth",
            "cover" or "stealth" => "stealthplants",
            _ => null,
        };
    }

    /// <summary>Species per channel, most used first, at most <paramref name="perChannel"/> each.</summary>
    public List<VegSpecies> Species(int x, int y, int perChannel = 6)
    {
        var file = res.TryFile(PlacementPath(x, y));
        if (file is null) return [];
        var found = new Dictionary<(string, Guid), VegSpecies>();
        foreach (var layer in file.All("PlacementLayer"))
        {
            try
            {
                var proc = res.Deref(layer, layer.Ref("ProcData"));
                if (proc?.Type != "PlacementProceduralData") continue;
                var pref = proc.Ref("Placement");
                if (pref.Path is null) continue;
                var channel = ChannelOf(pref.Path);
                if (channel is null) continue;
                if (res.Target(proc.File!, pref) is not { TypeName: "MeshPlacement" or "PlacementSet" }) continue; // e.g. destructible trees
                var node = res.Deref(proc, pref);
                if (node is null) continue;
                foreach (var mp in MeshPlacements(node, 0))
                {
                    var m = mp.Ref("Mesh");
                    if (m.IsNull) continue;
                    var meshFile = m.Path ?? mp.File!.Path;
                    var key = (meshFile, m.Uuid);
                    found[key] = found.TryGetValue(key, out var e) ? e with { Layers = e.Layers + 1 }
                        : new VegSpecies(channel, meshFile, m.Uuid, mp.Str("Name"), Math.Max(0.1f, mp.Float("Footprint")), mp.Float("Scale"), mp.Float("ScaleVariance"), mp.Float("MaxSlope"), 1);
                }
            }
            catch (Exception ex) { log.Warn($"vegetation layer: {ex.Message}"); }
        }
        return found.Values.GroupBy(s => s.Channel)
            .SelectMany(g => g.OrderByDescending(s => s.Layers).ThenBy(s => s.Name, StringComparer.Ordinal).Take(perChannel)).ToList();
    }

    private IEnumerable<Obj> MeshPlacements(Obj node, int depth)
    {
        if (depth > 6) yield break;
        if (node.Type == "MeshPlacement") { yield return node; yield break; }
        if (node.Type != "PlacementSet") yield break;
        foreach (var c in node.Refs("Children"))
        {
            var child = res.Target(node.File!, c) is { TypeName: "MeshPlacement" or "PlacementSet" } ? res.Deref(node, c) : null;
            if (child is null) continue;
            foreach (var m in MeshPlacements(child, depth + 1)) yield return m;
        }
    }
}
