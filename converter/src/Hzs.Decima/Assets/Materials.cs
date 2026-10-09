using System.Collections.Concurrent;
using Hzs.Decima.Core;

namespace Hzs.Decima.Assets;

/// <summary>
/// Finds the texture set a render effect samples (TextureBindings -> Texture or TextureSet) and decodes its colour
/// texture. A TextureSetEntry's PackingInfo holds one byte per output channel: low nibble = ETextureSetType of the
/// source (1 Color, 3 Normal, 6 Roughness ...), high nibble = source channel; 0x80 = unused.
/// </summary>
public sealed class Materials(Resolver res, int maxPx)
{
    private readonly ConcurrentDictionary<string, Image?> _images = new();
    private readonly ConcurrentDictionary<string, bool> _ok = new();

    public sealed record Choice(string Key, Image? Color);

    /// <summary>
    /// The colour image a render effect uses (null if none found). Key identifies the texture set. When
    /// <paramref name="known"/> says the caller already has the key's texture, the image is not decoded (Color null).
    /// </summary>
    public Choice? ForEffect(Obj? effect, Func<string, bool>? acceptPath = null, Func<string, bool>? known = null)
    {
        if (effect is null) return null;
        var refs = new List<Ref>();
        foreach (var set in effect.Structs("TechniqueSets"))
            foreach (var tech in set.Structs("RenderTechniques"))
                foreach (var tb in tech.Structs("TextureBindings"))
                {
                    var r = tb.Ref("TextureResource");
                    if (r.IsNull || r.Path is null) continue;
                    if (acceptPath is not null && !acceptPath(r.Path)) continue;
                    if (Tier(r.Path) < 0) continue;
                    if (!refs.Contains(r)) refs.Add(r);
                }
        // per source tier (asset folder, shared shader libraries, texture library): 1) the colour map of a bound texture
        // set; 2) assets coloured by the ecotope shader at runtime (rocks) have no colour map, only normal + AO:
        // neutral stone x AO. Detail/noise/pattern maps are never used as base colour.
        foreach (var tier in new[] { 0, 1, 2 })
            foreach (var pass in new[] { 1, 2 })
                foreach (var r in refs.Where(x => Tier(x.Path!) == tier))
                {
                    var key = $"{pass}:{r.Path}#{r.Uuid}";
                    if (_ok.TryGetValue(key, out var ok))
                    {
                        if (!ok) continue;
                        if (known?.Invoke(key) == true) return new Choice(key, null);
                    }
                    var img = _images.GetOrAdd(key, _ => pass == 1 ? ColorOf(r) : AoStone(r));
                    _ok[key] = img is not null;
                    if (img is not null)
                    {
                        if (_images.Count > 48) _images.Clear(); // bounded: callers that keep results pass `known`
                        return new Choice(key, img);
                    }
                    _images.TryRemove(key, out _);
                }
        return null;
    }

    /// <summary>0 = the asset's own textures (models/), 1 = shared shader libraries, 2 = texture library; -1 = never base colour.</summary>
    private static int Tier(string path)
    {
        string[] bad = ["detail", "noise", "pattern", "sparkle", "colorize", "anisoramp", "frost", "rain", "_msk", "_nmt", "/fx/"];
        if (bad.Any(b => path.Contains(b, StringComparison.OrdinalIgnoreCase))) return -1;
        if (path.StartsWith("models/", StringComparison.Ordinal)) return 0;
        if (path.StartsWith("shader_libraries/", StringComparison.Ordinal)) return 1;
        if (path.StartsWith("textures/", StringComparison.Ordinal)) return 2;
        return -1;
    }

    private Obj? SetOf(Ref r, out CoreFile? file)
    {
        file = res.TryFile(r.Path!);
        var target = file?.Find(r.Uuid);
        if (file is null || target is null) return null;
        if (target.TypeName == "TextureSet") return file.Decode(target);
        if (target.TypeName != "Texture") return null;
        foreach (var s in file.All("TextureSet"))
            if (s.Structs("Entries").Any(e => e.Ref("Texture").Uuid == r.Uuid)) return s;
        return null;
    }

    private static int ChannelOf(Obj entry, int type)
    {
        var p = (uint)entry.Long("PackingInfo");
        for (var c = 0; c < 4; c++) if (((p >> (c * 8)) & 0x0F) == type) return c;
        return -1;
    }

    private Image? ColorOf(Ref r)
    {
        var set = SetOf(r, out var file);
        if (set is null) return null;
        var entry = set.Structs("Entries").FirstOrDefault(e => ((uint)e.Long("PackingInfo") & 0x0F) == 1)
                    ?? set.Structs("Entries").FirstOrDefault(e => e.Int("ColorSpace") == 1);
        if (entry is null) return null;
        var texObj = res.Deref(file!, entry.Ref("Texture"));
        if (texObj is null) return null;
        var tex = HzdTexture.Parse(texObj);
        var color = tex.Decode(res.Archive, tex.MipFor(maxPx)).Fit(maxPx);
        // foliage: the cut-out mask is a separate channel of type Alpha (2), often in another entry of the set
        foreach (var e in set.Structs("Entries"))
        {
            var ch = ChannelOf(e, 2);
            if (ch < 0) continue;
            if (ReferenceEquals(e, entry) && ch == 3 && color.Channels == 4) break; // already in the colour map's alpha
            var aObj = res.Deref(file!, e.Ref("Texture"));
            if (aObj is null) break;
            var at = HzdTexture.Parse(aObj);
            var a = at.Decode(res.Archive, at.MipFor(maxPx)).Fit(maxPx);
            if (ch >= a.Channels) break;
            if (a.Width != color.Width || a.Height != color.Height) break;
            var rgba = new byte[color.Width * color.Height * 4];
            for (var i = 0; i < color.Width * color.Height; i++)
            {
                for (var k = 0; k < 3; k++) rgba[i * 4 + k] = color.Pixels[i * color.Channels + Math.Min(k, color.Channels - 1)];
                rgba[i * 4 + 3] = a.Pixels[i * a.Channels + ch];
            }
            return new Image(color.Width, color.Height, 4, rgba);
        }
        return color;
    }

    private Image? AoStone(Ref r)
    {
        var set = SetOf(r, out var file);
        if (set is null) return null;
        foreach (var e in set.Structs("Entries"))
        {
            var ch = ChannelOf(e, 5); // AO
            if (ch < 0) continue;
            var texObj = res.Deref(file!, e.Ref("Texture"));
            if (texObj is null) continue;
            var tex = HzdTexture.Parse(texObj);
            var img = tex.Decode(res.Archive, tex.MipFor(maxPx)).Fit(maxPx);
            if (ch >= img.Channels) continue;
            var o = new byte[img.Width * img.Height * 3];
            for (var i = 0; i < img.Width * img.Height; i++)
            {
                var ao = img.Pixels[i * img.Channels + ch] / 255f;
                var k = 0.35f + 0.65f * ao;
                o[i * 3] = (byte)(140 * k); o[i * 3 + 1] = (byte)(134 * k); o[i * 3 + 2] = (byte)(124 * k);
            }
            return new Image(img.Width, img.Height, 3, o);
        }
        return null;
    }
}
