using System.Numerics;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hzs.Generated;
using ValveResourceFormat.ResourceTypes;
using ValveResourceFormat.Serialization.KeyValues;

namespace Hzs.Cs2;

/// <summary>
/// Content contract of a weapon (docs/ARCHITECTURE.md "Content contract"): cs2/weapons/&lt;id&gt;/meta.json with
/// content_model, bone_roles and points as found in the CS2 models. The sheet columns of the same names are the
/// source of truth; differences are reported as problems.
/// </summary>
internal static partial class WeaponMeta
{
    private const float Scale = 0.0254f;

    /// <summary>role -> bone name pattern, searched in the weapon model skeleton (first match in bone order).</summary>
    private static readonly (string Role, Regex Pattern)[] WeaponRoles =
    [
        ("mag", MagPattern()),
        ("bolt", BoltPattern()),
        ("trigger", TriggerPattern()),
        ("pin", PinPattern()),
    ];

    /// <summary>point name -> attachment names tried in order; suppressed weapons prefer the suppressor muzzle.</summary>
    private static readonly (string Point, string[] Attachments, string Kind)[] PointRules =
    [
        ("muzzle", ["muzzle_flash"], "fx"),
        ("eject", ["shell_eject"], "fx"),
        ("mag_drop", ["mag_drop"], "fx"),
        ("flame", ["molotov_particle"], "fx"),
    ];

    [GeneratedRegex("^(clip|magazine|mag)$", RegexOptions.IgnoreCase)] private static partial Regex MagPattern();
    [GeneratedRegex("^(slide|bolt|bolt_action|chargehandle|pump)$", RegexOptions.IgnoreCase)] private static partial Regex BoltPattern();
    [GeneratedRegex("^trigger$", RegexOptions.IgnoreCase)] private static partial Regex TriggerPattern();
    [GeneratedRegex("^pin$", RegexOptions.IgnoreCase)] private static partial Regex PinPattern();

    /// <summary>
    /// Arms bone the weapon's secondary skeleton attaches to: its entry in the clip skeleton's m_secondarySkeletons,
    /// else the one attach bone every declared entry uses (viewmodel.vnmskel lists 13 weapon skeletons, all on the
    /// same bone; knives and grenades are not listed).
    /// </summary>
    public static string? AttachBone(Cs2Source src, string primarySkeleton, string secondarySkeleton)
    {
        using var res = src.Load(primarySkeleton + "_c");
        if (res?.DataBlock is not BinaryKV3 kv) return null;
        var all = new HashSet<string>(StringComparer.Ordinal);
        foreach (var s in kv.Data.Root.GetArray("m_secondarySkeletons") ?? [])
        {
            var bone = s.GetStringProperty("m_attachToBoneID");
            if (string.IsNullOrEmpty(bone)) continue;
            all.Add(bone);
            var skel = s.GetStringProperty("m_skeleton");
            if (string.Equals(skel?.Replace('\\', '/'), secondarySkeleton.Replace('\\', '/'), StringComparison.OrdinalIgnoreCase))
                return bone;
        }
        return all.Count == 1 ? all.First() : null;
    }

