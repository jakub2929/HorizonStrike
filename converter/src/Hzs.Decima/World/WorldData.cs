using Hzs.Decima.Assets;
using Hzs.Decima.Core;

namespace Hzs.Decima.World;

/// <summary>
/// Channels of a tile's world-data maps: a WorldDataTextureMap file holds one Texture and WorldDataTextureMapEntry
/// objects naming which channel carries which WorldDataType (e.g. worlddata/ecotope_effect -> A).
/// </summary>
public static class WorldData
{
    /// <summary>The channel of <paramref name="type"/> in the tile-relative map <paramref name="mapFile"/> as L8 (north up), or null.</summary>
    public static Image? Channel(Resolver res, int x, int y, string mapFile, string type, int maxPx)
    {
        var file = res.TryFile($"{WorldTiles.TileDir(x, y)}/{mapFile}");
        var texObj = file?.FirstObj("Texture");
        if (file is null || texObj is null) return null;
        var entry = file.All("WorldDataTextureMapEntry").FirstOrDefault(e => e.Ref("Type").Path == type);
        if (entry is null) return null;
        var ch = entry.Int("Channel");
        var tex = HzdTexture.Parse(texObj);
        var img = tex.Decode(res.Archive, tex.MipFor(maxPx)).Fit(maxPx);
        if (ch < 0 || ch >= img.Channels) return null;
        var n = img.Width * img.Height;
        var o = new byte[n];
        for (var i = 0; i < n; i++) o[i] = img.Pixels[i * img.Channels + ch];
        return new Image(img.Width, img.Height, 1, o);
    }
}
