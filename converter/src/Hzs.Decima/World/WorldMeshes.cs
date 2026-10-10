using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using Hzs.Common;
using Hzs.Decima.Archive;
using Hzs.Decima.Assets;
using Hzs.Decima.Core;

namespace Hzs.Decima.World;

/// <summary>
/// An exported shared mesh: id, texture ids, whether a material is colourised (stone x AO), its mesh-local bounds
/// (Godot axes) and whether every material is opaque.
/// </summary>
public sealed record MeshRef(string Id, string[] Textures, bool Colorized, System.Numerics.Vector3 Min, System.Numerics.Vector3 Max, bool Opaque);

/// <summary>
/// Shared static meshes of the world: hzd/meshes/&lt;meshid&gt;.glb (Godot space, mesh-local, no transform) and their
/// colour textures shared by many meshes in hzd/textures/&lt;texid&gt;.png (glb image uri "../textures/&lt;texid&gt;.png").
/// meshid = 16 hex digits of the archive path hash of the mesh's core file + "_" + object index in that file.
/// The LOD is the finest one within the vertex budget. Thread-safe; each mesh/texture is written once (atomic) and
/// written again when its file was deleted meanwhile (cache GC).
/// </summary>
public sealed class WorldMeshes(Resolver res, CachePaths cache, Log log, int texPx = 512, int maxVertices = 12000)
{
    /// <summary>
    /// glb asset.extras.format of shared meshes; bump when mesh/texture export changes. Meshes of another format are
    /// exported again (same id, overwritten atomically) together with their textures.
    /// </summary>
    public const int Format = 6;

    private const string ColorizedFlag = "#colorized";

    /// <summary>Render effects of invisible helper geometry (collision quads, occluder planes): never exported.</summary>
    private static readonly string[] SkipEffects = Sheets.HzdNames.List("geometry.skip_effect_names");

    private readonly ConcurrentDictionary<string, Lazy<bool>> _meshes = new();
    private readonly ConcurrentDictionary<string, Lazy<(string Id, bool Alpha)?>> _textures = new();
    private readonly Materials _mats = new(res, texPx);

    public string MeshDir => cache.Meshes;
    public string TextureDir => Path.Combine(cache.Hzd, "textures");

    public static string MeshId(string corePath, int objectIndex) => $"{Murmur3.PathHash(HzdArchive.Normalize(corePath)):x16}_{objectIndex}";

    /// <summary>
    /// Exports the mesh if needed. Returns the mesh id and its texture ids, or null when it has no drawable geometry.
    /// Bytes of mesh/texture files this call actually writes are added to <paramref name="written"/> (per job; a mesh
    /// another job is already exporting is counted by that job only).
    /// </summary>
    public MeshRef? Ensure(string file, Guid uuid, StrongBox<long> written)
    {
        var core = res.TryFile(file);
        var obj = core?.Find(uuid);
        if (core is null || obj is null) return null;
        var id = MeshId(file, obj.Index);
        var ok = Fresh(_meshes, id, () => new Lazy<bool>(() => Export(core, obj, id, written), LazyThreadSafetyMode.ExecutionAndPublication),
            v => !v || MeshFilesPresent(id));
        if (!ok) return null;
        // texture ids (and the #colorized flag) are recorded next to the mesh (small sidecar) so cells can list them
        // without re-reading the glb
        var side = Path.Combine(MeshDir, id + ".tex");
        var lines = File.Exists(side) ? File.ReadAllLines(side).Where(l => l.Length > 0).ToArray() : [];
        var (min, max, opaque) = _info.GetOrAdd(id, i => GlbInfo(Path.Combine(MeshDir, i + ".glb")));
        return new MeshRef(id, lines.Where(l => !l.StartsWith('#')).ToArray(), lines.Contains(ColorizedFlag), min, max, opaque);
    }

    private readonly ConcurrentDictionary<string, (System.Numerics.Vector3, System.Numerics.Vector3, bool)> _info = new();

    /// <summary>Bounds of the POSITION accessors and "no MASK/BLEND material" of an exported glb.</summary>
    private static (System.Numerics.Vector3 Min, System.Numerics.Vector3 Max, bool Opaque) GlbInfo(string path)
    {
        var min = new System.Numerics.Vector3(float.MaxValue); var max = new System.Numerics.Vector3(float.MinValue);
        var opaque = true;
        try
        {
            using var f = File.OpenRead(path);
            Span<byte> head = stackalloc byte[20];
            if (f.Read(head) != 20) return (default, default, false);
            var json = new byte[BitConverter.ToInt32(head[12..16])];
            f.ReadExactly(json);
            var j = JsonNode.Parse(json)!;
            var acc = j["accessors"]!.AsArray();
            foreach (var mesh in j["meshes"]?.AsArray() ?? [])
                foreach (var prim in mesh!["primitives"]!.AsArray())
                {
                    var a = acc[prim!["attributes"]!["POSITION"]!.GetValue<int>()]!;
                    var mn = a["min"]!.AsArray(); var mx = a["max"]!.AsArray();
                    min = System.Numerics.Vector3.Min(min, new(mn[0]!.GetValue<float>(), mn[1]!.GetValue<float>(), mn[2]!.GetValue<float>()));
                    max = System.Numerics.Vector3.Max(max, new(mx[0]!.GetValue<float>(), mx[1]!.GetValue<float>(), mx[2]!.GetValue<float>()));
                }
            foreach (var m in j["materials"]?.AsArray() ?? [])
                if (m?["alphaMode"]?.GetValue<string>() is "MASK" or "BLEND") opaque = false;
        }
        catch (Exception) { return (default, default, false); }
        return min.X <= max.X ? (min, max, opaque) : (default, default, false);
    }

