using System.Buffers.Binary;
using System.Numerics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hzs.Decima.Assets;

/// <summary>Minimal glTF 2.0 binary (.glb) writer: meshes, skins, nodes, PBR materials with embedded PNG textures.</summary>
public sealed class Glb
{
    private readonly MemoryStream _bin = new();
    private readonly JsonArray _accessors = [], _views = [], _meshes = [], _nodes = [], _materials = [], _textures = [], _images = [], _skins = [];
    private readonly JsonArray _sceneNodes = [];
    public string Generator { get; init; } = "hzsconv";

    private int View(ReadOnlySpan<byte> data, int? target = null, int? stride = null)
    {
        while (_bin.Length % 4 != 0) _bin.WriteByte(0);
        var off = (int)_bin.Length;
        _bin.Write(data);
        var v = new JsonObject { ["buffer"] = 0, ["byteOffset"] = off, ["byteLength"] = data.Length };
        if (target is { } t) v["target"] = t;
        if (stride is { } s) v["byteStride"] = s;
        _views.Add(v);
        return _views.Count - 1;
    }

    private int Accessor(int view, int componentType, int count, string type, JsonArray? min = null, JsonArray? max = null, bool normalized = false)
    {
        var a = new JsonObject { ["bufferView"] = view, ["componentType"] = componentType, ["count"] = count, ["type"] = type };
        if (normalized) a["normalized"] = true;
        if (min is not null) a["min"] = min;
        if (max is not null) a["max"] = max;
        _accessors.Add(a);
        return _accessors.Count - 1;
    }

    public int Floats(float[] data, int comps, bool minMax = false, bool vertex = true)
    {
        var bytes = new byte[data.Length * 4];
        Buffer.BlockCopy(data, 0, bytes, 0, bytes.Length);
        JsonArray? mn = null, mx = null;
        if (minMax)
        {
            mn = []; mx = [];
            for (var c = 0; c < comps; c++)
            {
                float lo = float.MaxValue, hi = float.MinValue;
                for (var i = c; i < data.Length; i += comps) { lo = Math.Min(lo, data[i]); hi = Math.Max(hi, data[i]); }
                mn.Add(lo); mx.Add(hi);
            }
        }
        var type = comps switch { 1 => "SCALAR", 2 => "VEC2", 3 => "VEC3", 4 => "VEC4", 16 => "MAT4", _ => throw new ArgumentException("comps") };
        return Accessor(View(bytes, vertex ? 34962 : null), 5126, data.Length / comps, type, mn, mx);
    }

    public int Joints(ushort[] data)
    {
        var bytes = new byte[data.Length * 2];
        Buffer.BlockCopy(data, 0, bytes, 0, bytes.Length);
        return Accessor(View(bytes, 34962), 5123, data.Length / 4, "VEC4");
    }

    public int Indices(uint[] idx, int vertexCount)
    {
        if (vertexCount <= 65535)
        {
            var b = new byte[idx.Length * 2];
            for (var i = 0; i < idx.Length; i++) BinaryPrimitives.WriteUInt16LittleEndian(b.AsSpan(i * 2), (ushort)idx[i]);
            return Accessor(View(b, 34963), 5123, idx.Length, "SCALAR");
        }
        var bb = new byte[idx.Length * 4];
        Buffer.BlockCopy(idx, 0, bb, 0, bb.Length);
        return Accessor(View(bb, 34963), 5125, idx.Length, "SCALAR");
    }

    public int ImagePng(byte[] png, string name)
    {
        _images.Add(new JsonObject { ["bufferView"] = View(png), ["mimeType"] = "image/png", ["name"] = name });
        _textures.Add(new JsonObject { ["source"] = _images.Count - 1, ["sampler"] = 0 });
        return _textures.Count - 1;
    }

    public int Material(string name, int? baseColorTex, int? normalTex = null, float metallic = 0f, float roughness = 0.8f, float[]? baseColor = null)
    {
        var pbr = new JsonObject { ["metallicFactor"] = metallic, ["roughnessFactor"] = roughness };
        if (baseColorTex is { } t) pbr["baseColorTexture"] = new JsonObject { ["index"] = t };
        if (baseColor is not null) pbr["baseColorFactor"] = new JsonArray(baseColor.Select(x => (JsonNode)x).ToArray());
        var m = new JsonObject { ["name"] = name, ["pbrMetallicRoughness"] = pbr };
        if (normalTex is { } n) m["normalTexture"] = new JsonObject { ["index"] = n };
        _materials.Add(m);
        return _materials.Count - 1;
    }

