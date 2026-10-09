using System.Collections.Concurrent;
using Hzs.Decima.Core;

using Hzs.Decima.Sheets;

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
    private static readonly string[] Tiers = HzdNames.List("materials.tiers");
    private static readonly string[] Bad = HzdNames.List("materials.never_base_color");
    private static readonly string[] Standalone = HzdNames.List("materials.standalone_color");
    private readonly ConcurrentDictionary<Ref, bool> _alphaSets = new();

    /// <summary>Key of the texture; Colorized = no colour map, neutral stone x AO (HZD colours these by ecotope at runtime).</summary>
    public sealed record Choice(string Key, Image? Color, bool Colorized);

    /// <summary>sRGB base of colourised (AO-only) assets.</summary>
    public static readonly byte[] Stone = [140, 134, 124];

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
        // cut-out mask bound next to the colour map (e.g. grass: colour + translucency texture and an alpha-only set)
        Ref? alphaRef = refs.FirstOrDefault(HasAlpha) is { Path: not null } ar ? ar : null;
        // per source tier (asset folder, shared shader libraries, texture library): 1) the colour map of a bound texture
        // set; 2) assets coloured by the ecotope shader at runtime (rocks) have no colour map, only normal + AO:
        // neutral stone x AO. Detail/noise/pattern maps are never used as base colour.
        for (var tier = 0; tier < Tiers.Length; tier++)
            foreach (var pass in new[] { 1, 2 })
                foreach (var r in refs.Where(x => Tier(x.Path!) == tier))
                {
                    var key = pass == 1 && alphaRef is { } a && a != r ? $"1:{r.Path}#{r.Uuid}+{a.Path}#{a.Uuid}" : $"{pass}:{r.Path}#{r.Uuid}";
                    if (_ok.TryGetValue(key, out var ok))
                    {
                        if (!ok) continue;
                        if (known?.Invoke(key) == true) return new Choice(key, null, pass == 2);
                    }
                    var img = _images.GetOrAdd(key, _ => pass == 1 ? ColorOf(r, alphaRef) : AoStone(r));
                    _ok[key] = img is not null;
                    if (img is not null)
                    {
                        if (_images.Count > 48) _images.Clear(); // bounded: callers that keep results pass `known`
                        return new Choice(key, img, pass == 2);
                    }
                    _images.TryRemove(key, out _);
                }
        return null;
    }

    /// <summary>0 = the asset's own textures (models/), 1 = shared shader libraries, 2 = texture library; -1 = never base colour.</summary>
    private static int Tier(string path)
    {
        if (Bad.Any(b => path.Contains(b, StringComparison.OrdinalIgnoreCase))) return -1;
        for (var i = 0; i < Tiers.Length; i++) if (path.StartsWith(Tiers[i], StringComparison.Ordinal)) return i;
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

    /// <summary>True when the ref is (or lies in) a texture set with a channel of type Alpha.</summary>
    private bool HasAlpha(Ref r) => _alphaSets.GetOrAdd(r, k =>
        SetOf(k, out _) is { } set && set.Structs("Entries").Any(e => ChannelOf(e, 2) >= 0));

    /// <summary>
    /// Colour map of a texture set entry of type Color, or a standalone colour texture (name marked in the sheet; its
    /// alpha holds translucency, not a mask). Alpha = the set's channel of type Alpha, else the effect's alpha-only set.
    /// </summary>
    private Image? ColorOf(Ref r, Ref? alphaRef)
    {
        var set = SetOf(r, out var file);
        Image color;
        var colorIdx = -1;
        if (set is null)
        {
            if (file is null || !Standalone.Any(m => r.Path!.Contains(m, StringComparison.OrdinalIgnoreCase))) return null;
            if (res.Target(file, r)?.TypeName != "Texture" || res.Deref(file, r) is not { } t) return null;
            var st = HzdTexture.Parse(t);
            color = st.Decode(res.Archive, st.MipFor(maxPx)).Fit(maxPx);
        }
        else
        {
            var entries = set.Structs("Entries").ToList();
            colorIdx = entries.FindIndex(e => ((uint)e.Long("PackingInfo") & 0x0F) == 1);
            if (colorIdx < 0) colorIdx = entries.FindIndex(e => e.Int("ColorSpace") == 1);
            if (colorIdx < 0) return null;
            var texObj = res.Deref(file!, entries[colorIdx].Ref("Texture"));
            if (texObj is null) return null;
            var tex = HzdTexture.Parse(texObj);
            color = tex.Decode(res.Archive, tex.MipFor(maxPx)).Fit(maxPx);
        }
        // the cut-out mask is a channel of type Alpha (2), often a BC4 entry of its own. Any other alpha content of the
        // colour map (unused, translucency, height ...) is dropped so it never cuts holes.
        if (set is not null && AlphaOf(set, file!, colorIdx, color) is { } own) return own;
        if (alphaRef is { } ar && SetOf(ar, out var af) is { } aset && AlphaOf(aset, af!, -1, color) is { } bound) return bound;
        return Rgb(color);
    }

    private Image? AlphaOf(Obj set, CoreFile file, int colorIdx, Image color)
    {
        var entries = set.Structs("Entries").ToList();
        for (var i = 0; i < entries.Count; i++)
        {
            var e = entries[i];
            var ch = ChannelOf(e, 2);
            if (ch < 0) continue;
            Image a;
            if (i == colorIdx) a = color;
            else
            {
                var aObj = res.Deref(file, e.Ref("Texture"));
                if (aObj is null) continue;
                var at = HzdTexture.Parse(aObj);
                var px = Math.Max(color.Width, color.Height);
                a = at.Decode(res.Archive, at.MipFor(px)).Fit(px);
            }
            if (ch >= a.Channels) continue;
            return WithAlpha(color, a, ch);
        }
        return null;
    }

    /// <summary>RGB of <paramref name="color"/> plus channel <paramref name="ch"/> of <paramref name="a"/> as alpha (nearest sample when sizes differ).</summary>
    private static Image WithAlpha(Image color, Image a, int ch)
    {
        int w = color.Width, h = color.Height;
        var rgba = new byte[w * h * 4];
        for (var y = 0; y < h; y++)
        {
            var ay = (int)((long)y * a.Height / h);
            for (var x = 0; x < w; x++)
            {
                var i = y * w + x;
                var ai = ay * a.Width + (int)((long)x * a.Width / w);
                for (var k = 0; k < 3; k++) rgba[i * 4 + k] = color.Pixels[i * color.Channels + Math.Min(k, color.Channels - 1)];
                rgba[i * 4 + 3] = a.Pixels[ai * a.Channels + ch];
            }
        }
        return new Image(w, h, 4, rgba);
    }

    private static Image Rgb(Image color)
    {
        if (color.Channels == 3) return color;
        var n = color.Width * color.Height;
        var rgb = new byte[n * 3];
        for (var i = 0; i < n; i++)
            for (var k = 0; k < 3; k++) rgb[i * 3 + k] = color.Pixels[i * color.Channels + Math.Min(k, color.Channels - 1)];
        return new Image(color.Width, color.Height, 3, rgb);
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
                o[i * 3] = (byte)(Stone[0] * k); o[i * 3 + 1] = (byte)(Stone[1] * k); o[i * 3 + 2] = (byte)(Stone[2] * k);
            }
            return new Image(img.Width, img.Height, 3, o);
        }
        return null;
    }
}
