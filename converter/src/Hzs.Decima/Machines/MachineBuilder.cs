using System.Numerics;
using System.Text.Json.Nodes;
using Hzs.Decima.Assets;
using Hzs.Decima.Core;
using Hzs.Decima.Sheets;
using Hzs.Generated;

namespace Hzs.Decima.Machines;

/// <summary>
/// Builds one machine: skinned glb on the real HZD mesh skeleton (bind pose) plus meta.json. Skinned parts keep their
/// weights; rigid parts (plates, eye, canisters) are attached to their orientation helper (from the destructibility
/// parts' BoneName) and skinned 100% to that helper, so everything shares one skin. Helpers are exported as extra
/// joints (weak-spot "bones" such as Eye_helper are helpers).
/// </summary>
public sealed class MachineBuilder(Resolver res, MachinesRow row, JsonObject? resolved, Hzs.Common.Log log, int maxTexPx = 1024)
{
    private readonly List<string> _names = [];
    private readonly List<int> _parent = [];
    private readonly List<Matrix4x4> _world = []; // HZD space, bind pose
    private readonly List<bool> _isHelper = [];

    public sealed record Result(byte[] Glb, JsonObject Meta, int Joints, float HeightM, int Vertices);

    public Result Build()
    {
        var parts = HzdBindings.Paths(row.ModelParts);
        var meshes = new List<MeshData>();
        foreach (var p in parts)
        {
            var md = MeshReader.ReadLod0(res, p);
            if (md is null || md.Prims.Count == 0) { log.Warn($"{row.Id}: no drawable mesh in {p}"); continue; }
            meshes.Add(md);
        }
        if (meshes.Count == 0) throw new InvalidDataException($"{row.Id}: no meshes");

        BuildSkeleton(meshes);
        var helperOfMesh = StaticAttachments();

        // geometry grouped by material key
        var mats = new Materials(res, maxTexPx);
        var groups = new Dictionary<string, (Materials.Choice? Mat, List<float> P, List<float> N, List<float> T, List<ushort> J, List<float> W, List<uint> I)>();
        (Materials.Choice?, List<float>, List<float>, List<float>, List<ushort>, List<float>, List<uint>) Group(Materials.Choice? m)
        {
            var key = m?.Key ?? "";
            if (!groups.TryGetValue(key, out var g)) groups[key] = g = (m, [], [], [], [], [], []);
            return g;
        }
        var totalVerts = 0;
        foreach (var md in meshes)
        {
            var meshJointMap = md.Skinned ? MapMeshJoints(md) : null;
            List<int> targets = md.Skinned ? [-1] : helperOfMesh.GetValueOrDefault(Norm(md.SourcePath)) ?? [NameMatchHelper(md.SourcePath)];
            foreach (var helper in targets)
                foreach (var prim in md.Prims)
                {
                    var m = mats.ForEffect(prim.Effect, p => p.StartsWith("models/", StringComparison.Ordinal));
                    var (_, P, N, T, J, W, I) = Group(m);
                    var baseV = (uint)(P.Count / 3);
                    var xf = helper >= 0 ? _world[helper] : Matrix4x4.Identity;
                    for (var v = 0; v < prim.VertexCount; v++)
                    {
                        var pos = new Vector3(prim.Pos[v * 3], prim.Pos[v * 3 + 1], prim.Pos[v * 3 + 2]);
                        if (helper >= 0) pos = Vector3.Transform(pos, xf);
                        var g = Space.P(pos);
                        P.Add(g.X); P.Add(g.Y); P.Add(g.Z);
                        var n = prim.Nrm is { } nn ? new Vector3(nn[v * 3], nn[v * 3 + 1], nn[v * 3 + 2]) : Vector3.UnitZ;
                        if (helper >= 0) n = Vector3.TransformNormal(n, xf);
                        n = n.LengthSquared() > 1e-12f ? Vector3.Normalize(Space.P(n)) : Vector3.UnitY;
                        N.Add(n.X); N.Add(n.Y); N.Add(n.Z);
                        T.Add(prim.Uv is { } uv ? uv[v * 2] : 0); T.Add(prim.Uv is { } uv2 ? uv2[v * 2 + 1] : 0);
                        if (helper >= 0) { J.Add((ushort)helper); J.Add(0); J.Add(0); J.Add(0); W.Add(1); W.Add(0); W.Add(0); W.Add(0); }
                        else if (prim.Joints is { } pj && prim.Weights is { } pw)
                            for (var k = 0; k < 4; k++) { var sj = pj[v * 4 + k]; J.Add((ushort)(sj < meshJointMap!.Length ? meshJointMap[sj] : 0)); W.Add(pw[v * 4 + k]); }
                        else { J.Add(0); J.Add(0); J.Add(0); J.Add(0); W.Add(1); W.Add(0); W.Add(0); W.Add(0); }
                    }
                    foreach (var i in prim.Idx) I.Add(baseV + i);
                    totalVerts += prim.VertexCount;
                }
        }

        // glb
        var glb = new Glb();
        var worldG = _world.Select(Space.M).ToArray();
        var nodes = new int[_names.Count];
        var root = glb.Node(row.Id);
        glb.SceneRoot(root);
        for (var j = 0; j < _names.Count; j++)
        {
            var local = _parent[j] >= 0 && Matrix4x4.Invert(worldG[_parent[j]], out var pinv) ? worldG[j] * pinv : worldG[j];
            nodes[j] = glb.Node(_names[j], local);
        }
        for (var j = 0; j < _names.Count; j++)
        {
            if (_parent[j] >= 0) glb.Child(nodes[_parent[j]], nodes[j]);
            else glb.Child(root, nodes[j]);
        }
        var ibm = worldG.Select(w => Matrix4x4.Invert(w, out var inv) ? inv : Matrix4x4.Identity).ToArray();
        var skin = glb.Skin(row.Id + "_skin", nodes, ibm, nodes[0]);
        var prims = new List<(JsonObject, int, int?)>();
        float minY = float.MaxValue, maxY = float.MinValue;
        var mi = 0;
        foreach (var (key, g) in groups)
        {
            int? mat = null;
            if (g.Mat?.Color is { } img) mat = glb.Material($"{row.Id}_{mi}", glb.ImagePng(img.ToPng(), $"{row.Id}_{mi}_color"));
            else mat = glb.Material($"{row.Id}_{mi}", null, baseColor: [0.45f, 0.45f, 0.45f, 1f]);
            mi++;
            var pos = g.P.ToArray();
            for (var i = 1; i < pos.Length; i += 3) { minY = Math.Min(minY, pos[i]); maxY = Math.Max(maxY, pos[i]); }
            var attrs = new JsonObject
            {
                ["POSITION"] = glb.Floats(pos, 3, minMax: true),
                ["NORMAL"] = glb.Floats(g.N.ToArray(), 3),
                ["TEXCOORD_0"] = glb.Floats(g.T.ToArray(), 2),
                ["JOINTS_0"] = glb.Joints(g.J.ToArray()),
                ["WEIGHTS_0"] = glb.Floats(g.W.ToArray(), 4),
            };
            prims.Add((attrs, glb.Indices(g.I.ToArray(), pos.Length / 3), mat));
        }
        var meshNode = glb.Node(row.Id + "_mesh", mesh: glb.Mesh(row.Id, prims), skin: skin);
        glb.Child(root, meshNode);

        var height = maxY - Math.Min(0, minY);
        var meta = Meta(height, worldG);
        return new Result(glb.ToBytes(), meta, _names.Count, height, totalVerts);
    }

