using System.Globalization;
using System.Text.RegularExpressions;
using Hzs.Decima.Archive;

namespace Hzs.Decima.World;

/// <summary>Main-world streaming tiles found in the prefetch path list (<c>levels/worlds/world/tiles/tile_x{X}_y{Y}/</c>).</summary>
public sealed partial class WorldTiles
{
    public const string WorldRoot = "levels/worlds/world";
    public const string TilesRoot = WorldRoot + "/tiles/";

    public SortedSet<(int X, int Y)> All { get; } = [];
    public SortedSet<(int X, int Y)> Terrain { get; } = [];
    public int MinX => Terrain.Count == 0 ? 0 : Terrain.Min(t => t.X);
    public int MaxX => Terrain.Count == 0 ? 0 : Terrain.Max(t => t.X);
    public int MinY => Terrain.Count == 0 ? 0 : Terrain.Min(t => t.Y);
    public int MaxY => Terrain.Count == 0 ? 0 : Terrain.Max(t => t.Y);

    [GeneratedRegex(@"^levels/worlds/world/tiles/tile_x(-?\d+)_y(-?\d+)/(.*)$")]
    private static partial Regex TileRx();

    public static string TileDir(int x, int y) => $"{TilesRoot}tile_x{Fmt(x)}_y{Fmt(y)}";

    /// <summary>Tile coordinate format of the folder names: sign + 2 digits (x04, x-01).</summary>
    public static string Fmt(int v) => v < 0 ? "-" + (-v).ToString("00", CultureInfo.InvariantCulture) : v.ToString("00", CultureInfo.InvariantCulture);

    public static WorldTiles Scan(HzdArchive arc)
    {
        var t = new WorldTiles();
        foreach (var p in arc.Paths)
        {
            if (!p.StartsWith(TilesRoot, StringComparison.Ordinal)) continue;
            var m = TileRx().Match(p);
            if (!m.Success) continue;
            var key = (int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture), int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture));
            t.All.Add(key);
            if (m.Groups[3].Value == "layers/terrain/terraintiledata") t.Terrain.Add(key);
        }
        return t;
    }
}
