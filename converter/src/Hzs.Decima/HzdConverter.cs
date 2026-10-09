using Hzs.Common;

namespace Hzs.Decima;

/// <summary>HZD side of the converter (owner: "svet"). Reads the player's HZD install, writes cache/hzd/.</summary>
public static class HzdConverter
{
    /// <summary>Watcher, Strider, Grazer: skinned models with the real skeleton, textures, meta, sounds.</summary>
    public static long ConvertMachines(ConvContext ctx, IProgressSink progress) =>
        throw new NotImplementedException("svet: ConvertMachines");

    /// <summary>World index: cell grid, start cell, campfires, spawn sites (hzd/index.json).</summary>
    public static long BuildIndex(ConvContext ctx, IProgressSink progress) =>
        throw new NotImplementedException("svet: BuildIndex");

    /// <summary>Start cell from hzd/index.json (after BuildIndex).</summary>
    public static (int X, int Y) StartCell(ConvContext ctx) =>
        throw new NotImplementedException("svet: StartCell");

    /// <summary>One world cell: terrain, instances, vegetation, campfires, spawns (hzd/cells/X_Y/).</summary>
    public static long ConvertCell(ConvContext ctx, int x, int y, IProgressSink progress) =>
        throw new NotImplementedException("svet: ConvertCell");

    /// <summary>Horizon music and ambience used by the game.</summary>
    public static long ConvertAudio(ConvContext ctx, IProgressSink progress) =>
        throw new NotImplementedException("svet: ConvertAudio");
}