    private static string Norm(string p) => Archive.HzdArchive.Normalize(p);

    // ---------------- skeleton ----------------

    private void BuildSkeleton(List<MeshData> meshes)
    {
        var skelPath = meshes.FirstOrDefault(m => m.Skinned)?.SkeletonPath ?? HzdBindings.Path(row.Skeleton)
            ?? throw new InvalidDataException($"{row.Id}: no skeleton");
        var skel = res.File(skelPath).FirstObj("Skeleton") ?? throw new InvalidDataException($"{skelPath}: no Skeleton");
        foreach (var j in skel.Structs("Joints"))
        {
            _names.Add(j.Str("Name"));
            _parent.Add(Convert.ToInt32(j["ParentIndex"]));
            _world.Add(Matrix4x4.Identity);
            _isHelper.Add(false);
        }
        var known = new bool[_names.Count];
        foreach (var md in meshes.Where(m => m.Skinned))
        {
            var map = MapMeshJoints(md);
            for (var k = 0; k < md.JointIndexList.Length; k++)
            {
                var j = md.JointIndexList[k] < map.Length ? map[md.JointIndexList[k]] : -1;
                if (j < 0 || j >= known.Length) continue;
                if (Matrix4x4.Invert(md.InverseBind[k], out var w)) { _world[j] = w; known[j] = true; }
            }
        }
        var pose = InitialPoseLocals();
        var covered = known.Count(x => x);
        for (var pass = 0; pass < 4; pass++)
            for (var j = 0; j < _names.Count; j++)
            {
                if (known[j]) continue;
                var p = _parent[j];
                if (p >= 0 && !known[p]) continue;
                var parentW = p >= 0 ? _world[p] : Matrix4x4.Identity;
                var local = pose.TryGetValue(_names[j], out var l) ? l : Matrix4x4.Identity;
                _world[j] = local * parentW;
                known[j] = true;
            }
        log.Info($"{row.Id}: skeleton {skelPath} {_names.Count} joints, {covered} from inverse bind matrices, rest from the initial pose");

        // helpers (attach points, weak spots)
        var dir = Norm(skelPath);
        var animDir = dir[..(dir.IndexOf("/animation/", StringComparison.Ordinal) + "/animation/".Length)];
        var helperFiles = res.Archive.Paths.Where(p => p.StartsWith(animDir, StringComparison.Ordinal) && p.Contains("helpers", StringComparison.Ordinal));
        var meshJointCount = _names.Count;
        foreach (var hf in helperFiles)
        {
            var f = res.TryFile(hf);
            if (f is null) continue;
            foreach (var hs in f.All("SkeletonHelpers"))
                foreach (var h in hs.Structs("Helpers"))
                {
                    var name = h.Str("Name");
                    if (_names.Contains(name)) continue;
                    var idx = h.Int("Index");
                    var parent = idx >= 0 && idx < meshJointCount ? idx : -1;
                    var local = MeshReader.ToMatrix(h.Struct("Matrix"));
                    _names.Add(name);
                    _parent.Add(parent);
                    _world.Add(parent >= 0 ? local * _world[parent] : local);
                    _isHelper.Add(true);
                }
        }
    }

