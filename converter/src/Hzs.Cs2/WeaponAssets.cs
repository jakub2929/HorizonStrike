using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Generated;
using ValveResourceFormat.ResourceTypes;

namespace Hzs.Cs2;

/// <summary>
/// cache/cs2/weapons/&lt;id&gt;/: world.glb, view.glb (arms + weapon + clips), anim_events.json, icon.svg, snd/.
/// Built in &lt;id&gt;.tmp and moved into place when complete.
/// </summary>
internal sealed class WeaponAssets(ConvContext ctx, Cs2Source src, SoundExport sounds)
{
    private byte[]? _arms;

    /// <summary>Godot space faces -Z; VRF exports face +Z: every exported scene gets a 180 degree turn about Y.</summary>
    private static readonly float[] TurnY180 = [0f, 1f, 0f, 0f];

    public List<string> Convert(WeaponsRow row, JsonObject? stats)
    {
        var problems = new List<string>();
        var target = ctx.Cache.Cs2Weapon(row.Id);
        var dir = Atomic.BeginDir(target);
        var tmp = Path.Combine(dir, ".work");

        // world model: bound world_model (vdata m_szWorldModel / items model_world)
        var worldModel = stats?["world_model"]?.GetValue<string>();
        byte[]? weaponSkinned = null;
        if (string.IsNullOrEmpty(worldModel)) problems.Add("world_model unresolved: no world.glb");
        else
        {
            var world = Glb.Parse(ModelExport.Export(src, worldModel, tmp, withSkeleton: false, ctx.Log, ctx.Ct));
            world.WrapRoots("world", TurnY180);
            File.WriteAllBytes(Path.Combine(dir, "world.glb"), world.ToBytes());
        }

        // viewmodel
        var clipSounds = new List<string>();
        if (row.ViewAnimGraph != "none" && !string.IsNullOrEmpty(worldModel))
        {
            var clipPaths = ViewModel.GraphClips(src, row.ViewAnimGraph);
            var chosen = ViewModel.ChooseClips(src, clipPaths, ctx.Log);
            if (chosen.Count == 0) problems.Add($"no clips found in {row.ViewAnimGraph}");
            weaponSkinned = ModelExport.Export(src, worldModel, tmp, withSkeleton: true, ctx.Log, ctx.Ct);
            _arms ??= ModelExport.Export(src, ViewModel.ArmsModel, tmp, withSkeleton: true, ctx.Log, ctx.Ct);
            var (glb, events, clipProblems) = ViewModel.Build(src, _arms, weaponSkinned, chosen, SoundExport.ShortName, ctx.Log);
            problems.AddRange(clipProblems);
            File.WriteAllBytes(Path.Combine(dir, "view.glb"), glb);
            Atomic.WriteJson(Path.Combine(dir, "anim_events.json"), events);
            clipSounds.AddRange(chosen.SelectMany(c => c.Clip.Events.OfType<ValveResourceFormat.ResourceTypes.ModelAnimation2.NmSoundEvent>().Select(e => e.Name)));
            ctx.Log.Info($"{row.Id}: view clips {string.Join(", ", chosen.Select(c => $"{c.Name}={Path.GetFileName(c.Path)}"))}");
        }

        // icon
        using (var icon = src.Load(row.Icon))
        {
            if (icon?.DataBlock is Panorama svg && svg.Data.Length > 0) File.WriteAllBytes(Path.Combine(dir, "icon.svg"), svg.Data);
            else problems.Add($"icon {row.Icon} not found");
        }

        // sounds: shoot sound + sheet events + every sound the chosen clips play
        var soundEvents = new List<string>();
        if (row.SndShoot != "none") soundEvents.Add(row.SndShoot);
        soundEvents.AddRange(ParseList(row.SndEvents));
        soundEvents.AddRange(clipSounds);
        var used = new Dictionary<string, string>(StringComparer.Ordinal); // short name -> event
        foreach (var ev in soundEvents.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var shortName = SoundExport.ShortName(ev);
            if (used.TryGetValue(shortName, out var other) && !other.Equals(ev, StringComparison.OrdinalIgnoreCase))
            {
                problems.Add($"sound {ev} skipped: short name '{shortName}' already used by {other}");
                continue;
            }
            used[shortName] = ev;
            sounds.Write(ev, shortName, Path.Combine(dir, "snd"), problems);
        }

        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        Atomic.CommitDir(dir, target);
        foreach (var p in problems) ctx.Log.Warn($"{row.Id}: {p}");
        return problems;
    }

    private static IEnumerable<string> ParseList(string json)
    {
        try { return JsonNode.Parse(json)?.AsArray().Select(x => x!.GetValue<string>()).ToList() ?? []; }
        catch { return []; }
    }
}
