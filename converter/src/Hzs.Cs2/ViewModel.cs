using System.Numerics;
using System.Text.Json.Nodes;
using Hzs.Common;
using SharpGLTF.Schema2;
using ValveResourceFormat.ResourceTypes;
using ValveResourceFormat.ResourceTypes.ModelAnimation;
using ValveResourceFormat.ResourceTypes.ModelAnimation2;
using ValveResourceFormat.Serialization.KeyValues;

namespace Hzs.Cs2;

/// <summary>A viewmodel clip chosen for one of the game's clip names (draw, idle, fire, reload, inspect, ...).</summary>
internal sealed record ChosenClip(string Name, string Path, AnimationClip Clip);

/// <summary>
/// First-person viewmodel: CS2 arms (weapons/models/shared/arms/weapon_arms.vmdl, skeleton viewmodel.vnmskel)
/// + the weapon model attached to the arms bone named by viewmodel.vnmskel m_secondarySkeletons (attach bone),
/// animated with the real AnimGraph2 clips of the weapon's graph.
/// </summary>
internal static class ViewModel
{
    public const string ArmsModel = "weapons/models/shared/arms/weapon_arms.vmdl";
    private const float Scale = 0.0254f; // CS2 inch -> m

    // VRF's glTF conversion (Z-up -> Y-up), applied on skeleton roots; see GltfModelExporter.Conversion.
    private static readonly Quaternion SourceToGltf = Quaternion.CreateFromYawPitchRoll(0, MathF.PI / -2f, MathF.PI / -2f);

    /// <summary>Clip names in view.glb -> leaf-name prefixes tried in order (shortest matching leaf wins).</summary>
    private static readonly (string Name, string[] Prefixes)[] ClipRules =
    [
        ("draw", ["draw_"]),
        ("idle", ["idle_", "idle1_"]),
        ("fire", ["shoot1_", "shoot_", "light_miss1_", "throw_overhand_", "throw_"]),
        ("fire2", ["heavy_miss1_"]),
        ("pullpin", ["pullpin_"]),
        ("reload", ["reload_"]),
        ("inspect", ["lookat01_", "lookat_"]),
    ];

    /// <summary>Further inspect variants (knives: e.g. the butterfly has lookat01..03).</summary>
    private static readonly (string Name, string[] Prefixes)[] ExtraInspectRules =
    [
        ("inspect2", ["lookat02_"]),
        ("inspect3", ["lookat03_"]),
    ];