    /// <summary>Mesh skeleton joint index -> our joint index (BlendIndices and JointIndexList both index the mesh skeleton).</summary>
    private int[] MapMeshJoints(MeshData md)
    {
        if (md.SkeletonPath is null) return Enumerable.Range(0, _names.Count).ToArray();
        var skel = res.File(md.SkeletonPath).FirstObj("Skeleton")!;
        return skel.Structs("Joints").Select(j => Math.Max(0, _names.IndexOf(j.Str("Name")))).ToArray();
    }

    /// <summary>Local transforms (HZD space) from the entity's SkinnedModelResource.InitialPose, by joint name.</summary>
    private Dictionary<string, Matrix4x4> InitialPoseLocals()
    {
        var result = new Dictionary<string, Matrix4x4>(StringComparer.Ordinal);
        try
        {
            var entity = HzdBindings.Path(row.Entity);
            if (entity is null) return result;
            var smr = res.File(entity).All("SkinnedModelResource").FirstOrDefault(o => !o.Str("Name").Contains("Corrupt", StringComparison.OrdinalIgnoreCase));
            if (smr?.Struct("InitialPose") is not { } pose || !pose.Has("Local")) return result;
            var skel = res.Deref(smr, pose.Ref("Skeleton"));
            var names = skel?.Structs("Joints").Select(j => j.Str("Name")).ToArray() ?? [];
            var l = pose.Prims<float>("Local");
            for (var i = 0; i < names.Length && (i + 1) * 12 <= l.Length; i++)
            {
                var q = new Quaternion(l[i * 12], l[i * 12 + 1], l[i * 12 + 2], l[i * 12 + 3]);
                var t = new Vector3(l[i * 12 + 4], l[i * 12 + 5], l[i * 12 + 6]);
                var s = new Vector3(l[i * 12 + 8], l[i * 12 + 9], l[i * 12 + 10]);
                if (s == Vector3.Zero) s = Vector3.One;
                result[names[i]] = Matrix4x4.CreateScale(s) * Matrix4x4.CreateFromQuaternion(Quaternion.Normalize(q)) * Matrix4x4.CreateTranslation(t);
            }
        }
        catch (Exception ex) { log.Warn($"{row.Id}: initial pose unavailable: {ex.Message}"); }
        return result;
    }

