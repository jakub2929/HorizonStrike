using System.Numerics;
using Hzs.Decima.Assets;
using Hzs.Decima.Sheets;

namespace Hzs.Decima.World;

/// <summary>
/// Approximate colour of colourised assets (rocks without a colour map: HZD tints them by ecotope at runtime). The
/// instance's neutral stone is pulled towards the baked terrain colour around it (snowy ground -> lighter, dirt ->
/// browner). Result = linear RGB multiplier for the instance (cell.json instances[].tint), 1 = unchanged.
/// </summary>
public sealed class GroundTint(Image albedo, int cellX, int cellY)
{
    private static readonly float Weight = (float)HzdNames.Num("materials.ground_tint");
    private const float RadiusM = 2f;

    private readonly float _x0 = cellX * TerrainReader.TileSize, _z0 = -(cellY + 1) * TerrainReader.TileSize;

    /// <summary>Tint at Godot position (x, z); null outside the cell.</summary>
    public Vector3? At(float x, float z)
    {
        float u = (x - _x0) / TerrainReader.TileSize, v = (z - _z0) / TerrainReader.TileSize;
        if (u < 0 || u > 1 || v < 0 || v > 1 || albedo.Channels < 3) return null;
        var sum = Vector3.Zero;
        var n = 0;
        var r = RadiusM / TerrainReader.TileSize;
        for (var j = -2; j <= 2; j++)
            for (var i = -2; i <= 2; i++)
            {
                var px = (int)Math.Clamp((u + i * r / 2) * albedo.Width, 0, albedo.Width - 1);
                var py = (int)Math.Clamp((v + j * r / 2) * albedo.Height, 0, albedo.Height - 1);
                var k = (py * albedo.Width + px) * albedo.Channels;
                sum += new Vector3(Lin(albedo.Pixels[k]), Lin(albedo.Pixels[k + 1]), Lin(albedo.Pixels[k + 2]));
                n++;
            }
        var ground = sum / n;
        var stone = new Vector3(Lin(Materials.Stone[0]), Lin(Materials.Stone[1]), Lin(Materials.Stone[2]));
        var t = Vector3.One + Weight * (ground / stone - Vector3.One);
        return Vector3.Clamp(t, new Vector3(0.25f), new Vector3(3f));
    }

    private static float Lin(byte c)
    {
        var s = c / 255f;
        return s <= 0.04045f ? s / 12.92f : MathF.Pow((s + 0.055f) / 1.055f, 2.4f);
    }
}
