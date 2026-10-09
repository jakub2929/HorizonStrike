using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hzs.Cs2;

/// <summary>
/// Minimal GLB container (JSON chunk + one BIN chunk) for structural edits that SharpGLTF does not offer:
/// appending one glTF into another (index remapping) and re-parenting scene roots.
/// </summary>
internal sealed class Glb
{
    private const uint Magic = 0x46546C67; // "glTF"
    private const uint ChunkJson = 0x4E4F534A;
    private const uint ChunkBin = 0x004E4942;

    public JsonObject Json { get; private set; } = new();
    public byte[] Bin { get; private set; } = [];

    public static Glb Parse(ReadOnlySpan<byte> data)
    {
        if (data.Length < 12 || BinaryPrimitives.ReadUInt32LittleEndian(data) != Magic)
            throw new InvalidDataException("not a GLB");
        var length = (int)BinaryPrimitives.ReadUInt32LittleEndian(data[8..]);
        var glb = new Glb();
        var off = 12;
        while (off + 8 <= length)
        {
            var clen = (int)BinaryPrimitives.ReadUInt32LittleEndian(data[off..]);
            var ctype = BinaryPrimitives.ReadUInt32LittleEndian(data[(off + 4)..]);
            var chunk = data.Slice(off + 8, clen);
            if (ctype == ChunkJson) glb.Json = JsonNode.Parse(chunk)!.AsObject();
            else if (ctype == ChunkBin) glb.Bin = chunk.ToArray();
            off += 8 + clen;
        }
        return glb;
    }