    // ---------------- rigid parts ----------------

    /// <summary>mesh path -> helper joints it is attached to (DestructibilityPart.BoneName of parts whose initial state shows the mesh).</summary>
    private Dictionary<string, List<int>> StaticAttachments()
    {
        var map = new Dictionary<string, List<int>>(StringComparer.Ordinal);
        var path = HzdBindings.Path(row.Destructibility);
        if (path is null) return map;
        var file = res.TryFile(path);
        if (file is null) return map;
        foreach (var part in file.All("DestructibilityPart"))
        {
            var bone = part.Str("BoneName");
            var j = _names.IndexOf(bone);
            if (bone.Length == 0 || j < 0) continue;
            try
            {
                var state = res.Deref(file, part.Ref("InitialState"));
                if (state is null) continue;
                var mp = res.Deref(state, state.Ref("ModelPartResource"));
                var mesh = mp?.Ref("MeshResource");
                if (mesh is not { Path: { } mpth }) continue;
                var key = Norm(mpth);
                if (!map.TryGetValue(key, out var list)) map[key] = list = [];
                if (!list.Contains(j)) list.Add(j);
            }
            catch (Exception ex) { log.Warn($"{row.Id}: part {part.Str("Name")}: {ex.Message}"); }
        }
        return map;
    }

    /// <summary>Fallback attach point: helper named like the mesh file ("l_bodyplate" -> "L_BodyPlate_helper"), else root.</summary>
    private int NameMatchHelper(string meshPath)
    {
        var stem = Path.GetFileNameWithoutExtension(Norm(meshPath)).ToLowerInvariant();
        for (var j = 0; j < _names.Count; j++)
            if (_isHelper[j] && _names[j].ToLowerInvariant().Replace("_helper", "") == stem) return j;
        return 0;
    }

    // ---------------- meta ----------------

    private JsonObject Meta(float height, Matrix4x4[] worldG)
    {
        var bones = new JsonArray();
        for (var j = 0; j < _names.Count; j++)
        {
            var t = worldG[j].Translation;
            bones.Add(new JsonObject
            {
                ["name"] = _names[j], ["parent"] = _parent[j] >= 0 ? _names[_parent[j]] : null, ["helper"] = _isHelper[j],
                ["pos"] = new JsonArray(R(t.X), R(t.Y), R(t.Z)),
            });
        }
        var weakParts = Json(row.WeakSpotParts) as JsonArray ?? [];
        var weakBones = WeakSpotBones();
        var weak = new JsonArray();
        foreach (var b in weakBones)
            weak.Add(new JsonObject { ["part"] = weakParts.Count > 0 ? weakParts[0]!.GetValue<string>() : "weak_spot", ["bone"] = b });
        return new JsonObject
        {
            ["id"] = row.Id,
            ["hzd_internal_name"] = row.HzdInternalName,
            ["model"] = "model.glb",
            ["up"] = "y",
            ["forward"] = "-z",
            ["scale_m"] = 1.0,
            ["space"] = "godot: meters, Y up, forward -Z (hzd (x,y,z) -> (x,z,-y))",
            ["bone_roles"] = BoneRoles(),
            ["points"] = Points(),
            ["height_m"] = R(height),
            ["bones"] = bones,
            ["weak_spots"] = weak,
            ["leg_chains"] = RoleLegChains(),
            ["leg_chains_bones"] = new JsonArray(LegChains().Select(c => (JsonNode)new JsonArray(c.Select(n => (JsonNode)n).ToArray())).ToArray()),
        };
    }

