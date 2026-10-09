using System.Numerics;
using Hzs.Common;
using Hzs.Decima.Core;

using Hzs.Decima.Sheets;

namespace Hzs.Decima.World;

/// <summary>One mesh resource placed in the world (HZD space world matrix, row-vector).</summary>
public readonly record struct Placement(string MeshFile, Guid MeshUuid, Matrix4x4 World, string Layer);

/// <summary>
/// Collects static geometry of a tile: every layer file under layers/geometry (minus cinematic/quest/lighting
/// dressing). generated_content/.../vegetation_hand_placed_* is a baked copy of the same vegetation (2131 of 2141
/// instances identical in tile 4,-3) and generated_content rocks_* are far-LOD merges, so generated content is skipped. Walks StaticMeshInstance -> mesh resource
/// (MultiMeshResource parts recursively), PrefabInstance -> PrefabResource.ObjectCollection (recursively, honouring
/// IsRemoved / transform overrides). Placement transforms compose child * parent (ChildTransformsRelative).
/// </summary>
public sealed class Placements(Resolver res, Log log)
{
    private static string[] SkipLayer => HzdNames.List("geometry.skip_layers");

    private readonly List<Placement> _out = [];
    private readonly string[] _skipPrefixes = HzdNames.List("geometry.skip_prefixes");
    private readonly string[] _skipMeshNames = HzdNames.List("geometry.skip_mesh_names");
    private int _depthWarn;

    public static IEnumerable<string> LayerFiles(Resolver res, int x, int y)
    {
        var dir = WorldTiles.TileDir(x, y) + "/" + HzdNames.Str("geometry.layers_dir");
        var skip = SkipLayer;
        foreach (var p in res.Archive.Paths)
        {
            if (p.StartsWith(dir, StringComparison.Ordinal))
            {
                var name = p[dir.Length..];
                if (name.Contains('/')) continue; // sub folders hold textures of skyboxes etc.
                if (skip.Any(s => name.Contains(s, StringComparison.Ordinal))) continue;
                yield return p;
            }
        }
    }

    public List<Placement> ForTile(int x, int y)
    {
        _out.Clear();
        foreach (var layer in LayerFiles(res, x, y))
        {
            var file = res.TryFile(layer);
            if (file is null) continue;
            var name = Path.GetFileName(layer);
            try { VisitRoots(file, Matrix4x4.Identity, name, 0); }
            catch (Exception ex) { log.Warn($"layer {layer}: {ex.Message}"); }
        }
        return _out;
    }

    /// <summary>Placements of one layer file (e.g. the tile's water layer), empty when the file is missing.</summary>
    public List<Placement> ForLayerFile(string path)
    {
        _out.Clear();
        var file = res.TryFile(path);
        if (file is null) return [];
        try { VisitRoots(file, Matrix4x4.Identity, Path.GetFileName(path), 0); }
        catch (Exception ex) { log.Warn($"layer {path}: {ex.Message}"); }
        return [.. _out];
    }

    /// <summary>
    /// Visual meshes of a placement target (PrefabResource, instance, collection or mesh resource) with prefab-local
    /// transforms; shadow/occluder chains are skipped like in the world layers.
    /// </summary>
    public List<Placement> ForTarget(CoreFile from, Ref r)
    {
        _out.Clear();
        if (r.IsNull) return [];
        var file = r.Path is null ? from : res.TryFile(r.Path);
        var target = file?.Find(r.Uuid);
        if (file is null || target is null) return [];
        var layer = Path.GetFileName(file.Path);
        switch (target.TypeName)
        {
            case "PrefabResource":
                if (TryDeref(file, file.Decode(target).Ref("ObjectCollection")) is { } coll) Safe(coll, Matrix4x4.Identity, layer, 0);
                break;
            case "StaticMeshInstance" or "PrefabInstance" or "ObjectCollection":
                Safe(file.Decode(target), Matrix4x4.Identity, layer, 0);
                break;
            default:
                VisitMesh(file, r, Matrix4x4.Identity, layer, 0);
                break;
        }
        return [.. _out];
    }

    /// <summary>Visits the objects listed by the file's root ObjectCollection (the last one), else all instances.</summary>
    private void VisitRoots(CoreFile file, Matrix4x4 parent, string layer, int depth)
    {
        var roots = file.OfType("ObjectCollection").LastOrDefault();
        IEnumerable<Obj> objs = roots is not null
            ? file.Decode(roots).Refs("Objects").Select(r => TryDeref(file, r)).OfType<Obj>()
            : file.Objects.Where(o => o.TypeName is "StaticMeshInstance" or "PrefabInstance").Select(file.Decode);
        foreach (var o in objs) Safe(o!, parent, layer, depth);
    }

    private int _errors;

    private void Safe(Obj o, Matrix4x4 parent, string layer, int depth)
    {
        try { Visit(o, parent, layer, depth); }
        catch (Exception ex) { if (_errors++ < 5) log.Warn($"{layer}: {o.Type}: {ex.Message}"); }
    }

