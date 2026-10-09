using System.Buffers.Binary;
using System.Numerics;
using Hzs.Decima.Archive;
using Hzs.Decima.Core;

namespace Hzs.Decima.Assets;

/// <summary>One draw primitive in HZD model space (Z-up, meters).</summary>
public sealed class Prim
{
    public float[] Pos = [];          // xyz per vertex
    public float[]? Nrm;              // xyz per vertex
    public float[]? Uv;               // uv per vertex
    public ushort[]? Joints;          // 4 per vertex, joint index into the mesh skeleton
    public float[]? Weights;          // 4 per vertex
    public uint[] Idx = [];
    public Obj? Effect;               // RenderEffectResource
    public int VertexCount => Pos.Length / 3;
}

/// <summary>LOD0 of a mesh resource with its primitives (and skin bindings when skinned).</summary>
public sealed class MeshData
{
    public string Name = "";
    public string SourcePath = "";
    public List<Prim> Prims { get; } = [];
    public bool Skinned;
    public string? SkeletonPath;
    public int[] JointIndexList = [];
    public Matrix4x4[] InverseBind = [];
}

/// <summary>
/// Reads HZD meshes: LodMeshResource -> Meshes[0] (RegularSkinnedMeshResource or StaticMeshResource) ->
/// RenderingPrimitiveResource -> VertexArrayResource + IndexArrayResource. Vertex/index payloads are in the
/// part's .core.stream: each vertex array's streams are stored back to back from the array's offset (each padded;
/// the length field gives the padded size).
/// </summary>
public static class MeshReader
{
    // EVertexElement
    private const int Pos = 0, Normal = 4, Uv0 = 6, BlendWeights = 16, BlendIndices = 17;
    // EVertexElementStorageType
    private const int SNorm16 = 1, F32 = 2, F16 = 3, UNorm8 = 4, SShort = 5, X10Y10Z10W2N = 6, UByte = 7, UShort = 8, UNorm16 = 9;

    /// <summary>LOD0 mesh of a core file (first LodMeshResource, else the first mesh resource), or null if none.</summary>
    public static MeshData? ReadLod0(Resolver res, string corePath)
    {
        var file = res.File(corePath);
        Obj? mesh = null;
        if (file.FirstObj("LodMeshResource") is { } lod)
        {
            var parts = lod.Structs("Meshes");
            if (parts.Length > 0) mesh = res.Deref(file, parts.OrderBy(p => p.Float("Distance")).First().Ref("Mesh"));
        }
        mesh ??= file.FirstObj("RegularSkinnedMeshResource") ?? file.FirstObj("StaticMeshResource");
        return mesh is null ? null : ReadMesh(res, mesh, corePath);
    }

    public static MeshData? ReadMesh(Resolver res, Obj mesh, string sourcePath)
    {
        var file = mesh.File!;
        var drawFlags = (uint)mesh.Struct("DrawFlags").Long("Data");
        if (((drawFlags >> 3) & 1) != 0) return null; // shadow-only geometry
        var md = new MeshData { Name = mesh.Str("Name"), SourcePath = sourcePath };
        Ref[] effects;
        if (mesh.Type == "RegularSkinnedMeshResource")
        {
            md.Skinned = true;
            md.SkeletonPath = mesh.Ref("Skeleton").Path;
            var bind = res.Deref(file, mesh.Ref("SkinnedMeshBoneBindings"))!;
            md.JointIndexList = bind.Prims<ushort>("JointIndexList").Select(x => (int)x).ToArray();
            md.InverseBind = bind.Structs("InverseBindMatrices").Select(ToMatrix).ToArray();
            effects = mesh.Refs("RenderFxResources");
        }
        else effects = mesh.Refs("RenderEffects");
        var prims = mesh.Refs("Primitives");
        for (var i = 0; i < prims.Length; i++)
        {
            var p = res.Deref(file, prims[i])!;
            var prim = ReadPrimitive(res, p);
            if (prim is null) continue;
            if (i < effects.Length && !effects[i].IsNull) prim.Effect = res.Deref(file, effects[i]);
            md.Prims.Add(prim);
        }
        return md;
    }

