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

    public sealed record Choice(string Key, Image? Color);

    /// <summary>The colour image a render effect uses (null if none found). Key identifies the texture set.</summary>
    public Choice? ForEffect(Obj? effect, Func<string, bool>? acceptPath = null)
    {
        if (effect is null) return null;
        foreach (var set in effect.Structs("TechniqueSets"))
            foreach (var tech in set.Structs("RenderTechniques"))
                foreach (var tb in tech.Structs("TextureBindings"))
                {
                    var r = tb.Ref("TextureResource");
                    if (r.IsNull || r.Path is null) continue;
                    if (acceptPath is not null && !acceptPath(r.Path)) continue;
                    if (!r.Path.Contains("/textures/", StringComparison.Ordinal) && !r.Path.Contains("_set", StringComparison.Ordinal)) continue;
                    var key = $"{r.Path}#{r.Uuid}";
                    var img = _images.GetOrAdd(key, _ => ColorOf(r));
                    if (img is not null) return new Choice(key, img);
                }
        return null;
    }

    private Image? ColorOf(Ref r)
    {
        var file = res.TryFile(r.Path!);
        var target = file?.Find(r.Uuid);
        if (file is null || target is null) return null;
        Obj? set = null;
        if (target.TypeName == "TextureSet") set = file.Decode(target);
        else if (target.TypeName == "Texture")
        {
            // a texture inside a texture set file: only colour (sRGB / Color-packed) entries are used as base colour
            foreach (var s in file.All("TextureSet"))
                if (s.Structs("Entries").Any(e => e.Ref("Texture").Uuid == r.Uuid)) { set = s; break; }
            if (set is null) return null;
        }
        else return null;
        var entry = set.Structs("Entries").FirstOrDefault(e => ((uint)e.Long("PackingInfo") & 0x0F) == 1)
                    ?? set.Structs("Entries").FirstOrDefault(e => e.Int("ColorSpace") == 1);
        if (entry is null) return null;
        if (target.TypeName == "Texture" && entry.Ref("Texture").Uuid != r.Uuid) return null; // effect samples a non-colour texture
        var texObj = res.Deref(file, entry.Ref("Texture"));
        if (texObj is null) return null;
        var tex = HzdTexture.Parse(texObj);
        return tex.Decode(res.Archive, tex.MipFor(maxPx)).Fit(maxPx);
    }
}
