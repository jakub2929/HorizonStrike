using System.Numerics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Decima.Assets;
using Hzs.Decima.Core;
using Hzs.Generated;

namespace Hzs.Decima.World;

/// <summary>
/// hzd/index.json: {format, world, cell_size, grid_min, grid_max, cells, start_cell, start_pos, start_campfire,
/// start_marker, axes}. Cells = main-world tiles with terrain. Start position = the Mother's Heart village centre
/// marker (AIMarker M_Area_Marketplace in the start tile's layers/gameplay/markers.core); start campfire = the
/// campfire of the start tile nearest to it.
/// </summary>
public static class WorldIndex
{
    public const string StartMarker = "M_Area_Marketplace";

    public static long Build(ConvContext ctx, Resolver res, IProgressSink progress)
    {
        progress.Report("index", 0, 1);
        var tiles = WorldTiles.Scan(res.Archive);
        float cellSize = TerrainReader.TileSize;
        try
        {
            var f = res.File("levels/worlds/world/leveldata/streamingtiles");
            var v = Members.Evaluate(res, f, "TileBasedStreamingStrategyResource.TileSize");
            cellSize = Convert.ToSingle(v);
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
            ["start_campfire"] = nearest?.Id,
            ["start_campfire_pos"] = nearest is null ? null : new JsonArray(Math.Round(nearest.GodotPos.X, 3), Math.Round(nearest.GodotPos.Y, 3), Math.Round(nearest.GodotPos.Z, 3)),
            ["axes"] = "godot meters: x east, y up, z south (hzd x east, y north, z up; godot = (x, z, -y)); cell (x,y) spans x 512x..512(x+1), z -512(y+1)..-512y",
        };
        Atomic.WriteJson(ctx.Cache.HzdIndex, index);
        progress.Report("index", 1, 1);
        ctx.Log.Info($"index: {tiles.Terrain.Count} cells, start {sx},{sy} at {startG}, campfire {nearest?.Id}");
        return new FileInfo(ctx.Cache.HzdIndex).Length;
    }

    public static (int X, int Y) StartCell(CachePaths cache)
    {
        var o = JsonNode.Parse(File.ReadAllText(cache.HzdIndex))!;
        var s = o["start_cell"]!.AsArray();
        return (s[0]!.GetValue<int>(), s[1]!.GetValue<int>());
    }
}
