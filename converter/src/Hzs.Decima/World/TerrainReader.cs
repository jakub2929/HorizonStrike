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
    public static string NormalPath(int x, int y) => $"{WorldTiles.TileDir(x, y)}/{HzdNames.Str("terrain.normal")}";

    /// <summary>
    /// World-space terrain normal in Godot axes as a 2-channel image: R = X (east), G = Z (south), unorm; Y (up) is
    /// rebuilt as sqrt(1 - x^2 - z^2). Source: the tile's terrain normal map (HZD world space R = east, G = north;
    /// checked against the height gradients: corr -0.87 / +0.71 on tile 4,-3), else derived from the heights.
    /// Row 0 = north edge like the heights.
    /// </summary>
    public static (Image Img, string Source) ReadNormal(Resolver res, int x, int y, TerrainData terrain, int maxPx)
    {
        var texObj = res.TryFile(NormalPath(x, y))?.FirstObj("Texture");
        if (texObj is not null)
        {
            try
            {
                var tex = HzdTexture.Parse(texObj);
                var img = tex.Decode(res.Archive, tex.MipFor(maxPx)).Fit(maxPx);
                if (img.Channels >= 2)
                {
                    var n = img.Width * img.Height;
                    var o = new byte[n * 2];
                    for (var i = 0; i < n; i++) { o[i * 2] = img.Pixels[i * img.Channels]; o[i * 2 + 1] = (byte)(255 - img.Pixels[i * img.Channels + 1]); }
                    return (new Image(img.Width, img.Height, 2, o), NormalPath(x, y));
                }
            }
            catch (NotSupportedException) { }
        }
        return (FromHeights(terrain), "heights");
    }

    private static Image FromHeights(TerrainData t)
    {
        int r = t.Res;
        var o = new byte[r * r * 2];
        var s = t.Spacing;
        for (var row = 0; row < r; row++)
            for (var c = 0; c < r; c++)
            {
                float hl = t.Heights[row * r + Math.Max(0, c - 1)], hr = t.Heights[row * r + Math.Min(r - 1, c + 1)];
                float hn = t.Heights[Math.Max(0, row - 1) * r + c], hs = t.Heights[Math.Min(r - 1, row + 1) * r + c];
                var nx = -(hr - hl) / (2 * s); var nz = -(hs - hn) / (2 * s);
                var l = MathF.Sqrt(nx * nx + nz * nz + 1);
                o[(row * r + c) * 2] = (byte)Math.Clamp((nx / l + 1) * 127.5f + 0.5f, 0, 255);
                o[(row * r + c) * 2 + 1] = (byte)Math.Clamp((nz / l + 1) * 127.5f + 0.5f, 0, 255);
            }
        return new Image(r, r, 2, o);
    }

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
        var img = tex.Decode(res.Archive, tex.MipFor(maxPx)).Fit(maxPx);
        if (img.Channels != 4) return img;
        // the bake's alpha is unused (255): RGB keeps the per-cell file smaller
        var rgb = new byte[img.Width * img.Height * 3];
        for (int i = 0, n = img.Width * img.Height; i < n; i++)
        {
            rgb[i * 3] = img.Pixels[i * 4]; rgb[i * 3 + 1] = img.Pixels[i * 4 + 1]; rgb[i * 3 + 2] = img.Pixels[i * 4 + 2];
        }
        return new Image(img.Width, img.Height, 3, rgb);
    }

    public static byte[] ToR32(float[] heights)
    {
        var b = new byte[heights.Length * 4];
        Buffer.BlockCopy(heights, 0, b, 0, b.Length);
        return b;
    }
}