    private void Visit(Obj o, Matrix4x4 parent, string layer, int depth)
    {
        if (depth > 12) { if (_depthWarn++ == 0) log.Warn($"{layer}: prefab nesting deeper than 12, cut"); return; }
        switch (o.Type)
        {
            case "StaticMeshInstance":
                {
                    var world = WorldXf.Hzd(o.Struct("Orientation")) * parent;
                    var r = o.Ref("Resource");
                    if (r.IsNull) return;
                    VisitMesh(o.File!, r, world, layer, depth + 1);
                    break;
                }
            case "PrefabInstance":
                {
                    var world = WorldXf.Hzd(o.Struct("Orientation")) * parent;
                    var relative = o.Bool("ChildTransformsRelative");
                    var prefab = TryDeref(o.File!, o.Ref("Prefab"));
                    if (prefab?.Type != "PrefabResource") return;
                    var coll = TryDeref(prefab.File!, prefab.Ref("ObjectCollection"));
                    if (coll is null) return;
                    var overrides = o.Structs("Overrides").ToDictionary(v => (Guid)v["RuntimeObject"]!, v => v);
                    foreach (var cr in coll.Refs("Objects"))
                    {
                        var child = TryDeref(coll.File!, cr);
                        if (child is null) continue;
                        if (overrides.TryGetValue(child.Uuid, out var ov))
                        {
                            if (ov.Bool("IsRemoved")) continue;
                            if (ov.Bool("IsTransformOverridden") && child.Has("Orientation"))
                            {
                                // the override replaces the child's local transform
                                var local = Assets.MeshReader.ToMatrix(ov.Struct("Orientation"));
                                VisitWithLocal(child, local * (relative ? world : Matrix4x4.Identity), layer, depth + 1);
                                continue;
                            }
                        }
                        Visit(child, relative ? world : Matrix4x4.Identity, layer, depth + 1);
                    }
                    break;
                }
            case "ObjectCollection":
                foreach (var cr in o.Refs("Objects"))
                    if (TryDeref(o.File!, cr) is { } c) Visit(c, parent, layer, depth + 1);
                break;
        }
    }

    /// <summary>Like Visit, but the object's own Orientation is replaced by an already composed world matrix.</summary>
    private void VisitWithLocal(Obj o, Matrix4x4 world, string layer, int depth)
    {
        switch (o.Type)
        {
            case "StaticMeshInstance":
                if (!o.Ref("Resource").IsNull) VisitMesh(o.File!, o.Ref("Resource"), world, layer, depth + 1);
                break;
            case "PrefabInstance":
                {
                    var prefab = TryDeref(o.File!, o.Ref("Prefab"));
                    if (prefab?.Type != "PrefabResource") return;
                    var coll = TryDeref(prefab.File!, prefab.Ref("ObjectCollection"));
                    if (coll is null) return;
                    var relative = o.Bool("ChildTransformsRelative");
                    foreach (var cr in coll.Refs("Objects"))
                        if (TryDeref(coll.File!, cr) is { } c) Visit(c, relative ? world : Matrix4x4.Identity, layer, depth + 1);
                    break;
                }
        }
    }

    /// <summary>Decodes a referenced object when we have a layout for its type (others are not geometry we place).</summary>
    private Obj? TryDeref(CoreFile from, Ref r)
    {
        if (r.IsNull) return null;
        var file = r.Path is null ? from : res.TryFile(r.Path);
        var target = file?.Find(r.Uuid);
        if (file is null || target is null) return null;
        return target.TypeName is "StaticMeshInstance" or "PrefabInstance" or "ObjectCollection" or "PrefabResource" ? file.Decode(target) : null;
    }

    private void VisitMesh(CoreFile from, Ref r, Matrix4x4 world, string layer, int depth)
    {
        if (depth > 16) return;
        var file = r.Path is null ? from : res.TryFile(r.Path);
        var target = file?.Find(r.Uuid);
        if (file is null || target is null) return;
        switch (target.TypeName)
        {
            case "MultiMeshResource":
                {
                    var mm = file.Decode(target);
                    foreach (var part in mm.Structs("Parts"))
                    {
                        var pw = WorldXf.Hzd(part.Struct("Transform")) * world;
                        VisitMesh(file, part.Ref("Mesh"), pw, layer, depth + 1);
                    }
                    break;
                }
            case "LodMeshResource":
            case "StaticMeshResource":
            case "RegularSkinnedMeshResource":
                {
                    // building blocks carry three chains: *_VisualLodChain, *_ShadowLodChain (shadow-only draw flag),
                    // *_OccluderLodChain (*_occ_L1 boxes for occlusion culling); only the visual one is placed
                    // generated_content meshes are merged far-LOD proxies of geometry placed elsewhere
                    if (_skipPrefixes.Any(pr => file.Path.StartsWith(pr, StringComparison.Ordinal))) break;
                    var decoded = file.Decode(target);
                    var name = decoded.Str("Name");
                    if (_skipMeshNames.Any(sn => name.Contains(sn, StringComparison.OrdinalIgnoreCase))) break; // *ShadowLodChain, *_ShadowGeo, ProxyShadowMesh*, occluders
                    if (decoded.Type == "LodMeshResource")
                    {
                        // compound buildings: the LOD chain holds MultiMeshResources (LOD0 = the real parts, far LODs =
                        // merged proxies) -> expand LOD0 into its parts
                        var lod0 = decoded.Structs("Meshes").OrderBy(p => p.Float("Distance")).FirstOrDefault();
                        var lr = lod0?.Ref("Mesh");
                        if (lr is { } r0 && !r0.IsNull)
                        {
                            var lf = r0.Path is null ? file : res.TryFile(r0.Path);
                            var lt = lf?.Find(r0.Uuid);
                            if (lt?.TypeName is "MultiMeshResource" or "LodMeshResource")
                            {
                                VisitMesh(file, r0, world, layer, depth + 1);
                                break;
                            }
                        }
                    }
                    _out.Add(new Placement(file.Path, target.Uuid, world, layer));
                    break;
                }
        }
    }
}