    private static double R(float v) => Math.Round(v, 4);

    // ---------------- content contract (sheet bone_roles / points, checked against the converted skeleton) ----------------

    private JsonObject BoneRoles()
    {
        var o = new JsonObject();
        if (Json(row.BoneRoles) is not JsonObject roles) return o;
        foreach (var (role, bone) in roles)
        {
            var b = bone?.GetValue<string>() ?? "";
            if (_names.Contains(b)) o[role] = b;
            else log.Warn($"{row.Id}: bone_roles.{role} = {b} not in the skeleton (dropped)");
        }
        return o;
    }

    private JsonObject Points()
    {
        var o = new JsonObject();
        if (Json(row.Points) is not JsonObject pts) return o;
        foreach (var (name, p) in pts)
        {
            var b = p?["bone"]?.GetValue<string>() ?? "";
            if (_names.Contains(b)) o[name] = p!.DeepClone();
            else log.Warn($"{row.Id}: points.{name}.bone = {b} not in the skeleton (dropped)");
        }
        return o;
    }

    /// <summary>Leg chains as role names (leg_&lt;id&gt;_upper/lower/foot/toe present in bone_roles), one array per leg.</summary>
    private JsonArray RoleLegChains()
    {
        var roles = BoneRoles();
        var legs = roles.Select(kv => kv.Key).Where(k => k.StartsWith("leg_", StringComparison.Ordinal))
            .GroupBy(k => k[..k.LastIndexOf('_')]).OrderBy(g => g.Key, StringComparer.Ordinal);
        string[] order = ["upper", "lower", "foot", "toe"];
        return new JsonArray(legs.Select(g => (JsonNode)new JsonArray(order.Select(part => g.Key + "_" + part).Where(g.Contains).Select(r => (JsonNode)r).ToArray())).ToArray());
    }

    private static JsonNode? Json(string text) { try { return JsonNode.Parse(text); } catch { return null; } }

    /// <summary>Weak-spot bones: the resolved sheet binding (DestructibilityPart.BoneName of the weak-spot parts), present in the skeleton.</summary>
    public List<string> WeakSpotBones()
    {
        var node = resolved?["weak_spot_bones"] ?? (row.WeakSpotBones.ConstJson is { } c ? Json(c) : null);
        if (node is not JsonArray arr) return [];
        return arr.Select(x => x?.GetValue<string>() ?? "").Where(_names.Contains).ToList();
    }

    /// <summary>
    /// Leg chains hip..foot: for every non-helper leaf joint that rests on the ground in the bind pose, walk up while the
    /// ancestor leads to only this one grounded leaf. Excludes IK/procedural helper joints.
    /// </summary>
    public List<List<string>> LegChains()
    {
        bool Skip(int j) => _isHelper[j] || _names[j].StartsWith("ik", StringComparison.Ordinal) || _names[j].Contains("Proc", StringComparison.Ordinal);
        var children = Enumerable.Range(0, _names.Count).ToLookup(j => _parent[j]);
        var grounded = Enumerable.Range(0, _names.Count)
            .Where(j => !Skip(j) && !children[j].Any(c => !Skip(c)) && _world[j].Translation.Z < 0.2f && _parent[j] >= 0)
            .ToList();
        int GroundedUnder(int a) => grounded.Count(g => { for (var x = g; x >= 0; x = _parent[x]) if (x == a) return true; return false; });
        var chains = new List<List<string>>();
        foreach (var leaf in grounded)
        {
            var chain = new List<int> { leaf };
            var cur = leaf;
            while (_parent[cur] >= 0 && GroundedUnder(_parent[cur]) == 1) { cur = _parent[cur]; chain.Insert(0, cur); }
            if (chain.Count >= 3) chains.Add(chain.Select(j => _names[j]).ToList());
        }
        return chains;
    }
}