    /// <summary>All clips referenced by a graph (recursing into nested graphs), in first-seen order.</summary>
    public static List<string> GraphClips(Cs2Source src, string graph)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void Walk(string g)
        {
            if (!seen.Add(g)) return;
            using var r = src.Load(g.EndsWith("_c") ? g : g + "_c");
            if (r?.DataBlock is not BinaryKV3 kv) return;
            foreach (var res in kv.Data.Root.GetArray<string>("m_resources") ?? [])
            {
                if (res.EndsWith(".vnmgraph", StringComparison.OrdinalIgnoreCase)) Walk(res);
                else if (res.EndsWith(".vnmclip", StringComparison.OrdinalIgnoreCase) && seen.Add(res)) result.Add(res);
            }
        }
        Walk(graph);
        return result;
    }

    public static List<ChosenClip> ChooseClips(Cs2Source src, IReadOnlyList<string> clips, Log log, bool extraInspects = false)
    {
        var chosen = new List<ChosenClip>();
        foreach (var (name, prefixes) in extraInspects ? ClipRules.Concat(ExtraInspectRules) : ClipRules)
        {
            string? pick = null;
            foreach (var prefix in prefixes)
            {
                pick = clips
                    .Where(c => Path.GetFileName(c).StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                                && !Path.GetFileName(c).Contains("_from_activity", StringComparison.OrdinalIgnoreCase))
                    .OrderBy(c => Path.GetFileName(c).Length).ThenBy(c => c, StringComparer.Ordinal)
                    .FirstOrDefault();
                if (pick is not null) break;
            }
            if (pick is null) continue;
            using var res = src.Load(pick + "_c");
            if (res?.DataBlock is not AnimationClip clip) { log.Warn($"clip {pick} could not be loaded"); continue; }
            chosen.Add(new ChosenClip(name, pick, clip));
        }
        return chosen;
    }

    /// <summary>
    /// Merge arms + weapon GLBs, attach the weapon root under "wpn", turn the whole model to Godot's -Z forward,
    /// and write one glTF animation per chosen clip. Returns the GLB bytes and the anim events per clip.
    /// </summary>
    public static (byte[] Glb, JsonObject Events, List<string> Problems) Build(Cs2Source src, byte[] armsGlb, byte[] weaponGlb,
        string attachBone, IReadOnlyList<ChosenClip> clips, Func<string, string> eventName, Log log)
    {
        var problems = new List<string>();
        var arms = Glb.Parse(armsGlb);
        var weapon = Glb.Parse(weaponGlb);
        var wpn = arms.FindNode(attachBone);
        if (wpn < 0) throw new InvalidDataException($"arms model has no '{attachBone}' bone");
        // weapon scene roots: the skeleton container (no mesh) goes under wpn, skinned mesh nodes stay roots
        arms.Append(weapon, n => n["mesh"] is null, wpn);
        // -Z forward (docs/ARCHITECTURE.md): VRF's export faces +Z, so turn 180 degrees about Y
        arms.WrapRoots("view", [0f, 1f, 0f, 0f]);

        var model = ModelRoot.ParseGLB(arms.ToBytes(), new ReadSettings { Validation = SharpGLTF.Validation.ValidationMode.Skip });
        var allNodes = model.LogicalNodes.ToList();
        var wpnNode = allNodes.First(n => n.Name == attachBone);
        // weapon bones live below wpn (after the merge); arms bones are everything else
        var weaponNodes = Descendants(wpnNode).Where(n => n != wpnNode).GroupBy(n => n.Name ?? "").ToDictionary(g => g.Key, g => g.First());
        var armsNodes = allNodes.Where(n => !weaponNodes.ContainsValue(n)).Where(n => n.Name is not null)
            .GroupBy(n => n.Name!).ToDictionary(g => g.Key, g => g.First());

        // the weapon root's rest = its clip bind pose (identity relative to wpn)
        var events = new JsonObject();
        Pose? idleBase = null;
        var skeletons = new Dictionary<string, Skeleton>(StringComparer.OrdinalIgnoreCase);
        Skeleton Skel(string name) => skeletons.TryGetValue(name, out var s) ? s
            : skeletons[name] = Skeleton.FromSkeletonResource(src.Loader, name) ?? throw new InvalidDataException($"skeleton {name} not found");

        // additive clips are composed over the first idle pose (not the bind pose, which is an A-pose)
        var idle = clips.FirstOrDefault(c => c.Name == "idle" && !c.Clip.IsAdditive);
        if (idle is not null && clips.Any(c => c.Clip.IsAdditive)) idleBase = FirstPose(idle.Clip, Skel(idle.Clip.SkeletonName));

        foreach (var c in clips)
        {
            try
            {
                var anim = model.CreateAnimation(c.Name);
                var primary = Skel(c.Clip.SkeletonName);
                WriteClip(anim, c.Clip, primary, armsNodes, isAttached: false, c.Clip.IsAdditive ? idleBase : null);
                if (c.Clip.IsAdditive && idleBase is null) problems.Add($"{c.Name}: additive clip composed over the bind pose (no idle clip)");
                foreach (var sec in c.Clip.SecondaryAnimations)
                    WriteClip(anim, sec, Skel(sec.SkeletonName), weaponNodes, isAttached: true, null);

                var list = new JsonArray();
                foreach (var e in c.Clip.Events.OfType<NmSoundEvent>().OrderBy(e => e.StartTime))
                    list.Add(new JsonObject { ["t"] = MathF.Round(e.StartTime, 4), ["event"] = eventName(e.Name) });
                events[c.Name] = list;
            }
            catch (Exception ex)
            {
                problems.Add($"{c.Name} ({c.Path}): {ex.Message}");
                log.Warn($"viewmodel clip {c.Path} skipped: {ex}");
            }
        }

        var result = Glb.Parse(model.WriteGLB());
        result.Compact();
        return (result.ToBytes(), events, problems);
    }

    private static IEnumerable<Node> Descendants(Node n)
    {
        yield return n;
        foreach (var c in n.VisualChildren)
            foreach (var d in Descendants(c)) yield return d;
    }

    /// <summary>Local pose per bone name (source units), used as the base of additive clips.</summary>
    private sealed class Pose : Dictionary<string, FrameBone>;

    private static Pose FirstPose(AnimationClip clip, Skeleton skel)
    {
        var frame = new Frame(skel, []) { FrameIndex = 0 };
        new ClipAnimation(clip).DecodeFrame(frame);
        var pose = new Pose();
        foreach (var b in skel.Bones) pose[b.Name] = frame.Bones[b.Index];
        return pose;
    }

    private static void WriteClip(SharpGLTF.Schema2.Animation anim, AnimationClip clip, Skeleton skel, Dictionary<string, Node> nodes,
        bool isAttached, Pose? additiveBase)
    {
        var va = new ClipAnimation(clip);
        var frame = new Frame(skel, []);
        var frames = Math.Max(1, va.FrameCount);
        // VRF reports 1 fps for single-pose clips; CS2 clips are authored at 30 fps
        var fps = frames > 1 && va.Fps > 0 ? va.Fps : 30f;
        var rot = new Dictionary<float, Quaternion>[skel.Bones.Length];
        var pos = new Dictionary<float, Vector3>[skel.Bones.Length];
        var scl = new Dictionary<float, Vector3>[skel.Bones.Length];
        var anyScale = new bool[skel.Bones.Length];
        var last = new Quaternion[skel.Bones.Length];
        for (var i = 0; i < skel.Bones.Length; i++) { rot[i] = []; pos[i] = []; scl[i] = []; }

        for (var f = 0; f < frames; f++)
        {
            frame.FrameIndex = f;
            va.DecodeFrame(frame);
            var t = f / fps;
            foreach (var bone in skel.Bones)
            {
                var fb = frame.Bones[bone.Index];
                if (clip.IsAdditive)
                {
                    var b = additiveBase is not null && additiveBase.TryGetValue(bone.Name, out var bb) ? bb
                        : new FrameBone(bone.Position, 1f, bone.Angle);
                    fb = new FrameBone(b.Position + fb.Position, b.Scale + fb.Scale, b.Angle * fb.Angle);
                }

                var p = fb.Position * Scale;
                var q = fb.Angle;
                if (bone.Parent is null && !isAttached)
                {
                    p = Vector3.Transform(p, SourceToGltf);
                    q = SourceToGltf * q;
                }
                q = Quaternion.Normalize(q);
                if (f > 0 && Quaternion.Dot(q, last[bone.Index]) < 0) q = Quaternion.Negate(q); // keep the shortest path
                last[bone.Index] = q;
                rot[bone.Index][t] = q;
                pos[bone.Index][t] = p;
                scl[bone.Index][t] = new Vector3(fb.Scale);
                if (MathF.Abs(fb.Scale - 1f) > 1e-4f) anyScale[bone.Index] = true;
            }
        }

        foreach (var bone in skel.Bones)
        {
            if (!nodes.TryGetValue(bone.Name, out var node)) continue;
            var i = bone.Index;
            if (frames == 1)
            {
                // single-pose clips (idle): two keys so engines see a non-zero length
                var t1 = 1f / fps;
                rot[i][t1] = rot[i][0];
                pos[i][t1] = pos[i][0];
                scl[i][t1] = scl[i][0];
            }
            anim.CreateRotationChannel(node, rot[i], true);
            anim.CreateTranslationChannel(node, pos[i], true);
            if (anyScale[i]) anim.CreateScaleChannel(node, scl[i], true);
        }
    }
}
