using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Decima.Core;

namespace Hzs.Decima.Audio;

/// <summary>
/// Machine sounds by role. Each machine's effects live in sounds/effects/robots/&lt;internal name&gt;/**/wav/*.core (one
/// WaveResource per file); the soundbanks (sheet sound_banks) play them through graph programs we do not run, so roles
/// are assigned from the wave names (vox_idle, vox_susp, vox_alrt, attack, hit_react, malfunct, footstep ...).
/// Output: hzd/machines/&lt;id&gt;/snd/&lt;role&gt;_&lt;n&gt;.(mp3|wav) plus snd/sounds.json {role: [{file, source, seconds}]}.
/// </summary>
public static class MachineSounds
{
    // ordered patterns per role (substring match on the wave file name); first patterns win
    private static readonly Dictionary<string, string[]> Roles = new()
    {
        ["idle"] = ["vox_idle", "idle_grunt", "idle_loop", "vox_snort", "horse_vox", "rndm_vox", "vox_grty", "chitter", "vox_borg"],
        ["graze"] = ["grass_processor", "ripgrass", "procesing", "harvester_burp"],
        ["scan"] = ["scan"],
        ["suspicious"] = ["vox_susp", "vox_tst", "vox_a_", "start_whinney", "vox_rise", "vox_noise"],
        ["alert"] = ["vox_alrt", "vox_alerted", "harvester_scream", "vox_b_", "jump_whine", "scout_call", "vox_speedup"],
        ["attack"] = ["vox_attck", "vox_attack", "attkick", "attbackkick", "attack_", "pre_attack", "vox_agr", "bucking", "blade_drill", "back_swipe", "front_kick", "combat_charge", "swipe"],
        ["hit"] = ["hit_react", "hit_pain_short", "hitmove", "hr_knockdown", "stumble", "hit_fall"],
        ["death"] = ["kill", "pain_long", "malfunct", "death"],
        ["footstep"] = ["footstep", "walk_dirt", "walk_grass", "step_extr", "fts_"],
    };

    private static readonly Dictionary<string, string> Fallback = new() { ["scan"] = "idle", ["graze"] = "idle", ["suspicious"] = "alert", ["death"] = "hit" };

    public static long Export(Resolver res, string internalName, IEnumerable<string> roles, string outDir, Log log, int perRole = 6)
    {
        var prefix = $"sounds/effects/robots/{internalName}/";
        var waves = res.Archive.Paths.Where(p => p.StartsWith(prefix, StringComparison.Ordinal) && p.Contains("/wav/", StringComparison.Ordinal))
            .OrderBy(p => p, StringComparer.Ordinal).ToList();
        var snd = Path.Combine(outDir, "snd");
        Directory.CreateDirectory(snd);
        var index = new JsonObject();
        long bytes = 0;
        var picked = new Dictionary<string, List<string>>();
        foreach (var role in Roles.Keys)
        {
            var list = new List<string>();
            foreach (var pat in Roles[role])
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
            if (src.Count == 0 && Fallback.TryGetValue(role, out var fb)) src = picked.GetValueOrDefault(fb) ?? [];
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
