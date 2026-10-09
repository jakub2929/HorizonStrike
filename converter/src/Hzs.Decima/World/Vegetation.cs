using Hzs.Common;
using Hzs.Decima.Assets;
using Hzs.Decima.Core;

using Hzs.Decima.Sheets;

namespace Hzs.Decima.World;

/// <summary>
/// One procedural vegetation species of a cell (the game scatters it from the density map). DensityScale = product of
/// the HZD DensityScale factors on the way (procedural data, sets, placement); EffectLo..EffectHi = range of the
/// ecotope effect value (0 none .. 1 snow) its density graph allows (0..1 = anywhere).
/// </summary>
public sealed record VegSpecies(string Channel, string MeshFile, Guid MeshUuid, string Name, float Footprint, float Scale,
    float ScaleVariance, float MaxSlope, int Layers, float DensityScale, float Wander, float EffectLo, float EffectHi)
{
    /// <summary>HZD instances per m2 where the channel density is 1 (Footprint = spacing in m).</summary>
    public double PerM2 => DensityScale / (Footprint * Footprint);
}

/// <summary>A species chosen for a cell with its expected HZD instance count (density map x effect range x PerM2).</summary>
public sealed record VegPick(VegSpecies Species, double Expected);

/// <summary>
/// HZD places most vegetation procedurally on the GPU. What the data gives us per tile:
/// <c>worlddata/worlddata_placement_trees_blockbush_undergrowth_stealthplants.core</c> = a 512 x 512 RGBA density map
/// (R trees, G blockbush, B undergrowth, A stealthplants; north up like the heights) and
/// <c>placement.core</c> = PlacementLayers -> PlacementProceduralData.Placement -> ecotopes/placement_nodes/&lt;category&gt;/...
/// (PlacementSet children / MeshPlacement with Footprint (spacing, m), Scale, MaxSlope, DensityGraph and either Mesh or
/// PlacementTargets -> PrefabResource -> StaticMeshInstance). Category folders map to channels: trees + destructibles ->
/// trees, vision_blockers + bushes -> blockbush, ground_cover -> undergrowth, cover -> stealthplants (rocks / pickups /
/// wildlife layers are not vegetation). Density graphs that look up the ecotope effect map (snow / frost / no snow
/// variants of a plant) become an effect range; the effect map itself is exported next to the density map.
/// </summary>
public sealed class Vegetation(Resolver res, Log log)
{
    public static string[] Channels => HzdNames.List("vegetation.channels");

    public static string DensityPath(int x, int y) => $"{WorldTiles.TileDir(x, y)}/{HzdNames.Str("vegetation.density")}";
    public static string PlacementPath(int x, int y) => $"{WorldTiles.TileDir(x, y)}/{HzdNames.Str("vegetation.placement")}";
    private static readonly string EffectType = HzdNames.Str("vegetation.effect_type");

    private readonly Placements _targets = new(res, log);

    public Image? Density(int x, int y)
    {
        var file = res.TryFile(DensityPath(x, y));
        var texObj = file?.FirstObj("Texture");
        if (texObj is null) return null;
        var tex = HzdTexture.Parse(texObj);
        return tex.Decode(res.Archive, 0);
    }

    /// <summary>Ecotope effect channel of the tile (L8, at most <paramref name="maxPx"/>, north up), or null.</summary>
    public Image? Effect(int x, int y, int maxPx) => WorldData.Channel(res, x, y, HzdNames.Str("vegetation.effect_map"), EffectType, maxPx);

    internal static string? ChannelOf(string placementPath)
    {
        var parts = placementPath.Split('/');
        if (parts.Length < 4 || parts[1] != HzdNames.Str("vegetation.placement_root")) return null;
        return HzdNames.Json("vegetation.category_channels")[parts[2]]?.GetValue<string>();
    }

