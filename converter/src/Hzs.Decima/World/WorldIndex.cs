using System.Numerics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Decima.Assets;
using Hzs.Decima.Core;
using Hzs.Generated;

using Hzs.Decima.Sheets;

namespace Hzs.Decima.World;

/// <summary>
/// hzd/index.json: {format, world, cell_size, grid_min, grid_max, cells, start_cell, start_pos, start_campfire,
/// start_marker, axes}. Cells = main-world tiles with terrain. Start position = the Mother's Heart village centre
/// marker (AIMarker M_Area_Marketplace in the start tile's layers/gameplay/markers.core); start campfire = the
/// campfire of the start tile nearest to it.
/// </summary>
public static class WorldIndex
{
    public static string StartMarker => HzdNames.Str("start.marker");

    public static long Build(ConvContext ctx, Resolver res, IProgressSink progress)
    {
        progress.Report("index", 0, 1);
        var tiles = WorldTiles.Scan(res.Archive);
        float cellSize = TerrainReader.TileSize;
        try
        {
            // sheet systems streaming.cell_size_m binding
            var key = JsonNode.Parse(SystemsSheet.StreamingCellSizeM.Value)!["hzd"]!.GetValue<string>();
            cellSize = float.Parse(HzdBindings.Resolve(res, key)!.ToJsonString(), System.Globalization.CultureInfo.InvariantCulture);
        }
        catch (Exception ex) { ctx.Log.Warn($"index: tile size unresolved ({ex.Message}), using 512"); }
        if (Math.Abs(cellSize - TerrainReader.TileSize) > 0.01f)
            throw new InvalidDataException($"tile size {cellSize} != {TerrainReader.TileSize}: cell layout assumptions do not hold");

        var start = JsonSerializer.Deserialize<int[]>(SystemsSheet.StreamingStartCell.Value) ?? [4, -3];
        var (sx, sy) = (start[0], start[1]);
        var campfires = Campfires.Read(res, sx, sy);
        var markers = Campfires.Markers(res, sx, sy);
        Vector3 startHzd;
        string? marker = null;
        if (markers.TryGetValue(StartMarker, out var m)) { startHzd = m; marker = StartMarker; }
        else if (campfires.Count > 0) startHzd = campfires[0].HzdPos;
        else startHzd = new Vector3((sx + 0.5f) * TerrainReader.TileSize, (sy + 0.5f) * TerrainReader.TileSize, 0);
        var nearest = campfires.OrderBy(c => Vector2.Distance(new Vector2(c.HzdPos.X, c.HzdPos.Y), new Vector2(startHzd.X, startHzd.Y))).FirstOrDefault();
        var markerHzd = startHzd;
        if (nearest is not null)
        {
            // the village marker stands on rock platforms (3.4 m off the heightmap); campfires sit on the terrain:
            // start 3 m from the start campfire towards the village centre, on the terrain surface
            var d = new Vector2(markerHzd.X - nearest.HzdPos.X, markerHzd.Y - nearest.HzdPos.Y);
            var dir = d.LengthSquared() > 1e-4f ? Vector2.Normalize(d) : Vector2.UnitY;
            var p = new Vector2(nearest.HzdPos.X, nearest.HzdPos.Y) + dir * (float)HzdNames.Num("start.campfire_offset_m");
            var h = TerrainReader.ReadReal(res, sx, sy) is { } t ? Sample(t, sx, sy, p.X, p.Y) : nearest.HzdPos.Z;
            startHzd = new Vector3(p.X, p.Y, h + 0.1f);
        }
        var startG = Space.P(startHzd);

        var cells = new JsonArray(tiles.Terrain.Select(t => (JsonNode)new JsonArray(t.X, t.Y)).ToArray());
        var index = new JsonObject
        {
            ["format"] = 1,
            ["world"] = WorldTiles.WorldRoot,
            ["cell_size"] = JsonNode.Parse(cellSize.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)),
            ["grid_min"] = new JsonArray(tiles.MinX, tiles.MinY),
            ["grid_max"] = new JsonArray(tiles.MaxX, tiles.MaxY),
            ["cells"] = cells,
            ["start_cell"] = new JsonArray(sx, sy),
            ["start_pos"] = new JsonArray(Math.Round(startG.X, 3), Math.Round(startG.Y, 3), Math.Round(startG.Z, 3)),
            ["start_marker"] = marker,
            ["start_marker_pos"] = new JsonArray(Math.Round(Space.P(markerHzd).X, 3), Math.Round(Space.P(markerHzd).Y, 3), Math.Round(Space.P(markerHzd).Z, 3)),
            ["start_campfire"] = nearest?.Id,
            ["start_campfire_pos"] = nearest is null ? null : new JsonArray(Math.Round(nearest.GodotPos.X, 3), Math.Round(nearest.GodotPos.Y, 3), Math.Round(nearest.GodotPos.Z, 3)),
            ["axes"] = "godot meters: x east, y up, z south (hzd x east, y north, z up; godot = (x, z, -y)); cell (x,y) spans x 512x..512(x+1), z -512(y+1)..-512y",
        };
        Atomic.WriteJson(ctx.Cache.HzdIndex, index);
        progress.Report("index", 1, 1);
        ctx.Log.Info($"index: {tiles.Terrain.Count} cells, start {sx},{sy} at {startG}, campfire {nearest?.Id}");
        return new FileInfo(ctx.Cache.HzdIndex).Length;
    }

    /// <summary>Bilinear terrain height at HZD world XY inside cell (x,y).</summary>
    public static float Sample(TerrainData t, int x, int y, float wx, float wy)
    {
        var s = t.Spacing;
        var c = Math.Clamp((wx - x * TerrainReader.TileSize) / s, 0, t.Res - 1.001f);
        var r = Math.Clamp(((y + 1) * TerrainReader.TileSize - wy) / s, 0, t.Res - 1.001f);
        int c0 = (int)c, r0 = (int)r;
        float fc = c - c0, fr = r - r0;
        float H(int rr, int cc) => t.Heights[rr * t.Res + cc];
        return H(r0, c0) * (1 - fc) * (1 - fr) + H(r0, c0 + 1) * fc * (1 - fr) + H(r0 + 1, c0) * (1 - fc) * fr + H(r0 + 1, c0 + 1) * fc * fr;
    }

    public static (int X, int Y) StartCell(CachePaths cache)
    {
        var o = JsonNode.Parse(File.ReadAllText(cache.HzdIndex))!;
        var s = o["start_cell"]!.AsArray();
        return (s[0]!.GetValue<int>(), s[1]!.GetValue<int>());
    }
}
