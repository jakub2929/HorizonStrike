using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Generated;
using ValveResourceFormat.ResourceTypes;

namespace Hzs.Cs2;

/// <summary>
/// cache/cs2/{weapons,knives}/&lt;id&gt;/: world.glb, view.glb (arms + weapon + clips), meta.json (content contract),
/// anim_events.json, icon.svg, snd/.
/// Built in &lt;id&gt;.tmp and moved into place when complete.
/// </summary>
/// <summary>What to convert for one weapon-like item (a weapons sheet row, or a knife found in the CS2 data).</summary>
/// <param name="CacheDir">cache-relative parent folder, '/'-separated (cs2/weapons, cs2/knives)</param>
/// <param name="ExtraInspects">also export lookat02/03 clips as inspect2/inspect3 (knives)</param>
/// <param name="Sheet">sheet row whose contract columns the found meta.json is compared with (null: no sheet row)</param>
internal sealed record AssetSpec(string Id, string CacheDir, string? WorldModel, string ViewAnimGraph, string Icon,
    string SndShoot, IReadOnlyList<string> SndEvents, bool Suppressed, bool ExtraInspects, WeaponsRow? Sheet)
{
    public static AssetSpec FromRow(WeaponsRow row, string? worldModel) =>
        new(row.Id, "cs2/weapons", worldModel, row.ViewAnimGraph, row.Icon, row.SndShoot, ParseList(row.SndEvents), row.Suppressed, false, row);

    public static IReadOnlyList<string> ParseList(string json)
    {
        try { return JsonNode.Parse(json)?.AsArray().Select(x => x!.GetValue<string>()).ToList() ?? []; }
        catch { return []; }
    }
}

/// <summary>Result of one item: problems (warnings) and the clip names in view.glb.</summary>
internal sealed record AssetResult(List<string> Problems, List<string> Clips);

internal sealed class WeaponAssets(ConvContext ctx, Cs2Source src, SoundExport sounds)
{
    private byte[]? _arms;

    /// <summary>Godot space faces -Z; VRF exports face +Z: every exported scene gets a 180 degree turn about Y.</summary>
    private static readonly float[] TurnY180 = [0f, 1f, 0f, 0f];

    public List<string> Convert(WeaponsRow row, JsonObject? stats) =>
        Convert(AssetSpec.FromRow(row, stats?["world_model"]?.GetValue<string>())).Problems;

    public string TargetDir(AssetSpec spec) =>
        Path.Combine(ctx.Cache.Root, Path.Combine(spec.CacheDir.Split('/')), spec.Id);

    public AssetResult Convert(AssetSpec spec)
    {
        var problems = new List<string>();
        var clips = new List<string>();
        var target = TargetDir(spec);
        var dir = Atomic.BeginDir(target);
        try
        {
            ConvertInto(spec, dir, problems, clips);
        }
        catch
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, true); // our own temp folder; the old result stays
            throw;
        }
        Atomic.CommitDir(dir, target);
        foreach (var p in problems) ctx.Log.Warn($"{spec.Id}: {p}");
        return new AssetResult(problems, clips);
    }

    private void ConvertInto(AssetSpec spec, string dir, List<string> problems, List<string> clips)
    {
        var tmp = Path.Combine(dir, ".work");

        // world model: bound world_model (vdata m_szWorldModel / items model_world)
        var worldModel = spec.WorldModel;
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
        string? attachBone = null, primarySkeleton = null, secondarySkeleton = null;
        var hasView = false;
        if (spec.ViewAnimGraph != "none" && !string.IsNullOrEmpty(worldModel))
        {
            var clipPaths = ViewModel.GraphClips(src, spec.ViewAnimGraph);
            var chosen = ViewModel.ChooseClips(src, clipPaths, ctx.Log, spec.ExtraInspects);
            if (chosen.Count == 0) throw new InvalidDataException($"{spec.Id}: no clips found in {spec.ViewAnimGraph}");
            // the arms bone the weapon hangs on comes from the clip skeleton's secondary-skeleton attachment
            primarySkeleton = chosen[0].Clip.SkeletonName;
            secondarySkeleton = chosen[0].Clip.SecondaryAnimations.FirstOrDefault()?.SkeletonName;
            attachBone = secondarySkeleton is null ? null : WeaponMeta.AttachBone(src, primarySkeleton, secondarySkeleton);
            if (attachBone is null) throw new InvalidDataException($"{spec.Id}: no attach bone for {secondarySkeleton} in {primarySkeleton}");
            weaponSkinned = ModelExport.Export(src, worldModel, tmp, withSkeleton: true, ctx.Log, ctx.Ct);
            _arms ??= ModelExport.Export(src, ViewModel.ArmsModel, tmp, withSkeleton: true, ctx.Log, ctx.Ct);
            var (glb, events, clipProblems) = ViewModel.Build(src, _arms, weaponSkinned, attachBone, chosen, SoundExport.ShortName, ctx.Log);
            hasView = true;
            problems.AddRange(clipProblems);
            File.WriteAllBytes(Path.Combine(dir, "view.glb"), glb);
            Atomic.WriteJson(Path.Combine(dir, "anim_events.json"), events);
            clipSounds.AddRange(chosen.SelectMany(c => c.Clip.Events.OfType<ValveResourceFormat.ResourceTypes.ModelAnimation2.NmSoundEvent>().Select(e => e.Name)));
            clips.AddRange(chosen.Select(c => c.Name));
            ctx.Log.Info($"{spec.Id}: view clips {string.Join(", ", chosen.Select(c => $"{c.Name}={Path.GetFileName(c.Path)}"))}");
        }

        // content contract (meta.json): what the models hold; the sheet columns are compared against it
        var meta = WeaponMeta.Build(src, spec, string.IsNullOrEmpty(worldModel) ? null : worldModel, hasView, attachBone,
            primarySkeleton, secondarySkeleton, problems);
        Atomic.WriteJson(Path.Combine(dir, "meta.json"), meta);

        // icon
        using (var icon = src.Load(spec.Icon))
        {
            if (icon?.DataBlock is Panorama svg && svg.Data.Length > 0) File.WriteAllBytes(Path.Combine(dir, "icon.svg"), svg.Data);
            else problems.Add($"icon {spec.Icon} not found");
        }

        // sounds: shoot sound + sheet events + every sound the chosen clips play
        var soundEvents = new List<string>();
        if (spec.SndShoot != "none") soundEvents.Add(spec.SndShoot);
        soundEvents.AddRange(spec.SndEvents);
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
    }
}
