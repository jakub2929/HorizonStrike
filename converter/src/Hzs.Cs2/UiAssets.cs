using Hzs.Common;
using ValveResourceFormat.ResourceTypes;

namespace Hzs.Cs2;

/// <summary>
/// cache/cs2/ui/: HUD art and buy wheel sounds (sheets/hooks.json cs2.hud_icons, cs2.ui_sounds):
/// armor.svg, kevlar.svg, snd/buy_&lt;n&gt;.(wav|mp3).
/// </summary>
internal static class UiAssets
{
    private static readonly (string Source, string File)[] Icons =
    [
        ("panorama/images/hud/armor.vsvg_c", "armor.svg"),
        ("panorama/images/icons/equipment/kevlar.vsvg_c", "kevlar.svg"),
    ];

    private static readonly string[] BuySounds =
    [
        "sounds/ui/panorama/radial_menu_buy_01.vsnd_c",
        "sounds/ui/panorama/radial_menu_buy_02.vsnd_c",
        "sounds/ui/panorama/radial_menu_buy_03.vsnd_c",
    ];

    public static string Dir(CachePaths cache) => Path.Combine(cache.Cs2, "ui");

    public static List<string> Convert(ConvContext ctx, Cs2Source src, SoundExport sounds)
    {
        var problems = new List<string>();
        var target = Dir(ctx.Cache);
        var dir = Atomic.BeginDir(target);
        foreach (var (source, file) in Icons)
        {
            using var res = src.Load(source);
            if (res?.DataBlock is Panorama svg && svg.Data.Length > 0) File.WriteAllBytes(Path.Combine(dir, file), svg.Data);
            else problems.Add($"{source} not found");
        }
        var n = 0;
        foreach (var vsnd in BuySounds)
            if (sounds.WriteFile(vsnd, Path.Combine(dir, "snd", $"buy_{n}"), problems)) n++;
        Atomic.CommitDir(dir, target);
        foreach (var p in problems) ctx.Log.Warn($"ui: {p}");
        return problems;
    }
}