    /// <summary>
    /// Species per channel, the most expected instances first, at most <paramref name="perChannel"/> each. Without a
    /// density map every species counts as covering the whole cell.
    /// </summary>
    public List<VegPick> Pick(int x, int y, Image? density, Image? effect, int? perChannelOverride = null, Func<VegSpecies, bool>? usable = null)
    {
        var memo = new Dictionary<VegSpecies, bool>();
        bool Ok(VegPick p) => usable is null || (memo.TryGetValue(p.Species, out var u) ? u : memo[p.Species] = usable(p.Species));
        var perChannel = perChannelOverride ?? HzdNames.Int("vegetation.species_per_channel");
        var channels = Channels;
        var picks = new List<VegPick>();
        foreach (var s in Species(x, y))
        {
            var ci = Array.IndexOf(channels, s.Channel);
            var expected = s.PerM2 * Coverage(density, ci, effect, s.EffectLo, s.EffectHi) * TerrainReader.TileSize * TerrainReader.TileSize;
            if (expected >= 1) picks.Add(new VegPick(s, expected));
        }
        // per channel: most placement layers first (used by more ecotopes of the tile), then most expected instances; the
        // best species of every distinct effect range (snow / frost / no snow variants) is kept before filling up
        var result = new List<VegPick>();
        foreach (var g in picks.GroupBy(p => p.Species.Channel))
        {
            var ordered = g.OrderByDescending(p => p.Species.Layers).ThenByDescending(p => p.Expected)
                .ThenBy(p => p.Species.Name, StringComparer.Ordinal).ToList();
            // (usable = the caller could export it, e.g. a textured mesh; evaluated lazily in rank order)
            var chosen = new List<VegPick>();
            foreach (var r in ordered.GroupBy(p => (p.Species.EffectLo, p.Species.EffectHi)))
                if (chosen.Count < perChannel && r.FirstOrDefault(Ok) is { } best) chosen.Add(best);
            foreach (var p in ordered)
                if (chosen.Count < perChannel && !chosen.Contains(p) && Ok(p)) chosen.Add(p);
            result.AddRange(chosen.OrderBy(p => ordered.IndexOf(p)));
        }
        return result;
    }

    /// <summary>Mean over the cell of channel density x (effect value within lo..hi).</summary>
    private static double Coverage(Image? density, int ci, Image? effect, float lo, float hi)
    {
        if (density is null || ci < 0 || ci >= density.Channels) return 1;
        double sum = 0;
        for (var py = 0; py < density.Height; py++)
            for (var px = 0; px < density.Width; px++)
            {
                var d = density.Pixels[(py * density.Width + px) * density.Channels + ci] / 255.0;
                if (d <= 0) continue;
                if (effect is not null)
                {
                    var e = effect.Pixels[(int)((long)py * effect.Height / density.Height) * effect.Width + (int)((long)px * effect.Width / density.Width)] / 255f;
                    if (e < lo || e > hi) continue;
                }
                sum += d;
            }
        return sum / ((double)density.Width * density.Height);
    }

