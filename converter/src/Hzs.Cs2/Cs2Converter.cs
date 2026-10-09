using Hzs.Common;

namespace Hzs.Cs2;

/// <summary>CS2 side of the converter (owner: "cs2"). Reads the player's CS2 install, writes cache/cs2/.</summary>
public static class Cs2Converter
{
    /// <summary>Weapons (stats, world + view models, sounds, icons) for every row of sheets/weapons.json.</summary>
    public static long ConvertWeapons(ConvContext ctx, IProgressSink progress)
    {
        throw new NotImplementedException("cs2: ConvertWeapons");
    }

    /// <summary>True when the cache already holds weapons converted from this CS2 build.</summary>
    public static bool IsUpToDate(ConvContext ctx) => false;
}
