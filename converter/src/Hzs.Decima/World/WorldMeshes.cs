using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Decima.Archive;
using Hzs.Decima.Assets;
using Hzs.Decima.Core;

namespace Hzs.Decima.World;

/// <summary>
/// Shared static meshes of the world: hzd/meshes/&lt;meshid&gt;.glb (Godot space, mesh-local, no transform) and their
/// colour textures shared by many meshes in hzd/textures/&lt;texid&gt;.png (glb image uri "../textures/&lt;texid&gt;.png").
/// meshid = 16 hex digits of the archive path hash of the mesh's core file + "_" + object index in that file.
/// The LOD is the finest one within the vertex budget. Thread-safe; each mesh/texture is written once (atomic).
/// </summary>
public sealed class WorldMeshes(Resolver res, CachePaths cache, Log log, int texPx = 512, int maxVertices = 12000)
{
    private readonly ConcurrentDictionary<string, Lazy<bool>> _meshes = new();
    private readonly ConcurrentDictionary<string, Lazy<(string Id, bool Alpha)?>> _textures = new();
    private readonly Materials _mats = new(res, texPx);
    private long _written;

    public string MeshDir => cache.Meshes;
    public string TextureDir => Path.Combine(cache.Hzd, "textures");
    public long BytesWritten => Interlocked.Read(ref _written);

    public static string MeshId(string corePath, int objectIndex) => $"{Murmur3.PathHash(HzdArchive.Normalize(corePath)):x16}_{objectIndex}";

    /// <summary>Exports the mesh if needed. Returns the mesh id and its texture ids, or null when it has no drawable geometry.</summary>
    public (string Id, string[] Textures)? Ensure(string file, Guid uuid)
    {
        var core = res.TryFile(file);
        var obj = core?.Find(uuid);
        if (core is null || obj is null) return null;
        var id = MeshId(file, obj.Index);
        var texs = new List<string>();
        var ok = _meshes.GetOrAdd(id, _ => new Lazy<bool>(() => Export(core, obj, id), LazyThreadSafetyMode.ExecutionAndPublication)).Value;
        if (!ok) return null;
        // texture ids are recorded next to the mesh (small sidecar) so cells can list them without re-reading the glb
        var side = Path.Combine(MeshDir, id + ".tex");
        if (File.Exists(side)) texs.AddRange(File.ReadAllLines(side).Where(l => l.Length > 0));
        return (id, texs.ToArray());
    }

    private bool Export(CoreFile core, CoreObject obj, string id)
    {
        var glbPath = Path.Combine(MeshDir, id + ".glb");
        var sidePath = Path.Combine(MeshDir, id + ".tex");
        if (File.Exists(glbPath) && File.Exists(sidePath)) return true;
        if (File.Exists(Path.Combine(MeshDir, id + ".empty"))) return false;
        try
        {
            var (md, lod, lods) = MeshReader.ReadBudget(res, core, obj, maxVertices);
            if (md is null || md.Prims.Count == 0 || md.Prims.All(p => p.Idx.Length == 0))
            {
                WriteShared(Path.Combine(MeshDir, id + ".empty"), []);
                return false;
            }
            var glb = new Glb { Extras = new JsonObject { ["source"] = $"{core.Path}#{obj.Index}", ["lod"] = lod, ["lods"] = lods } };
            var prims = new List<(JsonObject, int, int?)>();
            var texIds = new List<string>();
            var matCache = new Dictionary<string, int>();
            foreach (var prim in md.Prims)
            {
                if (prim.Idx.Length == 0) continue;
                var choice = _mats.ForEffect(prim.Effect);
                var key = choice?.Key ?? "";
                if (!matCache.TryGetValue(key, out var mat))
                {
                    var tex = choice?.Color is { } img ? Texture(key, img) : null;
                    if (tex is { } t)
                    {
                        texIds.Add(t.Id);
                        mat = glb.Material($"m{matCache.Count}", glb.ImageUri($"../textures/{t.Id}.png", t.Id), alphaMask: t.Alpha, doubleSided: t.Alpha);
                    }
                    else mat = glb.Material($"m{matCache.Count}", null, baseColor: [0.5f, 0.5f, 0.5f, 1f]);
                    matCache[key] = mat;
                }
                var pos = (float[])prim.Pos.Clone();
                Space.Points(pos);
                var attrs = new JsonObject { ["POSITION"] = glb.Floats(pos, 3, minMax: true) };
                if (prim.Nrm is { } n)
                {
                    var nn = (float[])n.Clone();
                    Space.Points(nn);
                    for (var i = 0; i + 2 < nn.Length; i += 3)
                    {
                        var l = MathF.Sqrt(nn[i] * nn[i] + nn[i + 1] * nn[i + 1] + nn[i + 2] * nn[i + 2]);
                        if (l > 1e-6f) { nn[i] /= l; nn[i + 1] /= l; nn[i + 2] /= l; } else { nn[i] = 0; nn[i + 1] = 1; nn[i + 2] = 0; }
                    }
                    attrs["NORMAL"] = glb.Floats(nn, 3);
                }
                if (prim.Uv is { } uv) attrs["TEXCOORD_0"] = glb.Floats(uv, 2);
                prims.Add((attrs, glb.Indices(prim.Idx, prim.VertexCount), mat));
            }
            var root = glb.Node(id, mesh: glb.Mesh(md.Name, prims));
            glb.SceneRoot(root);
            var bytes = glb.ToBytes();
            WriteShared(sidePath, System.Text.Encoding.UTF8.GetBytes(string.Join("\n", texIds.Distinct())));
            WriteShared(glbPath, bytes);
            return true;
        }
        catch (Exception ex)
        {
            log.Warn($"mesh {core.Path}#{obj.Index}: {ex.Message}");
            return false;
        }
    }

    private (string Id, bool Alpha)? Texture(string key, Image img) =>
        _textures.GetOrAdd(key, k => new Lazy<(string, bool)?>(() =>
        {
            var tid = $"{Murmur3.PathHash(k):x16}";
            var path = Path.Combine(TextureDir, tid + ".png");
            var alpha = img.Channels == 4 && HasCutout(img);
            if (!File.Exists(path)) WriteShared(path, img.ToPng());
            return (tid, alpha);
        }, LazyThreadSafetyMode.ExecutionAndPublication)).Value;

    private static bool HasCutout(Image img)
    {
        long low = 0, n = (long)img.Width * img.Height;
        for (var i = 3; i < img.Pixels.Length; i += 4) if (img.Pixels[i] < 128) low++;
        return low > n / 200;
    }

    /// <summary>Writes a shared cache file atomically; concurrent writers of identical content are fine.</summary>
    private void WriteShared(string target, byte[] data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        var tmp = $"{target}.{Environment.ProcessId}.{Environment.CurrentManagedThreadId}.tmp";
        File.WriteAllBytes(tmp, data);
        try { File.Move(tmp, target, true); }
        catch (IOException) { try { File.Delete(tmp); } catch (IOException) { } }
        Interlocked.Add(ref _written, data.Length);
    }
}