    /// <summary>HZD Mat44 (Col0..Col3, column-vector convention) as a System.Numerics row-vector matrix.</summary>
    public static Matrix4x4 ToMatrix(Obj m)
    {
        Obj c0 = m.Struct("Col0"), c1 = m.Struct("Col1"), c2 = m.Struct("Col2"), c3 = m.Struct("Col3");
        return new Matrix4x4(
            c0.Float("X"), c0.Float("Y"), c0.Float("Z"), c0.Float("W"),
            c1.Float("X"), c1.Float("Y"), c1.Float("Z"), c1.Float("W"),
            c2.Float("X"), c2.Float("Y"), c2.Float("Z"), c2.Float("W"),
            c3.Float("X"), c3.Float("Y"), c3.Float("Z"), c3.Float("W"));
    }

    private sealed record Element(int Offset, int Storage, int Slots, int Type);
    private sealed record Stream(int Stride, Element[] Elements, string? Source, long Offset, long Length, byte[]? Inline);

    private static Prim? ReadPrimitive(Resolver res, Obj p)
    {
        var file = p.File!;
        var va = res.Deref(file, p.Ref("VertexArray"));
        var ia = res.Deref(file, p.Ref("IndexArray"));
        if (va is null || ia is null) return null;

        // vertex array (binary)
        var r = va.ExtraReader();
        var vc = r.I32();
        var sc = r.I32();
        var streaming = r.U8() != 0;
        var streams = new List<Stream>();
        for (var s = 0; s < sc; s++)
        {
            r.Skip(4); // flags
            var stride = r.I32();
            var ec = r.I32();
            var els = new Element[ec];
            for (var e = 0; e < ec; e++) els[e] = new Element(r.U8(), r.U8(), r.U8(), r.U8());
            r.Skip(16); // hash
            if (streaming)
            {
                var loc = System.Text.Encoding.UTF8.GetString(r.Span(r.I32()));
                var off = (long)r.U64();
                var len = (long)r.U64();
                streams.Add(new Stream(stride, els, StripCache(loc), off, len, null));
            }
            else streams.Add(new Stream(stride, els, null, 0, (long)stride * vc, r.Bytes(stride * vc)));
        }

        var prim = new Prim();
        var baseOff = streams.FirstOrDefault(s => s.Source is not null)?.Offset ?? 0;
        byte[]? blob = null;
        if (streaming)
        {
            var total = streams.Sum(s => s.Length);
            var src = streams[0].Source!;
            var size = res.Archive.SizeOf(src);
            blob = res.Archive.ReadRange(src, baseOff, Math.Min(total, size - baseOff));
        }
        long acc = 0;
        ushort[]? joints = null; byte[]? wraw = null; int wslots = 0, jslots = 0;
        foreach (var s in streams)
        {
            ReadOnlySpan<byte> data = s.Inline ?? blob.AsSpan((int)acc, (int)Math.Min((long)s.Stride * vc, blob!.Length - acc));
            acc += s.Length;
            for (var ei = 0; ei < s.Elements.Length; ei++)
            {
                var el = s.Elements[ei];
                switch (el.Type)
                {
                    case Pos: prim.Pos = ReadFloats(data, s.Stride, vc, el, 3); break;
                    case Normal: prim.Nrm = ReadFloats(data, s.Stride, vc, el, 3); break;
                    case Uv0: prim.Uv = ReadFloats(data, s.Stride, vc, el, 2); break;
                    case BlendIndices:
                        jslots = el.Slots;
                        joints = new ushort[vc * el.Slots];
                        for (var v = 0; v < vc; v++)
                            for (var k = 0; k < el.Slots; k++)
                                joints[v * el.Slots + k] = el.Storage is UShort or SShort
                                    ? BinaryPrimitives.ReadUInt16LittleEndian(data[(v * s.Stride + el.Offset + k * 2)..])
                                    : data[v * s.Stride + el.Offset + k];
                        break;
                    case BlendWeights:
                        wslots = el.Slots;
                        wraw = new byte[vc * el.Slots];
                        for (var v = 0; v < vc; v++)
                            for (var k = 0; k < el.Slots; k++)
                                wraw[v * el.Slots + k] = data[v * s.Stride + el.Offset + k];
                        break;
                }
            }
        }
        if (prim.Pos.Length == 0) return null;
        if (joints is not null) (prim.Joints, prim.Weights) = Skin(vc, joints, jslots, wraw, wslots);

        // index array (binary): count, flags, format (0 = u16, 1 = u32), streaming, hash, data or source
        var ir = ia.ExtraReader();
        var count = ir.I32();
        ir.Skip(4);
        var fmt = ir.I32();
        var istreaming = ir.I32() != 0;
        ir.Skip(16);
        var isz = fmt == 0 ? 2 : 4;
        byte[] idata;
        if (istreaming)
        {
            var loc = StripCache(System.Text.Encoding.UTF8.GetString(ir.Span(ir.I32())));
            var off = (long)ir.U64();
            ir.U64();
            idata = res.Archive.ReadRange(loc, off, (long)count * isz);
        }
        else idata = ir.Bytes(count * isz);
        var start = p.Int("StartIndex");
        var end = p.Int("EndIndex");
        if (end <= start || end > count) { start = 0; end = count; }
        var baseVertex = (uint)Math.Max(0, p.Int("IndexOffset"));
        prim.Idx = new uint[end - start];
        for (var i = start; i < end; i++)
            prim.Idx[i - start] = baseVertex + (isz == 2 ? BinaryPrimitives.ReadUInt16LittleEndian(idata.AsSpan(i * 2)) : BinaryPrimitives.ReadUInt32LittleEndian(idata.AsSpan(i * 4)));
        return prim;
    }

