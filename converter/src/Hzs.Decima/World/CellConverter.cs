using System.Diagnostics;
using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Decima.Core;

namespace Hzs.Decima.World;

/// <summary>
/// Converts one main-world tile into cache/hzd/cells/X_Y (Godot space: x = east, y = up, z = south).
/// cell.json "origin" is the cell's north-west corner (min x, min z) at height 0; terrain samples (row r, column c)
/// lie at origin + (c * spacing, h, r * spacing).
/// </summary>
public static class CellConverter
{
    public static long Convert(ConvContext ctx, Resolver res, int x, int y, IProgressSink progress, int texPx = 1024)
    {
        var sw = Stopwatch.StartNew();
        var target = ctx.Cache.Cell(x, y);
        var tmp = Atomic.BeginDir(target);
        try
        {
            progress.Report("terrain", 0, 1);
            var terrain = TerrainReader.ReadReal(res, x, y);
            if (terrain is null)
            {
                ctx.Log.Warn($"cell {x},{y}: no readable height data, using fallback terrain");
                terrain = TerrainReader.Fallback(x, y);
            }
            File.WriteAllBytes(Path.Combine(tmp, "height.r32"), TerrainReader.ToR32(terrain.Heights));
            string? albedo = null;
            try
            {
                var img = TerrainReader.ReadAlbedo(res, x, y, texPx);
                if (img is not null)
                {
                    File.WriteAllBytes(Path.Combine(tmp, "albedo.png"), img.ToPng());
                    albedo = "albedo.png";
                }
            }
            catch (Exception ex) { ctx.Log.Warn($"cell {x},{y}: albedo: {ex.Message}"); }
            progress.Report("terrain", 1, 1);

            var cell = new JsonObject
            {
                ["format"] = 1,
                ["cell"] = new JsonArray(x, y),
                ["origin"] = new JsonArray(x * TerrainReader.TileSize, 0f, -(y + 1) * TerrainReader.TileSize),
                ["size"] = TerrainReader.TileSize,
                ["terrain"] = new JsonObject
                {
                    ["file"] = "height.r32",
                    ["res"] = new JsonArray(terrain.Res, terrain.Res),
                    ["spacing"] = Math.Round(terrain.Spacing, 6),
                    ["min"] = Math.Round(terrain.Min, 3),
                    ["max"] = Math.Round(terrain.Max, 3),
                    ["real"] = terrain.Real,
                    ["albedo"] = albedo,
                    ["source"] = terrain.Source,
                },
                ["instances"] = new JsonArray(),
                ["vegetation"] = null,
                ["campfires"] = new JsonArray(),
                ["spawns"] = new JsonArray(),
                ["meshes"] = new JsonArray(),
            };
            Atomic.WriteJson(Path.Combine(tmp, "cell.json"), cell);
            Atomic.CommitDir(tmp, target);
        }
        catch
        {
            try { Directory.Delete(tmp, true); } catch (IOException) { }
            throw;
        }
        var bytes = Sizes.DirBytes(target);
        ctx.Log.Info($"cell {x},{y}: {bytes} bytes, {sw.ElapsedMilliseconds} ms");
        return bytes;
    }
}