    /// <summary>A coarse LOD of the mesh (finest LOD with at most <paramref name="maxVertices"/> vertices, else the coarsest), HZD axes.</summary>
    public MeshData? ReadLow(string file, Guid uuid, int maxVertices)
    {
        var core = res.TryFile(file);
        var obj = core?.Find(uuid);
        if (core is null || obj is null) return null;
        try { return MeshReader.ReadBudget(res, core, obj, maxVertices).Mesh; }
        catch (Exception) { return null; }
    }

    /// <summary>
    /// The cached result for <paramref name="key"/>, exported again when <paramref name="valid"/> says its files are gone
    /// (the game's cache GC deletes shared files of evicted cells while this process keeps running). The swap is atomic:
    /// with several workers exactly one re-exports, the others wait on the same Lazy.
    /// </summary>
    private static T Fresh<T>(ConcurrentDictionary<string, Lazy<T>> map, string key, Func<Lazy<T>> make, Func<T, bool> valid)
    {
        var lz = map.GetOrAdd(key, _ => make());
        var v = lz.Value;
        if (valid(v)) return v;
        var fresh = make();
        return (map.TryUpdate(key, fresh, lz) ? fresh : map[key]).Value;
    }

    private string TexPath(string texId) => Path.Combine(TextureDir, texId + TexExt);

    /// <summary>Shared texture files: DDS (BC1 opaque / BC7 cut-out colour, sRGB, full mips; see <see cref="Dds"/>).</summary>
    public const string TexExt = ".dds";
    private static readonly BcFormat AlbedoFormat = Dds.Parse(Hzs.Generated.SystemsSheet.RenderTextureFormatAlbedo.Value);
    private static readonly BcFormat AlbedoAlphaFormat = Dds.Parse(Hzs.Generated.SystemsSheet.RenderTextureFormatAlbedoAlpha.Value);
    private static readonly BcFormat NormalFormat = Dds.Parse(Hzs.Generated.SystemsSheet.RenderTextureFormatNormal.Value);
    private static readonly BcFormat OrmFormat = Dds.Parse(Hzs.Generated.SystemsSheet.RenderTextureFormatOrm.Value);
    private readonly ConcurrentDictionary<string, Lazy<string?>> _maps = new();

    /// <summary>Normal (BC5 linear, XY) or ORM (BC1 linear) texture id of a surface-map key, exported when missing; null if undecodable.</summary>
    private string? MapTexture(string key, bool normal, StrongBox<long> written) =>
        Fresh(_maps, key, () => new Lazy<string?>(() =>
        {
            var img = _mats.Map(key);
            if (img is null) return null;
            var tid = $"{Murmur3.PathHash(key):x16}";
            var dds = normal ? Dds.Encode(img, NormalFormat, false, MipMode.Normal) : Dds.Encode(img, OrmFormat, false, MipMode.Data);
            WriteShared(TexPath(tid), dds, written);
            return tid;
        }, LazyThreadSafetyMode.ExecutionAndPublication), v => v is null || File.Exists(TexPath(v)));

    /// <summary>glb, sidecar and every texture the sidecar lists exist on disk.</summary>
    private bool MeshFilesPresent(string id)
    {
        var side = Path.Combine(MeshDir, id + ".tex");
        if (!File.Exists(Path.Combine(MeshDir, id + ".glb")) || !File.Exists(side)) return false;
        try { return File.ReadAllLines(side).Where(l => l.Length > 0 && !l.StartsWith('#')).All(t => File.Exists(TexPath(t))); }
        catch (IOException) { return false; }
    }

