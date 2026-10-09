using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Decima.Assets;
using Hzs.Decima.Core;
using Hzs.Decima.Sheets;

namespace Hzs.Decima.World;

/// <summary>
/// Terrain material layers (snow, grass, dirt, rock). HZD blends its terrain layers in per-tile compiled shaders from a
/// texture array (not readable as data), so this is the fallback the plan allows:
/// <list type="bullet">
/// <item>layer textures: one HZD terrain texture set per layer (sheet terrain.layers), shared files
/// hzd/terrain_layers/&lt;name&gt;_{albedo,normal,orm}.dds;</item>
/// <item>per-cell masks.dds (R snow, G grass, B dirt, A rock, sum 1) from HZD world data: snow from the ecotope effect map,
/// rock from the slope of the heights, grass from the undergrowth density, dirt from the roads map and the rest.</item>
/// </list>
/// </summary>
public static class TerrainLayers
{
    public sealed record Layer(string Name, string Set, double TileM);

    public static readonly string[] MaskChannels = ["snow", "grass", "dirt", "rock"];
    private static readonly object Lock = new();

    public static IReadOnlyList<Layer> Defs => HzdNames.Json("terrain.layers").AsArray()
        .Select(l => new Layer(l!["name"]!.GetValue<string>(), l["set"]!.GetValue<string>(), l["tile_m"]!.GetValue<double>())).ToList();

    public static string Dir(CachePaths cache) => Path.Combine(cache.Hzd, "terrain_layers");

    /// <summary>
    /// Writes missing layer textures (once per cache; written again if deleted) and returns cell.json terrain.layers
    /// entries with cache-relative paths.
    /// </summary>
    public static JsonArray EnsureShared(CachePaths cache, Resolver res, StrongBox<long> written)
    {
        var px = HzdNames.Int("terrain.layer_px");
        var dir = Dir(cache);
        var arr = new JsonArray();
        lock (Lock)
        {
            Materials? mats = null;
            foreach (var l in Defs)
            {
                string F(string kind) => Path.Combine(dir, $"{l.Name}_{kind}.dds");
                string Rel(string kind) => $"hzd/terrain_layers/{l.Name}_{kind}.dds";
                if (!File.Exists(F("albedo")))
                {
                    mats ??= new Materials(res, px);
                    var (c, n, o) = mats.SetMaps(l.Set);
                    if (c is not null) Write(F("albedo"), Dds.Encode(c, Dds.Parse(Hzs.Generated.SystemsSheet.RenderTextureFormatAlbedo.Value), true, MipMode.Color), written);
                    if (n is not null) Write(F("normal"), Dds.Encode(n, Dds.Parse(Hzs.Generated.SystemsSheet.RenderTextureFormatNormal.Value), false, MipMode.Normal), written);
                    if (o is not null) Write(F("orm"), Dds.Encode(o, Dds.Parse(Hzs.Generated.SystemsSheet.RenderTextureFormatOrm.Value), false, MipMode.Data), written);
                }
                arr.Add(new JsonObject
                {
                    ["name"] = l.Name,
                    ["albedo"] = File.Exists(F("albedo")) ? Rel("albedo") : null,
                    ["normal"] = File.Exists(F("normal")) ? Rel("normal") : null,
                    ["orm"] = File.Exists(F("orm")) ? Rel("orm") : null,
                    ["tile_m"] = l.TileM,
                    ["source"] = l.Set,
                });
            }
        }
        return arr;
    }

    private static void Write(string target, byte[] data, StrongBox<long> written)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        var tmp = $"{target}.{Environment.ProcessId}.{Environment.CurrentManagedThreadId}.tmp";
        File.WriteAllBytes(tmp, data);
        File.Move(tmp, target, true);
        Interlocked.Add(ref written.Value, data.Length);
    }

    /// <summary>
    /// Blend masks (px x px RGBA, north up; R snow, G grass, B dirt, A rock; bytes sum to 255). Rock takes the slope share
    /// first, snow the effect share of the rest, then grass / dirt split what is left by undergrowth density minus roads.
    /// </summary>
    public static Image Masks(TerrainData t, Image? effect, Image? density, int grassChannel, Image? roads, int px)
    {
        var rules = HzdNames.Json("terrain.mask_rules");
        float[] F(string k) => rules[k]!.AsArray().Select(v => (float)v!.GetValue<double>()).ToArray();
        var snowE = F("snow_effect"); var rockS = F("rock_slope_deg");
        var gain = (float)rules["grass_density_gain"]!.GetValue<double>();
        var o = new byte[px * px * 4];
        var res = t.Res;
        var sp = t.Spacing;
        static float Smooth(float a, float b, float v) { var x = Math.Clamp((v - a) / (b - a), 0f, 1f); return x * x * (3 - 2 * x); }
        static float At(Image? im, int ch, float u, float v)
        {
            if (im is null || ch < 0 || ch >= im.Channels) return 0f;
            var x = Math.Clamp((int)(u * im.Width), 0, im.Width - 1); var y = Math.Clamp((int)(v * im.Height), 0, im.Height - 1);
            return im.Pixels[(y * im.Width + x) * im.Channels + ch] / 255f;
        }
        for (var py = 0; py < px; py++)
            for (var pxx = 0; pxx < px; pxx++)
            {
                float u = (pxx + 0.5f) / px, v = (py + 0.5f) / px;
                int c = Math.Clamp((int)(u * (res - 1) + 0.5f), 0, res - 1), r = Math.Clamp((int)(v * (res - 1) + 0.5f), 0, res - 1);
                float hl = t.Heights[r * res + Math.Max(0, c - 1)], hr = t.Heights[r * res + Math.Min(res - 1, c + 1)];
                float hn = t.Heights[Math.Max(0, r - 1) * res + c], hs = t.Heights[Math.Min(res - 1, r + 1) * res + c];
                var slope = MathF.Atan(MathF.Sqrt(MathF.Pow((hr - hl) / (2 * sp), 2) + MathF.Pow((hs - hn) / (2 * sp), 2))) * 180f / MathF.PI;
                var rock = Smooth(rockS[0], rockS[1], slope);
                var snow = (1 - rock) * Smooth(snowE[0], snowE[1], At(effect, 0, u, v));
                var rest = 1 - rock - snow;
                var g = Math.Clamp(At(density, grassChannel, u, v) * gain - At(roads, 0, u, v), 0f, 1f);
                int bs = (int)MathF.Round(snow * 255), bg = (int)MathF.Round(rest * g * 255), br = (int)MathF.Round(rock * 255);
                var bd = Math.Max(0, 255 - bs - bg - br);
                var i = (py * px + pxx) * 4;
                o[i] = (byte)bs; o[i + 1] = (byte)bg; o[i + 2] = (byte)bd; o[i + 3] = (byte)(255 - bs - bg - bd);
            }
        return new Image(px, px, 4, o);
    }
}
