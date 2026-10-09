using System.Buffers.Binary;
using System.Text;

namespace Hzs.Decima.Archive;

/// <summary>MurmurHash3 x64 128-bit (Austin Appleby's public-domain algorithm). Decima uses seed 42.</summary>
public static class Murmur3
{
    private const ulong C1 = 0x87c37b91114253d5UL;
    private const ulong C2 = 0x4cf5ad432745937fUL;

    public static (ulong H1, ulong H2) Hash128(ReadOnlySpan<byte> data, uint seed = 42)
    {
        ulong h1 = seed, h2 = seed;
        var nblocks = data.Length / 16;
        for (var i = 0; i < nblocks; i++)
        {
            var k1 = BinaryPrimitives.ReadUInt64LittleEndian(data.Slice(i * 16));
            var k2 = BinaryPrimitives.ReadUInt64LittleEndian(data.Slice(i * 16 + 8));
            k1 *= C1; k1 = ulong.RotateLeft(k1, 31); k1 *= C2; h1 ^= k1;
            h1 = ulong.RotateLeft(h1, 27); h1 += h2; h1 = h1 * 5 + 0x52dce729;
            k2 *= C2; k2 = ulong.RotateLeft(k2, 33); k2 *= C1; h2 ^= k2;
            h2 = ulong.RotateLeft(h2, 31); h2 += h1; h2 = h2 * 5 + 0x38495ab5;
        }
        var tail = data.Slice(nblocks * 16);
        ulong t1 = 0, t2 = 0;
        for (var i = tail.Length - 1; i >= 8; i--) t2 ^= (ulong)tail[i] << ((i - 8) * 8);
        if (tail.Length > 8) { t2 *= C2; t2 = ulong.RotateLeft(t2, 33); t2 *= C1; h2 ^= t2; }
        for (var i = Math.Min(tail.Length, 8) - 1; i >= 0; i--) t1 ^= (ulong)tail[i] << (i * 8);
        if (tail.Length > 0) { t1 *= C1; t1 = ulong.RotateLeft(t1, 31); t1 *= C2; h1 ^= t1; }
        h1 ^= (ulong)data.Length; h2 ^= (ulong)data.Length;
        h1 += h2; h2 += h1;
        h1 = FMix(h1); h2 = FMix(h2);
        h1 += h2; h2 += h1;
        return (h1, h2);
    }

    private static ulong FMix(ulong k)
    {
        k ^= k >> 33; k *= 0xff51afd7ed558ccdUL; k ^= k >> 33; k *= 0xc4ceb9fe1a85ec53UL; k ^= k >> 33;
        return k;
    }

    /// <summary>Archive key of a resource path: first u64 of Hash128(UTF-8 path + NUL).</summary>
    public static ulong PathHash(string normalizedPath)
    {
        var n = Encoding.UTF8.GetByteCount(normalizedPath);
        Span<byte> buf = n < 1024 ? stackalloc byte[n + 1] : new byte[n + 1];
        Encoding.UTF8.GetBytes(normalizedPath, buf);
        buf[n] = 0;
        return Hash128(buf).H1;
    }
}