    public byte[] ToBytes()
    {
        if (Json["scene"] is null && Json["scenes"] is JsonArray { Count: > 0 }) Json["scene"] = 0;
        if (Bin.Length > 0)
        {
            var buffers = Json["buffers"] as JsonArray ?? [];
            if (buffers.Count == 0) buffers.Add(new JsonObject());
            buffers[0]!["byteLength"] = Bin.Length;
            Json["buffers"] = buffers;
        }
        var json = Encoding.UTF8.GetBytes(Json.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
        var jsonPad = (4 - json.Length % 4) % 4;
        var binPad = (4 - Bin.Length % 4) % 4;
        var total = 12 + 8 + json.Length + jsonPad + (Bin.Length > 0 ? 8 + Bin.Length + binPad : 0);
        var outb = new byte[total];
        var s = outb.AsSpan();
        BinaryPrimitives.WriteUInt32LittleEndian(s, Magic);
        BinaryPrimitives.WriteUInt32LittleEndian(s[4..], 2);
        BinaryPrimitives.WriteUInt32LittleEndian(s[8..], (uint)total);
        BinaryPrimitives.WriteUInt32LittleEndian(s[12..], (uint)(json.Length + jsonPad));
        BinaryPrimitives.WriteUInt32LittleEndian(s[16..], ChunkJson);
        json.CopyTo(s[20..]);
        s.Slice(20 + json.Length, jsonPad).Fill((byte)' ');
        if (Bin.Length > 0)
        {
            var o = 20 + json.Length + jsonPad;
            BinaryPrimitives.WriteUInt32LittleEndian(s[o..], (uint)(Bin.Length + binPad));
            BinaryPrimitives.WriteUInt32LittleEndian(s[(o + 4)..], ChunkBin);
            Bin.CopyTo(s[(o + 8)..]);
        }
        return outb;
    }

    public JsonArray Array(string name) => Json[name] as JsonArray ?? (JsonArray)(Json[name] = new JsonArray());

    public JsonArray SceneRoots()
    {
        var scenes = Array("scenes");
        if (scenes.Count == 0) scenes.Add(new JsonObject { ["nodes"] = new JsonArray() });
        var scene = scenes[Json["scene"]?.GetValue<int>() ?? 0]!.AsObject();
        return scene["nodes"] as JsonArray ?? (JsonArray)(scene["nodes"] = new JsonArray());
    }

    /// <summary>Index of the first node with this name, or -1.</summary>
    public int FindNode(string name)
    {
        var nodes = Array("nodes");
        for (var i = 0; i < nodes.Count; i++)
            if (nodes[i]?["name"]?.GetValue<string>() == name) return i;
        return -1;
    }

    public void AddChild(int parent, int child)
    {
        var p = Array("nodes")[parent]!.AsObject();
        var children = p["children"] as JsonArray ?? (JsonArray)(p["children"] = new JsonArray());
        children.Add(child);
    }

    /// <summary>Wrap every scene root into one new root node with the given rotation (x,y,z,w).</summary>
    public int WrapRoots(string name, float[] rotation)
    {
        var roots = SceneRoots();
        var children = new JsonArray();
        foreach (var r in roots) children.Add(r!.GetValue<int>());
        var nodes = Array("nodes");
        nodes.Add(new JsonObject { ["name"] = name, ["rotation"] = new JsonArray(rotation.Select(v => (JsonNode)JsonValue.Create(v)!).ToArray()), ["children"] = children });
        var idx = nodes.Count - 1;
        roots.Clear();
        roots.Add(idx);
        return idx;
    }

    /// <summary>Bytes of a buffer view.</summary>
    public ReadOnlySpan<byte> View(int index)
    {
        var bv = Array("bufferViews")[index]!.AsObject();
        var off = bv["byteOffset"]?.GetValue<int>() ?? 0;
        return Bin.AsSpan(off, bv["byteLength"]!.GetValue<int>());
    }

    /// <summary>Append bytes as a new buffer view (8-byte aligned); returns its index.</summary>
    public int AddView(byte[] data)
    {
        var pad = (8 - Bin.Length % 8) % 8;
        var off = Bin.Length + pad;
        var bin = new byte[off + data.Length];
        Bin.CopyTo(bin, 0);
        data.CopyTo(bin, off);
        Bin = bin;
        var views = Array("bufferViews");
        views.Add(new JsonObject { ["buffer"] = 0, ["byteOffset"] = off, ["byteLength"] = data.Length });
        return views.Count - 1;
    }

    /// <summary>
    /// Re-encode embedded images: transform(bytes, mimeType) returns new bytes + mime type, or null to keep the image.
    /// The old data becomes unreferenced; call <see cref="Compact"/> afterwards.
    /// </summary>
    public void TransformImages(Func<byte[], (byte[] Data, string Mime)?> transform)
    {
        foreach (var img in Array("images"))
        {
            var o = img!.AsObject();
            if (o["bufferView"] is not JsonValue v) continue;
            var result = transform(View(v.GetValue<int>()).ToArray());
            if (result is not { } r) continue;
            o["bufferView"] = AddView(r.Data);
            o["mimeType"] = r.Mime;
        }
    }

    /// <summary>Rebuild BIN with only the buffer views that accessors and images reference (drops orphaned data).</summary>
    public void Compact()
    {
        var views = Array("bufferViews");
        var used = new SortedSet<int>();
        foreach (var a in Array("accessors"))
        {
            if (a!["bufferView"] is JsonValue v) used.Add(v.GetValue<int>());
            if (a["sparse"] is JsonObject sp)
            {
                if (sp["indices"]?["bufferView"] is JsonValue si) used.Add(si.GetValue<int>());
                if (sp["values"]?["bufferView"] is JsonValue sv) used.Add(sv.GetValue<int>());
            }
        }
        foreach (var i in Array("images"))
            if (i!["bufferView"] is JsonValue v) used.Add(v.GetValue<int>());

        var map = new Dictionary<int, int>();
        var newViews = new JsonArray();
        using var ms = new MemoryStream();
        foreach (var idx in used)
        {
            while (ms.Length % 8 != 0) ms.WriteByte(0);
            var bv = views[idx]!.DeepClone().AsObject();
            var data = View(idx);
            bv["buffer"] = 0;
            bv["byteOffset"] = (int)ms.Length;
            ms.Write(data);
            map[idx] = newViews.Count;
            newViews.Add(bv);
        }
        Bin = ms.ToArray();
        Json["bufferViews"] = newViews;

        void Remap(JsonObject? o)
        {
            if (o?["bufferView"] is JsonValue v) o["bufferView"] = map[v.GetValue<int>()];
        }
        foreach (var a in Array("accessors"))
        {
            Remap(a!.AsObject());
            if (a["sparse"] is JsonObject sp)
            {
                Remap(sp["indices"] as JsonObject);
                Remap(sp["values"] as JsonObject);
            }
        }
        foreach (var i in Array("images")) Remap(i!.AsObject());
    }

    /// <summary>
    /// Append <paramref name="src"/> into this glTF. Scene roots of src for which <paramref name="attach"/> returns
    /// true become children of node <paramref name="attachParent"/>, the rest become scene roots. Returns the node
    /// index offset of the appended nodes.
    /// </summary>
    public int Append(Glb src, Func<JsonObject, bool> attach, int attachParent)
    {
        // BIN: keep 8-byte alignment for every appended buffer view
        var pad = (8 - Bin.Length % 8) % 8;
        var binOffset = Bin.Length + pad;
        var bin = new byte[binOffset + src.Bin.Length];
        Bin.CopyTo(bin, 0);
        src.Bin.CopyTo(bin, binOffset);
        Bin = bin;

        string[] lists = ["accessors", "bufferViews", "images", "textures", "samplers", "materials", "meshes", "skins", "nodes", "cameras", "animations"];
        var b = lists.ToDictionary(n => n, n => (Json[n] as JsonArray)?.Count ?? 0);

        void Shift(JsonObject o, string key, string list)
        {
            if (o[key] is JsonValue v) o[key] = v.GetValue<int>() + b[list];
        }

        void ShiftArray(JsonObject o, string key, string list)
        {
            if (o[key] is not JsonArray a) return;
            for (var i = 0; i < a.Count; i++) a[i] = a[i]!.GetValue<int>() + b[list];
        }

        void ShiftTextureRefs(JsonNode? n)
        {
            if (n is JsonObject o)
            {
                foreach (var (k, v) in o.ToList())
                {
                    if (k.EndsWith("Texture", StringComparison.Ordinal) && v is JsonObject t && t["index"] is JsonValue) Shift(t, "index", "textures");
                    else ShiftTextureRefs(v);
                }
            }
            else if (n is JsonArray a)
                foreach (var e in a) ShiftTextureRefs(e);
        }

        foreach (var name in lists)
        {
            if (src.Json[name] is not JsonArray items) continue;
            var dst = Array(name);
            foreach (var item in items)
            {
                var o = item!.DeepClone().AsObject();
                switch (name)
                {
                    case "bufferViews":
                        o["buffer"] = 0;
                        o["byteOffset"] = (o["byteOffset"]?.GetValue<int>() ?? 0) + binOffset;
                        break;
                    case "accessors":
                        Shift(o, "bufferView", "bufferViews");
                        if (o["sparse"] is JsonObject sp)
                        {
                            if (sp["indices"] is JsonObject si) Shift(si, "bufferView", "bufferViews");
                            if (sp["values"] is JsonObject sv) Shift(sv, "bufferView", "bufferViews");
                        }
                        break;
                    case "images":
                        Shift(o, "bufferView", "bufferViews");
                        break;
                    case "textures":
                        Shift(o, "source", "images");
                        Shift(o, "sampler", "samplers");
                        break;
                    case "materials":
                        ShiftTextureRefs(o);
                        break;
                    case "meshes":
                        foreach (var p in o["primitives"] as JsonArray ?? [])
                        {
                            var po = p!.AsObject();
                            if (po["attributes"] is JsonObject attrs)
                                foreach (var k in attrs.Select(kv => kv.Key).ToList()) Shift(attrs, k, "accessors");
                            Shift(po, "indices", "accessors");
                            Shift(po, "material", "materials");
                            foreach (var t in po["targets"] as JsonArray ?? [])
                            {
                                var to = t!.AsObject();
                                foreach (var k in to.Select(kv => kv.Key).ToList()) Shift(to, k, "accessors");
                            }
                        }
                        break;
                    case "skins":
                        Shift(o, "inverseBindMatrices", "accessors");
                        ShiftArray(o, "joints", "nodes");
                        Shift(o, "skeleton", "nodes");
                        break;
                    case "nodes":
                        ShiftArray(o, "children", "nodes");
                        Shift(o, "mesh", "meshes");
                        Shift(o, "skin", "skins");
                        Shift(o, "camera", "cameras");
                        break;
                    case "animations":
                        foreach (var c in o["channels"] as JsonArray ?? [])
                            if (c!["target"] is JsonObject tg) Shift(tg, "node", "nodes");
                        foreach (var s in o["samplers"] as JsonArray ?? [])
                        {
                            Shift(s!.AsObject(), "input", "accessors");
                            Shift(s.AsObject(), "output", "accessors");
                        }
                        break;
                }
                dst.Add(o);
            }
        }

        foreach (var ext in new[] { "extensionsUsed", "extensionsRequired" })
        {
            if (src.Json[ext] is not JsonArray se) continue;
            var de = Array(ext);
            foreach (var e in se)
                if (!de.Any(x => x!.GetValue<string>() == e!.GetValue<string>())) de.Add(e!.GetValue<string>());
        }

        var roots = SceneRoots();
        var nodes = Array("nodes");
        foreach (var r in src.SceneRoots())
        {
            var idx = r!.GetValue<int>() + b["nodes"];
            if (attach(nodes[idx]!.AsObject())) AddChild(attachParent, idx);
            else roots.Add(idx);
        }
        return b["nodes"];
    }
}