    private static string StripCache(string loc) => loc.StartsWith("cache:", StringComparison.Ordinal) ? loc[6..] : loc;

    /// <summary>
    /// HZD skin weights ("3x8"): the weight bytes hold the weights of influences 1..n-1; influence 0 gets the rest
    /// (1 - sum). Result: 4 influences per vertex, normalized.
    /// </summary>
    private static (ushort[], float[]) Skin(int vc, ushort[] j, int jslots, byte[]? w, int wslots)
    {
        var joints = new ushort[vc * 4];
        var weights = new float[vc * 4];
        Span<float> ww = stackalloc float[8];
        Span<ushort> jj = stackalloc ushort[8];
        for (var v = 0; v < vc; v++)
        {
            var n = Math.Min(jslots, 8);
            float sum = 0;
            for (var k = 0; k < n; k++)
            {
                jj[k] = j[v * jslots + k];
                ww[k] = 0;
            }
            if (w is not null)
                for (var k = 1; k < n && k - 1 < wslots; k++) { ww[k] = w[v * wslots + k - 1] / 255f; sum += ww[k]; }
            ww[0] = Math.Max(0, 1 - sum);
            // keep the 4 largest
            for (var a = 0; a < 4 && a < n; a++)
            {
                var best = a;
                for (var b = a + 1; b < n; b++) if (ww[b] > ww[best]) best = b;
                (ww[a], ww[best]) = (ww[best], ww[a]);
                (jj[a], jj[best]) = (jj[best], jj[a]);
            }
            float total = 0;
            for (var k = 0; k < Math.Min(4, n); k++) total += ww[k];
            for (var k = 0; k < 4; k++)
            {
                joints[v * 4 + k] = k < n ? jj[k] : (ushort)0;
                weights[v * 4 + k] = k < n && total > 0 ? ww[k] / total : (k == 0 ? 1 : 0);
            }
        }
        return (joints, weights);
    }

    private static float[] ReadFloats(ReadOnlySpan<byte> data, int stride, int vc, Element el, int comps)
    {
        var o = new float[vc * comps];
        for (var v = 0; v < vc; v++)
        {
            var b = data[(v * stride + el.Offset)..];
            if (el.Storage == X10Y10Z10W2N)
            {
                var u = BinaryPrimitives.ReadUInt32LittleEndian(b);
                for (var k = 0; k < comps && k < 3; k++)
                {
                    var bits = (int)((u >> (k * 10)) & 0x3FF);
                    if (bits >= 512) bits -= 1024;
                    o[v * comps + k] = Math.Max(-1f, bits / 511f);
                }
                continue;
            }
            for (var k = 0; k < comps && k < el.Slots; k++)
            {
                o[v * comps + k] = el.Storage switch
                {
                    F32 => BinaryPrimitives.ReadSingleLittleEndian(b[(k * 4)..]),
                    F16 => (float)BinaryPrimitives.ReadHalfLittleEndian(b[(k * 2)..]),
                    SNorm16 => Math.Max(-1f, BinaryPrimitives.ReadInt16LittleEndian(b[(k * 2)..]) / 32767f),
                    UNorm16 => BinaryPrimitives.ReadUInt16LittleEndian(b[(k * 2)..]) / 65535f,
                    SShort => BinaryPrimitives.ReadInt16LittleEndian(b[(k * 2)..]),
                    UShort => BinaryPrimitives.ReadUInt16LittleEndian(b[(k * 2)..]),
                    UNorm8 => b[k] / 255f,
                    UByte => b[k],
                    _ => throw new NotSupportedException($"vertex storage type {el.Storage}"),
                };
            }
        }
        return o;
    }
}