    /// <summary>All vegetation species of the tile's placement layers (one per mesh).</summary>
    public List<VegSpecies> Species(int x, int y)
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
                // layers point at single placements inside a node file: the enclosing sets' graphs and scales apply too
                var (alo, ahi, ascale) = Ancestors(node);
                foreach (var (mp, scale, lo, hi) in MeshPlacements(node, proc.Float("DensityScale") * ascale, alo, ahi, 0))
                {
                    if (MeshOf(mp) is not { } m) continue;
                    var key = (m.MeshFile, m.MeshUuid);
                    found[key] = found.TryGetValue(key, out var e)
                        ? e with { Layers = e.Layers + 1, DensityScale = Math.Max(e.DensityScale, scale), EffectLo = Math.Min(e.EffectLo, lo), EffectHi = Math.Max(e.EffectHi, hi) }
                        : new VegSpecies(channel, m.MeshFile, m.MeshUuid, mp.Str("Name"), Math.Max(0.1f, mp.Float("Footprint")), mp.Float("Scale"),
                            mp.Float("ScaleVariance"), mp.Float("MaxSlope"), 1, scale, mp.Float("WanderingDistance"), lo, hi);
                }
            }
            catch (Exception ex) { log.Warn($"vegetation layer: {ex.Message}"); }
        }
        return [.. found.Values];
    }

    /// <summary>The placement's mesh: MeshPlacement.Mesh, else the first visual mesh of its PlacementTargets.</summary>
    private Placement? MeshOf(Obj mp)
    {
        var m = mp.Ref("Mesh");
        if (!m.IsNull) return new Placement(m.Path ?? mp.File!.Path, m.Uuid, System.Numerics.Matrix4x4.Identity, "");
        foreach (var t in mp.Refs("PlacementTargets"))
            if (_targets.ForTarget(mp.File!, t) is { Count: > 0 } parts) return parts[0];
        return null;
    }

    private readonly Dictionary<string, Dictionary<Guid, Obj>> _parents = new(StringComparer.Ordinal);

    /// <summary>Effect range and density scale of the PlacementSets (same file) that contain <paramref name="node"/>.</summary>
    private (float Lo, float Hi, float Scale) Ancestors(Obj node)
    {
        var file = node.File!;
        if (!_parents.TryGetValue(file.Path, out var parents))
        {
            parents = [];
            foreach (var set in file.All("PlacementSet"))
                foreach (var c in set.Refs("Children"))
                    if (c.Path is null) parents.TryAdd(c.Uuid, set);
            _parents[file.Path] = parents;
        }
        float lo = 0f, hi = 1f, scale = 1f;
        var cur = node;
        for (var depth = 0; depth < 8 && parents.TryGetValue(cur.Uuid, out var parent); depth++)
        {
            var (gl, gh) = EffectRange(SafeDeref(parent, parent.Ref("DensityGraph")), 0);
            lo = Math.Max(lo, gl); hi = Math.Min(hi, gh);
            scale *= parent.Float("DensityScale");
            cur = parent;
        }
        return (lo, hi, scale);
    }

    private IEnumerable<(Obj Mp, float Scale, float Lo, float Hi)> MeshPlacements(Obj node, float scale, float lo, float hi, int depth)
    {
        if (depth > 6) yield break;
        var (gl, gh) = EffectRange(node.Has("DensityGraph") ? SafeDeref(node, node.Ref("DensityGraph")) : null, 0);
        lo = Math.Max(lo, gl); hi = Math.Min(hi, gh);
        if (lo > hi) yield break; // never grows anywhere
        scale *= node.Has("DensityScale") ? node.Float("DensityScale") : 1f;
        if (node.Type == "MeshPlacement") { yield return (node, scale, lo, hi); yield break; }
        if (node.Type != "PlacementSet") yield break;
        foreach (var c in node.Refs("Children"))
        {
            var child = res.Target(node.File!, c) is { TypeName: "MeshPlacement" or "PlacementSet" } ? res.Deref(node, c) : null;
            if (child is null) continue;
            foreach (var m in MeshPlacements(child, scale, lo, hi, depth + 1)) yield return m;
        }
    }

    /// <summary>Allowed ecotope effect range of a density graph: curve lookups on the effect map, intersected through multiplies.</summary>
    private (float Lo, float Hi) EffectRange(Obj? node, int depth)
    {
        if (node is null || depth > 8) return (0f, 1f);
        switch (node.Type)
        {
            case "DensityMultiply":
                {
                    float lo = 0f, hi = 1f;
                    foreach (var r in node.Refs("Inputs"))
                    {
                        var (a, b) = EffectRange(SafeDeref(node, r), depth + 1);
                        lo = Math.Max(lo, a); hi = Math.Min(hi, b);
                    }
                    return (lo, hi);
                }
            case "DensityWorldDataMap":
                {
                    // the effect value itself (through the map's own curve when it has one)
                    if (node.Ref("WorldDataType").Path != EffectType) return (0f, 1f);
                    var curve = SafeDeref(node, node.Ref("Curve"));
                    return curve?.Type == "CurveResource" ? CurveRange(curve) : (0.5f, 1f);
                }
            case "DensityInvert":
                {
                    // complement of a one-sided range; anything else is not expressible as one range
                    var (lo, hi) = EffectRange(SafeDeref(node, node.Ref("InputDensity")), depth + 1);
                    if (lo <= 0f && hi >= 1f) return (0f, 1f);
                    if (hi >= 1f) return (0f, lo);
                    if (lo <= 0f) return (hi, 1f);
                    return (0f, 1f);
                }
            case "DensityCurveLookup":
                {
                    var map = SafeDeref(node, node.Ref("Map"));
                    if (map?.Type != "DensityWorldDataMap" || map.Ref("WorldDataType").Path != EffectType) return (0f, 1f);
                    var curve = SafeDeref(node, node.Ref("Curve"));
                    return curve?.Type == "CurveResource" ? CurveRange(curve) : (0f, 1f);
                }
            default:
                return (0f, 1f);
        }
    }

    /// <summary>Inputs where the piecewise-linear curve is at least 0.5 (HZD uses step curves here); empty = (1, 0).</summary>
    private static (float Lo, float Hi) CurveRange(Obj curve)
    {
        var pts = curve.Structs("Points").Select(p => (X: p.Float("X"), Y: p.Float("Y"))).OrderBy(p => p.X).ToArray();
        if (pts.Length == 0) return (0f, 1f);
        float lo = 1f, hi = 0f;
        for (var i = 0; i <= 1000; i++)
        {
            var x = i / 1000f;
            float y;
            if (x <= pts[0].X) y = pts[0].Y;
            else if (x >= pts[^1].X) y = pts[^1].Y;
            else
            {
                var k = 1;
                while (pts[k].X < x) k++;
                var (a, b) = (pts[k - 1], pts[k]);
                y = b.X - a.X < 1e-6f ? b.Y : a.Y + (b.Y - a.Y) * (x - a.X) / (b.X - a.X);
            }
            if (y >= 0.5f) { lo = Math.Min(lo, x); hi = Math.Max(hi, x); }
        }
        return (lo, hi);
    }

    private Obj? SafeDeref(Obj from, Ref r)
    {
        if (r.IsNull) return null;
        var t = res.Target(from.File!, r);
        return t?.TypeName is "DensityMultiply" or "DensityCurveLookup" or "DensityWorldDataMap" or "DensityInvert" or "CurveResource" ? res.Deref(from, r) : null;
    }
}
