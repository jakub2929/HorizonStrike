using System.Globalization;
using System.Text.RegularExpressions;
using Hzs.Decima.Archive;

using Hzs.Decima.Sheets;

namespace Hzs.Decima.World;

/// <summary>Main-world streaming tiles found in the prefetch path list (<c>levels/worlds/world/tiles/tile_x{X}_y{Y}/</c>).</summary>
public sealed partial class WorldTiles
{
    public static string WorldRoot => HzdNames.Str("world.root");
    /// <summary>Tile folders share this prefix (sheet world.tile_dir up to the tile name).</summary>
    public static string TilesRoot => HzdNames.Str("world.tile_dir")[..(HzdNames.Str("world.tile_dir").LastIndexOf('/') + 1)];

    public SortedSet<(int X, int Y)> All { get; } = [];
    public SortedSet<(int X, int Y)> Terrain { get; } = [];
    public int MinX => Terrain.Count == 0 ? 0 : Terrain.Min(t => t.X);
    public int MaxX => Terrain.Count == 0 ? 0 : Terrain.Max(t => t.X);
    public int MinY => Terrain.Count == 0 ? 0 : Terrain.Min(t => t.Y);
    public int MaxY => Terrain.Count == 0 ? 0 : Terrain.Max(t => t.Y);

    private static readonly Lazy<Regex> TileRxLazy = new(() => new Regex("^" + Regex.Escape(HzdNames.Str("world.tile_dir")).Replace(@"\{x}", @"(-?\d+)").Replace(@"\{y}", @"(-?\d+)") + "/(.*)$", RegexOptions.Compiled));
    private static Regex TileRx() => TileRxLazy.Value;

    public static string TileDir(int x, int y) => HzdNames.Fill("world.tile_dir", ("x", Fmt(x)), ("y", Fmt(y)));

    /// <summary>Tile coordinate format of the folder names: sign + 2 digits (x04, x-01).</summary>
    public static string Fmt(int v) => v < 0 ? "-" + (-v).ToString("00", CultureInfo.InvariantCulture) : v.ToString("00", CultureInfo.InvariantCulture);

    public static WorldTiles Scan(HzdArchive arc)
    {
        var t = new WorldTiles();
        var marker = HzdNames.Str("world.tile_terrain_marker");
        foreach (var p in arc.Paths)
        {
            if (!p.StartsWith(TilesRoot, StringComparison.Ordinal)) continue;
            var m = TileRx().Match(p);
            if (!m.Success) continue;
            var key = (int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture), int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture));
            t.All.Add(key);
            if (m.Groups[3].Value == marker) t.Terrain.Add(key);
        }
        return t;
    }
}
