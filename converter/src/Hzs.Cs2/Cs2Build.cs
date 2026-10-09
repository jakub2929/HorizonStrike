using System.Text.RegularExpressions;
using Hzs.Common;
using ValveKeyValue;

namespace Hzs.Cs2;

/// <summary>
/// CS2 build id for cache invalidation (sheets/hooks.json steam.cs2_manifest): buildid of
/// &lt;lib&gt;/steamapps/appmanifest_730.acf (= {game}/../../appmanifest_730.acf), fallback game/csgo/steam.inf ClientVersion.
/// </summary>
internal static partial class Cs2Build
{
    public static (long Build, string Source)? Read(string cs2Dir)
    {
        var root = Path.GetFullPath(cs2Dir);
        var acf = Path.GetFullPath(Path.Combine(root, "..", "..", "appmanifest_730.acf"));
        try
        {
            if (File.Exists(acf))
            {
                using var fs = GameFiles.OpenRead(acf);
                var kv = KVSerializer.Create(KVSerializationFormat.KeyValues1Text).Deserialize(fs);
                if (kv.Root.TryGetValue("buildid", out var b) && long.TryParse(b.ToString(), out var build)) return (build, acf);
            }
        }
        catch (Exception)
        {
            // fall through to steam.inf
        }
        var inf = Path.Combine(root, "game", "csgo", "steam.inf");
        if (File.Exists(inf))
        {
            var m = ClientVersion().Match(File.ReadAllText(inf));
            if (m.Success && long.TryParse(m.Groups[1].Value, out var v)) return (v, inf);
        }
        return null;
    }

    [GeneratedRegex(@"ClientVersion\s*=\s*(\d+)")]
    private static partial Regex ClientVersion();
}