    public static JsonObject Build(Cs2Source src, WeaponsRow row, string? worldModel, bool hasView, string? attachBone,
        string? primarySkeleton, string? secondarySkeleton, List<string> problems)
    {
        var id = row.Id;
        var contentModel = new JsonObject();
        if (hasView) contentModel["view"] = $"cs2/weapons/{id}/view.glb";
        if (worldModel is not null) contentModel["world"] = $"cs2/weapons/{id}/world.glb";

        var roles = new JsonObject();
        var points = new JsonObject();
        var sourceRoles = new List<string>();
        var sourcePoints = new List<string>();
        if (hasView && worldModel is not null)
        {
            using var armsRes = src.Load(ViewModel.ArmsModel + "_c");
            using var weaponRes = src.Load(worldModel + "_c");
            if (armsRes?.DataBlock is Model arms && weaponRes?.DataBlock is Model weapon)
            {
                var root = arms.Skeleton.Roots.FirstOrDefault()?.Name;
                if (root is not null) { roles["camera"] = root; roles["root"] = root; }
                if (attachBone is not null) roles["attach"] = attachBone;
                var handR = arms.Skeleton.Bones.FirstOrDefault(b => b.Name.Equals("hand_R", StringComparison.OrdinalIgnoreCase))?.Name;
                var handL = arms.Skeleton.Bones.FirstOrDefault(b => b.Name.Equals("hand_L", StringComparison.OrdinalIgnoreCase))?.Name;
                if (handR is not null) roles["hand_r"] = handR;
                if (handL is not null) roles["hand_l"] = handL;
                var weaponRoot = weapon.Skeleton.Roots.FirstOrDefault()?.Name;
                if (weaponRoot is not null) roles["weapon"] = weaponRoot;
                foreach (var (role, pattern) in WeaponRoles)
                {
                    var bone = weapon.Skeleton.Bones.FirstOrDefault(b => pattern.IsMatch(b.Name))?.Name;
                    if (bone is not null) roles[role] = bone;
                }
                sourceRoles.Add($"{ViewModel.ArmsModel} skeleton (root, hand_R, hand_L)");
                if (primarySkeleton is not null) sourceRoles.Add($"{primarySkeleton} m_secondarySkeletons attach {attachBone}");
                sourceRoles.Add($"{worldModel} skeleton ({string.Join(",", weapon.Skeleton.Bones.Select(b => b.Name))})");

                foreach (var (name, attachments, kind) in PointRules)
                {
                    var names = name == "muzzle" && row.Suppressed ? new[] { "muzzle_flash2" }.Concat(attachments) : attachments;
                    var att = names.Select(n => weapon.Attachments.GetValueOrDefault(n)).FirstOrDefault(a => a is not null && a.Length > 0);
                    if (att is null) continue;
                    var inf = Enumerable.Range(0, att.Length).Select(i => att[i]).OrderByDescending(i => i.Weight).First();
                    var fwd = Vector3.Transform(Vector3.UnitX, inf.Rotation);
                    points[name] = new JsonObject
                    {
                        ["bone"] = inf.Name,
                        ["offset"] = Vec(inf.Offset * Scale),
                        ["rotation"] = new JsonArray(R(inf.Rotation.X), R(inf.Rotation.Y), R(inf.Rotation.Z), R(inf.Rotation.W)),
                        ["forward"] = Vec(fwd),
                        ["kind"] = kind,
                    };
                    sourcePoints.Add($"attachment {att.Name} on {inf.Name}");
                }
                if (sourcePoints.Count > 0) sourcePoints.Insert(0, $"{worldModel}:");
            }
            else problems.Add("meta: arms or weapon model could not be loaded");
        }

        var meta = new JsonObject
        {
            ["content_model"] = contentModel,
            ["model"] = hasView ? "view.glb" : worldModel is not null ? "world.glb" : null,
            ["up"] = "y",
            ["forward"] = "-z",
            ["scale_m"] = 1.0,
            ["origin"] = hasView ? "eye" : "model",
            ["bone_roles"] = roles,
            ["points"] = points,
            ["_source"] = new JsonObject
            {
                ["bone_roles"] = sourceRoles.Count > 0 ? string.Join("; ", sourceRoles) : "no viewmodel",
                ["points"] = sourcePoints.Count > 0 ? string.Join(" ", sourcePoints) : "no fx attachments",
            },
        };
        Compare(row, meta, problems);
        return meta;
    }

    /// <summary>The sheet is the source of truth: report every contract cell the models disagree with.</summary>
    private static void Compare(WeaponsRow row, JsonObject meta, List<string> problems)
    {
        foreach (var (column, sheetJson) in new[] { ("content_model", row.ContentModel), ("bone_roles", row.BoneRoles), ("points", row.Points) })
        {
            JsonNode? sheet;
            try { sheet = JsonNode.Parse(sheetJson); }
            catch { sheet = null; }
            if (sheet is not JsonObject)
            {
                problems.Add($"meta: sheet {column} is not filled");
                continue;
            }
            if (!Same(sheet, meta[column])) problems.Add($"meta: {column} differs from the sheet (sheet {sheet.ToJsonString()}, model {meta[column]!.ToJsonString()})");
        }
    }

    private static bool Same(JsonNode? a, JsonNode? b)
    {
        switch (a, b)
        {
            case (null, null): return true;
            case (JsonObject oa, JsonObject ob):
                return oa.Count == ob.Count && oa.All(kv => ob.ContainsKey(kv.Key) && Same(kv.Value, ob[kv.Key]));
            case (JsonArray xa, JsonArray xb):
                return xa.Count == xb.Count && xa.Zip(xb).All(p => Same(p.First, p.Second));
            case (JsonValue va, JsonValue vb):
                if (va.TryGetValue<double>(out var da) && vb.TryGetValue<double>(out var db)) return Math.Abs(da - db) <= 1e-4;
                return va.ToJsonString() == vb.ToJsonString();
            default: return false;
        }
    }

    private static double R(float v) => Math.Round(v, 5) + 0.0; // + 0.0: no "-0"
    private static JsonArray Vec(Vector3 v) => new(R(v.X), R(v.Y), R(v.Z));
}