    private bool Export(CoreFile core, CoreObject obj, string id, StrongBox<long> written)
    {
        var glbPath = Path.Combine(MeshDir, id + ".glb");
        var sidePath = Path.Combine(MeshDir, id + ".tex");
        if (File.Exists(glbPath) && File.Exists(sidePath) && GlbFormat(glbPath) == Format) return true;
        if (File.Exists(Path.Combine(MeshDir, id + ".empty"))) return false;
        try
        {
            var (md, lod, lods) = Timers.Time("mesh_read", () => MeshReader.ReadBudget(res, core, obj, maxVertices));
            md?.Prims.RemoveAll(p => p.Effect?.Has("Name") == true && SkipEffects.Any(e => p.Effect.Str("Name").Contains(e, StringComparison.OrdinalIgnoreCase)));
            if (md is null || md.Prims.Count == 0 || md.Prims.All(p => p.Idx.Length == 0))
            {
                WriteShared(Path.Combine(MeshDir, id + ".empty"), [], written);
                return false;
            }
            var glb = new Glb { Extras = new JsonObject { ["source"] = $"{core.Path}#{obj.Index}", ["lod"] = lod, ["lods"] = lods, ["format"] = Format } };
            var prims = new List<(JsonObject, int, int?)>();
            var texIds = new List<string>();
            var matCache = new Dictionary<string, int>();
            var colorized = false;
            foreach (var prim in md.Prims)
            {
                if (prim.Idx.Length == 0) continue;
                var choice = _mats.ForEffect(prim.Effect, known: k => _textures.TryGetValue(k, out var lz) && lz.IsValueCreated && lz.Value is { } kt && File.Exists(TexPath(kt.Id)));
                var (nk, ok) = _mats.SurfaceMaps(prim.Effect, choice?.Colorized == true);
                var key = $"{choice?.Key}|{nk}|{ok}";
                if (!matCache.TryGetValue(key, out var mat))
                {
                    var nid = nk is null ? null : MapTexture(nk, true, written);
                    var oid = ok is null ? null : MapTexture(ok, false, written);
                    int? nTex = nid is null ? null : glb.ImageUri($"../textures/{nid}{TexExt}", nid);
                    int? oTex = oid is null ? null : glb.ImageUri($"../textures/{oid}{TexExt}", oid);
                    if (nid is not null) texIds.Add(nid);
                    if (oid is not null) texIds.Add(oid);
                    var tex = choice is null ? null : choice.Color is { } img ? Texture(key, img, written) : _textures.TryGetValue(key, out var done) ? done.Value : null;
                    if (tex is { } t)
                    {
                        texIds.Add(t.Id);
                        colorized |= choice!.Colorized;
                        mat = glb.Material($"m{matCache.Count}", glb.ImageUri($"../textures/{t.Id}{TexExt}", t.Id), nTex, alphaMask: t.Alpha, doubleSided: t.Alpha, ormTex: oTex, extras: NoNormal(nTex));
                    }
                    else mat = glb.Material($"m{matCache.Count}", null, nTex, baseColor: [0.5f, 0.5f, 0.5f, 1f], ormTex: oTex, extras: NoNormal(nTex));
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
            WriteShared(sidePath, System.Text.Encoding.UTF8.GetBytes(string.Join("\n", texIds.Distinct().Concat(colorized ? [ColorizedFlag] : []))), written);
            WriteShared(glbPath, bytes, written);
            return true;
        }
        catch (Exception ex)
        {
            log.Warn($"mesh {core.Path}#{obj.Index}: {ex.Message}");
            return false;
        }
    }

    private (string Id, bool Alpha)? Texture(string key, Image img, StrongBox<long> written) =>
        Fresh(_textures, key, () => new Lazy<(string Id, bool Alpha)?>(() =>
        {
            var tid = $"{Murmur3.PathHash(key):x16}";
            var alpha = img.Channels == 4 && HasCutout(img);
            var dds = alpha ? Dds.Encode(img, AlbedoAlphaFormat, true, MipMode.Cutout) : Dds.Encode(img, AlbedoFormat, true, MipMode.Color);
            WriteShared(TexPath(tid), dds, written); // a texture is decoded only for a mesh being exported
            return (tid, alpha);
        }, LazyThreadSafetyMode.ExecutionAndPublication), v => v is null || File.Exists(TexPath(v.Value.Id)));

    /// <summary>Material extras when HZD binds no normal map to the effect (searched: texture-set channels, plain normal textures).</summary>
    private static JsonObject? NoNormal(int? normalTex) => normalTex is null ? new JsonObject { ["hzd_normal"] = "none" } : null;

    /// <summary>asset.extras.format of a glb file (0 when missing or unreadable).</summary>
    private static int GlbFormat(string path)
    {
        try
        {
            using var f = File.OpenRead(path);
            Span<byte> head = stackalloc byte[20];
            if (f.Read(head) != 20) return 0;
            var len = BitConverter.ToInt32(head[12..16]);
            if (len <= 0 || len > 16 << 20) return 0;
            var json = new byte[len];
            f.ReadExactly(json);
            return JsonNode.Parse(json)?["asset"]?["extras"]?["format"]?.GetValue<int>() ?? 0;
        }
        catch (Exception) { return 0; }
    }

    private static bool HasCutout(Image img)
    {
        long low = 0, n = (long)img.Width * img.Height;
        for (var i = 3; i < img.Pixels.Length; i += 4) if (img.Pixels[i] < 128) low++;
        return low > n / 200;
    }

    /// <summary>Writes a shared cache file atomically; concurrent writers of identical content are fine.</summary>
    private static void WriteShared(string target, byte[] data, StrongBox<long> written)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        var tmp = $"{target}.{Environment.ProcessId}.{Environment.CurrentManagedThreadId}.tmp";
        File.WriteAllBytes(tmp, data);
        try { File.Move(tmp, target, true); }
        catch (IOException) { try { File.Delete(tmp); } catch (IOException) { } }
        Interlocked.Add(ref written.Value, data.Length);
    }
}