    /// <summary>Adds a mesh; each primitive is (attributes, indices accessor, material).</summary>
    public int Mesh(string name, IEnumerable<(JsonObject Attributes, int Indices, int? Material)> prims)
    {
        var arr = new JsonArray();
        foreach (var (attrs, idx, mat) in prims)
        {
            var p = new JsonObject { ["attributes"] = attrs, ["indices"] = idx, ["mode"] = 4 };
            if (mat is { } m) p["material"] = m;
            arr.Add(p);
        }
        _meshes.Add(new JsonObject { ["name"] = name, ["primitives"] = arr });
        return _meshes.Count - 1;
    }

    public int Node(string name, Matrix4x4? local = null, int? mesh = null, int? skin = null)
    {
        var n = new JsonObject { ["name"] = name };
        if (local is { } m && !m.IsIdentity)
        {
            Matrix4x4.Decompose(m, out var s, out var r, out var t);
            if (t != Vector3.Zero) n["translation"] = new JsonArray(t.X, t.Y, t.Z);
            if (r != Quaternion.Identity) n["rotation"] = new JsonArray(r.X, r.Y, r.Z, r.W);
            if (Vector3.Distance(s, Vector3.One) > 1e-5f) n["scale"] = new JsonArray(s.X, s.Y, s.Z);
        }
        if (mesh is { } me) n["mesh"] = me;
        if (skin is { } sk) n["skin"] = sk;
        _nodes.Add(n);
        return _nodes.Count - 1;
    }

    public void Child(int parent, int child)
    {
        var p = _nodes[parent]!.AsObject();
        if (p["children"] is not JsonArray c) p["children"] = c = [];
        c.Add(child);
    }

    public void SceneRoot(int node) => _sceneNodes.Add(node);

    public int Skin(string name, int[] joints, Matrix4x4[] inverseBind, int? skeletonRoot)
    {
        var f = new float[joints.Length * 16];
        for (var i = 0; i < joints.Length; i++)
        {
            var m = inverseBind[i];
            float[] v = [m.M11, m.M12, m.M13, m.M14, m.M21, m.M22, m.M23, m.M24, m.M31, m.M32, m.M33, m.M34, m.M41, m.M42, m.M43, m.M44];
            v.CopyTo(f, i * 16);
        }
        var s = new JsonObject { ["name"] = name, ["inverseBindMatrices"] = Floats(f, 16, vertex: false), ["joints"] = new JsonArray(joints.Select(j => (JsonNode)j).ToArray()) };
        if (skeletonRoot is { } r) s["skeleton"] = r;
        _skins.Add(s);
        return _skins.Count - 1;
    }

    public byte[] ToBytes()
    {
        var json = new JsonObject
        {
            ["asset"] = new JsonObject { ["version"] = "2.0", ["generator"] = Generator },
            ["scene"] = 0,
            ["scenes"] = new JsonArray(new JsonObject { ["nodes"] = _sceneNodes.DeepClone() }),
            ["nodes"] = _nodes.DeepClone(),
        };
        void Put(string k, JsonArray a) { if (a.Count > 0) json[k] = a.DeepClone(); }
        Put("meshes", _meshes); Put("materials", _materials); Put("textures", _textures); Put("images", _images);
        Put("skins", _skins); Put("accessors", _accessors); Put("bufferViews", _views);
        if (_textures.Count > 0) json["samplers"] = new JsonArray(new JsonObject { ["magFilter"] = 9729, ["minFilter"] = 9987, ["wrapS"] = 10497, ["wrapT"] = 10497 });
        while (_bin.Length % 4 != 0) _bin.WriteByte(0);
        json["buffers"] = new JsonArray(new JsonObject { ["byteLength"] = _bin.Length });
        var jsonBytes = Encoding.UTF8.GetBytes(json.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
        var jpad = (4 - jsonBytes.Length % 4) % 4;
        var total = 12 + 8 + jsonBytes.Length + jpad + 8 + (int)_bin.Length;
        using var o = new MemoryStream(total);
        Span<byte> h = stackalloc byte[12];
        BinaryPrimitives.WriteUInt32LittleEndian(h, 0x46546C67); // glTF
        BinaryPrimitives.WriteUInt32LittleEndian(h[4..], 2);
        BinaryPrimitives.WriteUInt32LittleEndian(h[8..], (uint)total);
        o.Write(h);
        Span<byte> ch = stackalloc byte[8];
        BinaryPrimitives.WriteUInt32LittleEndian(ch, (uint)(jsonBytes.Length + jpad));
        BinaryPrimitives.WriteUInt32LittleEndian(ch[4..], 0x4E4F534A); // JSON
        o.Write(ch);
        o.Write(jsonBytes);
        for (var i = 0; i < jpad; i++) o.WriteByte(0x20);
        BinaryPrimitives.WriteUInt32LittleEndian(ch, (uint)_bin.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(ch[4..], 0x004E4942); // BIN
        o.Write(ch);
        _bin.Position = 0;
        _bin.CopyTo(o);
        return o.ToArray();
    }
}
