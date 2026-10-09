using System.Buffers.Binary;
using System.IO.Compression;

namespace Hzs.Decima.Assets;

/// <summary>Minimal PNG encoder (8-bit gray, RGB or RGBA; filter "up" per row; zlib via ZLibStream).</summary>
public static class Png
{
    private static readonly uint[] CrcTable = BuildCrc();

    private static uint[] BuildCrc()
    {
        var t = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            var c = n;
            for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            t[n] = c;
        }
        return t;
    }

    private static uint Crc(ReadOnlySpan<byte> a, ReadOnlySpan<byte> b)
    {
        var c = 0xFFFFFFFFu;
        foreach (var x in a) c = CrcTable[(c ^ x) & 0xFF] ^ (c >> 8);
        foreach (var x in b) c = CrcTable[(c ^ x) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }

    /// <summary>Encodes <paramref name="pixels"/> (row-major, <paramref name="channels"/> = 1, 3 or 4 bytes per pixel).</summary>
    public static byte[] Encode(int width, int height, int channels, ReadOnlySpan<byte> pixels, CompressionLevel level = CompressionLevel.Fastest)
    {
        var colorType = channels switch { 1 => (byte)0, 2 => (byte)4, 3 => (byte)2, 4 => (byte)6, _ => throw new ArgumentException("channels") };
        var stride = width * channels;
        if (pixels.Length < stride * height) throw new ArgumentException("pixel buffer too small");
        using var raw = new MemoryStream();
        using (var z = new ZLibStream(raw, level, leaveOpen: true))
        {
            var line = new byte[stride + 1];
            for (var y = 0; y < height; y++)
            {
                var row = pixels.Slice(y * stride, stride);
                if (y == 0) { line[0] = 0; row.CopyTo(line.AsSpan(1)); }
                else
                {
                    line[0] = 2; // Up filter: helps smooth images (terrain, normal maps)
                    var prev = pixels.Slice((y - 1) * stride, stride);
                    for (var i = 0; i < stride; i++) line[i + 1] = (byte)(row[i] - prev[i]);
                }
                z.Write(line);
            }
        }
        using var png = new MemoryStream();
        png.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        Span<byte> ihdr = stackalloc byte[13];
        BinaryPrimitives.WriteInt32BigEndian(ihdr, width);
        BinaryPrimitives.WriteInt32BigEndian(ihdr[4..], height);
        ihdr[8] = 8; ihdr[9] = colorType; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
        Chunk(png, "IHDR"u8, ihdr);
        Chunk(png, "IDAT"u8, raw.GetBuffer().AsSpan(0, (int)raw.Length));
        Chunk(png, "IEND"u8, []);
        return png.ToArray();
    }

    private static void Chunk(Stream s, ReadOnlySpan<byte> type, ReadOnlySpan<byte> data)
    {
        Span<byte> b4 = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(b4, data.Length);
        s.Write(b4);
        s.Write(type);
        s.Write(data);
        BinaryPrimitives.WriteUInt32BigEndian(b4, Crc(type, data));
        s.Write(b4);
    }
}
