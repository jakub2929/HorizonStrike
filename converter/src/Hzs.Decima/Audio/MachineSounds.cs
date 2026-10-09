using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Decima.Core;
using Hzs.Decima.Sheets;

namespace Hzs.Decima.Audio;

/// <summary>
/// Machine sounds by role. Each machine's effects live in sounds/effects/robots/&lt;internal name&gt;/**/wav/*.core (one
/// WaveResource per file); the soundbanks (sheet sound_banks) play them through graph programs we do not run, so roles
/// are assigned from the wave names (vox_idle, vox_susp, vox_alrt, attack, hit_react, malfunct, footstep ...).
/// Output: hzd/machines/&lt;id&gt;/snd/&lt;role&gt;_&lt;n&gt;.(mp3|wav) plus snd/sounds.json {role: [{file, source, seconds}]}.
/// </summary>
public static class MachineSounds
{
    // ordered wave-name patterns per role and role fallbacks: sheet hzd_content machines.sound_roles / sound_role_fallback
    private static Dictionary<string, string[]> Roles => HzdNames.Json("machines.sound_roles").AsObject()
        .ToDictionary(kv => kv.Key, kv => kv.Value!.AsArray().Select(x => x!.GetValue<string>()).ToArray());

    private static Dictionary<string, string> Fallback => HzdNames.Json("machines.sound_role_fallback").AsObject()
        .ToDictionary(kv => kv.Key, kv => kv.Value!.GetValue<string>());

    public static long Export(Resolver res, string internalName, IEnumerable<string> roles, string outDir, Log log, int? perRoleOverride = null)
    {
        var perRole = perRoleOverride ?? HzdNames.Int("machines.sounds_per_role");
        var patterns = Roles;
        var fallback = Fallback;
        var marker = HzdNames.Str("machines.sound_dir_marker");
        var prefix = HzdNames.Fill("machines.sound_root", ("internal", internalName));
        var waves = res.Archive.Paths.Where(p => p.StartsWith(prefix, StringComparison.Ordinal) && p.Contains(marker, StringComparison.Ordinal))
            .OrderBy(p => p, StringComparer.Ordinal).ToList();
        var snd = Path.Combine(outDir, "snd");
        Directory.CreateDirectory(snd);
        var index = new JsonObject();
        long bytes = 0;
        var picked = new Dictionary<string, List<string>>();
        foreach (var role in patterns.Keys)
        {
            var list = new List<string>();
            foreach (var pat in patterns[role])
                foreach (var w in waves)
                {
                    if (list.Count >= perRole) break;
                    var name = w[(w.LastIndexOf('/') + 1)..];
                    if (name.Contains(pat, StringComparison.OrdinalIgnoreCase) && !list.Contains(w)) list.Add(w);
                }
            picked[role] = list;
        }
        foreach (var role in roles)
        {
            var src = picked.GetValueOrDefault(role) ?? [];
            if (src.Count == 0 && fallback.TryGetValue(role, out var fb)) src = picked.GetValueOrDefault(fb) ?? [];
            var arr = new JsonArray();
            var n = 0;
            foreach (var w in src)
            {
                try
                {
                    var file = res.TryFile(w);
                    var wave = file?.FirstObj("WaveResource");
                    if (wave is null) continue;
                    var e = Waves.Export(res.Archive, wave);
                    if (e is null) continue;
                    var fn = $"{role}_{n++}.{e.Ext}";
                    File.WriteAllBytes(Path.Combine(snd, fn), e.Data);
                    bytes += e.Data.Length;
                    arr.Add(new JsonObject { ["file"] = fn, ["source"] = w, ["seconds"] = Math.Round(e.Seconds, 3) });
                }
                catch (Exception ex) { log.Warn($"sound {w}: {ex.Message}"); }
            }
            if (arr.Count == 0) log.Warn($"{internalName}: no sounds for role {role}");
            index[role] = arr;
        }
        var json = System.Text.Encoding.UTF8.GetBytes(index.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
        File.WriteAllBytes(Path.Combine(snd, "sounds.json"), json);
        return bytes + json.Length;
    }
}
