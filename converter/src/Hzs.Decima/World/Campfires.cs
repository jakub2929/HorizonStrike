using System.Numerics;
using Hzs.Decima.Core;

namespace Hzs.Decima.World;

public sealed record Campfire(string Id, Vector3 HzdPos, Vector3 GodotPos, float YawDeg);

/// <summary>
/// Campfires (save points) of a tile: <c>layers/gameplay/campfires.core</c> holds SceneInstances of the prefab
/// <c>levels/worlds/world/scenes/campfire_save/scene_campfire_save_resource</c>; the instance Name is the id
/// (e.g. Campfire_x04_y-03_01). They sit on the terrain (checked: |z - terrain| &lt; 0.35 m in tile 4,-3).
/// </summary>
public static class Campfires
{
    public static string PathOf(int x, int y) => $"{WorldTiles.TileDir(x, y)}/layers/gameplay/campfires";

    public static List<Campfire> Read(Resolver res, int x, int y)
    {
        var list = new List<Campfire>();
        var file = res.TryFile(PathOf(x, y));
        if (file is null) return list;
        var i = 0;
        foreach (var si in file.All("SceneInstance"))
        {
            var prefab = si.Ref("Prefab").Path ?? "";
            if (!prefab.Contains("campfire", StringComparison.OrdinalIgnoreCase)) continue;
            var wt = si.Struct("Orientation");
            var name = si.Str("Name");
            if (string.IsNullOrEmpty(name)) name = $"Campfire_x{WorldTiles.Fmt(x)}_y{WorldTiles.Fmt(y)}_i{i}";
            var g = WorldXf.Godot(wt);
            list.Add(new Campfire(name, WorldXf.HzdPos(wt), g.Translation, WorldXf.GodotYawDeg(g)));
            i++;
        }
        return list;
    }

    /// <summary>Named AI markers of a tile (layers/gameplay/markers.core), HZD positions.</summary>
    public static Dictionary<string, Vector3> Markers(Resolver res, int x, int y)
    {
        var d = new Dictionary<string, Vector3>(StringComparer.Ordinal);
        var file = res.TryFile($"{WorldTiles.TileDir(x, y)}/layers/gameplay/markers");
        if (file is null) return d;
        foreach (var m in file.All("AIMarker")) d.TryAdd(m.Str("Name"), WorldXf.HzdPos(m.Struct("Orientation")));
        return d;
    }
}
