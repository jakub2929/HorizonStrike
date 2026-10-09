using System.Buffers.Binary;
using System.Text;

namespace Hzs.Decima.Core;

/// <summary>Reference kinds of a serialized <c>Ref&lt;T&gt;</c> / <c>StreamingRef&lt;T&gt;</c> / <c>UUIDRef&lt;T&gt;</c>.</summary>
public enum RefKind : byte { None = 0, InternalLink = 1, ExternalLink = 2, ExternalRef = 3, InternalRef = 5 }

/// <summary>A reference to an object in the same core file (Path null) or in another core file.</summary>
public readonly record struct Ref(RefKind Kind, Guid Uuid, string? Path)
{
    public bool IsNull => Kind == RefKind.None;
    public bool IsExternal => Kind is RefKind.ExternalLink or RefKind.ExternalRef;
    public override string ToString() => Kind == RefKind.None ? "null" : Path is null ? $"#{Uuid}" : $"{Path}#{Uuid}";
}

/// <summary>Little-endian reader over a decompressed core file (Decima binary serialization).</summary>
public sealed class BinReader(byte[] data, int position = 0, int? end = null)
{
    public byte[] Data { get; } = data;
    public int Position { get; set; } = position;
    public int End { get; } = end ?? data.Length;
    public int Remaining => End - Position;

    private ReadOnlySpan<byte> Take(int n)
    {
        if (n < 0 || Position + n > End) throw new InvalidDataException($"read past end ({Position}+{n} > {End})");
        var s = Data.AsSpan(Position, n);
        Position += n;
        return s;
    }

    public byte U8() => Take(1)[0];
    public sbyte I8() => (sbyte)Take(1)[0];
    public bool Bool() => Take(1)[0] != 0;
    public ushort U16() => BinaryPrimitives.ReadUInt16LittleEndian(Take(2));
    public short I16() => BinaryPrimitives.ReadInt16LittleEndian(Take(2));
    public uint U32() => BinaryPrimitives.ReadUInt32LittleEndian(Take(4));
    public int I32() => BinaryPrimitives.ReadInt32LittleEndian(Take(4));
    public ulong U64() => BinaryPrimitives.ReadUInt64LittleEndian(Take(8));
    public long I64() => BinaryPrimitives.ReadInt64LittleEndian(Take(8));
    public float F32() => BinaryPrimitives.ReadSingleLittleEndian(Take(4));
    public double F64() => BinaryPrimitives.ReadDoubleLittleEndian(Take(8));
    public Half F16() => BinaryPrimitives.ReadHalfLittleEndian(Take(2));
    public Guid Guid() => new(Take(16));
    public byte[] Bytes(int n) => Take(n).ToArray();
    public ReadOnlySpan<byte> Span(int n) => Take(n);
    public void Skip(int n) => Take(n);

    /// <summary>Decima String: u32 length, then (if non-empty) u32 CRC32C and UTF-8 bytes.</summary>
    public string Str()
    {
        var n = I32();
        if (n <= 0) return "";
        Skip(4); // CRC32C of the bytes
        return Encoding.UTF8.GetString(Take(n));
    }

    /// <summary>Decima WString: u32 length in UTF-16 units, then the units.</summary>
    public string WStr()
    {
        var n = I32();
        return n <= 0 ? "" : Encoding.Unicode.GetString(Take(n * 2));
    }

    public Ref Ref()
    {
        var kind = (RefKind)U8();
        return kind switch
        {
            RefKind.None => default,
            RefKind.InternalLink or RefKind.InternalRef => new Ref(kind, Guid(), null),
            RefKind.ExternalLink or RefKind.ExternalRef => new Ref(kind, Guid(), Str()),
            _ => throw new InvalidDataException($"unknown reference kind {(byte)kind} at {Position - 1}"),
        };
    }

    public int Count()
    {
        var n = I32();
        if (n < 0 || n > Remaining) throw new InvalidDataException($"bad array count {n} at {Position - 4}");
        return n;
    }

    public T[] Array<T>(Func<BinReader, T> item)
    {
        var n = Count();
        var a = new T[n];
        for (var i = 0; i < n; i++) a[i] = item(this);
        return a;
    }

    /// <summary>HashMap/HashSet: count, then per element a u32 hash followed by the element.</summary>
    public T[] HashMap<T>(Func<BinReader, T> item)
    {
        var n = Count();
        var a = new T[n];
        for (var i = 0; i < n; i++) { Skip(4); a[i] = item(this); }
        return a;
    }

    public float[] F32Array() { var n = Count(); var a = new float[n]; for (var i = 0; i < n; i++) a[i] = F32(); return a; }
    public int[] I32Array() { var n = Count(); var a = new int[n]; for (var i = 0; i < n; i++) a[i] = I32(); return a; }
    public uint[] U32Array() { var n = Count(); var a = new uint[n]; for (var i = 0; i < n; i++) a[i] = U32(); return a; }
    public ushort[] U16Array() { var n = Count(); var a = new ushort[n]; for (var i = 0; i < n; i++) a[i] = U16(); return a; }
    public byte[] U8Array() => Bytes(Count());
    public string[] StrArray() => Array(r => r.Str());
    public Ref[] RefArray() => Array(r => r.Ref());
}
