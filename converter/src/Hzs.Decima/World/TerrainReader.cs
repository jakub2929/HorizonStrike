using System.Buffers.Binary;
using Hzs.Decima.Assets;
using Hzs.Decima.Core;

using Hzs.Decima.Sheets;

namespace Hzs.Decima.World;

/// <summary>Heights of one cell in Godot layout: row-major, row 0 = north edge, column 0 = west edge.</summary>
public sealed record TerrainData(float[] Heights, int Res, float Min, float Max, bool Real, string Source)
{
    public float Spacing => TerrainReader.TileSize / (Res - 1);
}

/// <summary>
/// Real HZD terrain heights. Each main-world tile has <c>worlddata/worlddata_height_terrain.core</c>: a
/// WorldDataTextureMap whose SurfaceCacheData is a 1024 x 1024 R_UNORM_16 grid. Facts established from the data:
/// heights in meters = raw / 32 (raw range of tile (4,-3) maps exactly onto its TerrainTileData.MappedHeightRange
/// 176..428); row 0 is the tile's north edge (max Y), column 0 its west edge (min X); neighbouring tiles share
/// their edge samples (identical raw values), so the 1024 samples span the 512 m tile inclusive (spacing 512/1023 m).
/// </summary>
public static class TerrainReader
{
    public const float TileSize = 512f;
    public const float HeightScale = 1f / 32f;

    public static string HeightPath(int x, int y) => $"{WorldTiles.TileDir(x, y)}/{HzdNames.Str("terrain.height")}";
    public static string AlbedoPath(int x, int y) => $"{WorldTiles.TileDir(x, y)}/{HzdNames.Str("terrain.albedo")}";

    public static TerrainData? ReadReal(Resolver res, int x, int y)
    {
        var file = res.TryFile(HeightPath(x, y));
        var map = file?.FirstObj("WorldDataTextureMap");
        if (map is null) return null;
        byte[] raw = map.Prims<byte>("SurfaceCacheData");
        var n = 0;
        if (raw.Length >= 2 && map.Int("SurfaceCacheFormat") == HzdTexture.R_UNORM_16)
            n = (int)Math.Sqrt(raw.Length / 2.0);
        if (n * n * 2 != raw.Length)
        {
            // no surface cache: decode the result texture (R_UNORM_16, mip 0)
            var texObj = res.Deref(file!, map.Ref("ResultTexture"));
            if (texObj is null) return null;
            var tex = HzdTexture.Parse(texObj);
            if (tex.Format != HzdTexture.R_UNORM_16 || tex.Width != tex.Height) return null;
            raw = tex.MipData(res.Archive, 0);
            n = tex.Width;
        }
        var h = new float[n * n];
        float min = float.MaxValue, max = float.MinValue;
        for (var i = 0; i < h.Length; i++)
        {
            var v = BinaryPrimitives.ReadUInt16LittleEndian(raw.AsSpan(i * 2)) * HeightScale;
            h[i] = v;
            if (v < min) min = v;
            if (v > max) max = v;
        }
        return new TerrainData(h, n, min, max, true, HeightPath(x, y) + ".core");
    }

    /// <summary>
    /// Fallback when a cell has no readable height data: gently rolling terrain (deterministic, continuous across
    /// cells because it is a function of world position).
    /// </summary>
    public static TerrainData Fallback(int x, int y, int res = 257, float baseHeight = 200f)
    {
        var h = new float[res * res];
        float min = float.MaxValue, max = float.MinValue;
        var s = TileSize / (res - 1);
        for (var r = 0; r < res; r++)
            for (var c = 0; c < res; c++)
            {
                double wx = x * TileSize + c * s, wy = (y + 1) * TileSize - r * s;
                var v = (float)(baseHeight + 6 * Math.Sin(wx / 97.0) * Math.Cos(wy / 113.0) + 3 * Math.Sin((wx + wy) / 41.0));
                h[r * res + c] = v;
                min = Math.Min(min, v); max = Math.Max(max, v);
            }
        return new TerrainData(h, res, min, max, false, "fallback");
    }

    /// <summary>Colour of the terrain as seen from above (flattened albedo world-data texture), north-up like the heights.</summary>
    public static Image? ReadAlbedo(Resolver res, int x, int y, int maxPx)
    {
        var file = res.TryFile(AlbedoPath(x, y));
        var texObj = file?.FirstObj("Texture");
        if (texObj is null) return null;
        var tex = HzdTexture.Parse(texObj);
        return tex.Decode(res.Archive, tex.MipFor(maxPx)).Fit(maxPx);
    }

    public static byte[] ToR32(float[] heights)
    {
        var b = new byte[heights.Length * 4];
        Buffer.BlockCopy(heights, 0, b, 0, b.Length);
        return b;
    }
}
