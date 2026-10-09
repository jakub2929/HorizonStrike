using System.Buffers.Binary;
using TinyBCSharp;

namespace Hzs.Decima.Assets;

/// <summary>Block-compressed GPU formats the converter writes (names as in systems render.texture_format_*).</summary>
public enum BcFormat { BC1, BC3, BC5, BC7 }

/// <summary>How a mip chain is built: colour (box), cut-out (box + alpha coverage kept), normal (renormalised XY), data (box).</summary>
public enum MipMode { Color, Cutout, Normal, Data }

/// <summary>
/// DDS writer for the cache: "DDS " + DDS_HEADER (124 bytes, flags CAPS|HEIGHT|WIDTH|PIXELFORMAT|MIPMAPCOUNT|LINEARSIZE,
/// pixel format FourCC "DX10", caps TEXTURE|MIPMAP|COMPLEX) + DDS_HEADER_DXT10 (dxgiFormat, TEXTURE2D, arraySize 1),
/// then every mip level from the largest down to 1x1, each ceil(w/4) x ceil(h/4) blocks, rows top to bottom.
/// DXGI formats: BC1 71 / 72 (sRGB), BC3 77 / 78, BC5 83 (UNORM, R = X, G = Y), BC7 98 / 99.
/// Blocks are encoded by <see cref="BcEncode"/>; mips are built here.
/// </summary>
public static class Dds
{
    public const float CutoutThreshold = 0.5f;

    public static int Dxgi(BcFormat f, bool srgb) => f switch
    {
        BcFormat.BC1 => srgb ? 72 : 71,
        BcFormat.BC3 => srgb ? 78 : 77,
        BcFormat.BC5 => 83,
        BcFormat.BC7 => srgb ? 99 : 98,
        _ => throw new ArgumentOutOfRangeException(nameof(f)),
    };

    public static int BlockBytes(BcFormat f) => f == BcFormat.BC1 ? 8 : 16;

    public static BcFormat Parse(string name) => Enum.Parse<BcFormat>(name.Trim().ToUpperInvariant());

    /// <summary>Encodes an image (1-4 channels) with a full mip chain into a DDS file.</summary>
    public static byte[] Encode(Image img, BcFormat f, bool srgb, MipMode mode)
    {
        var rgba = ToRgba(img);
        var mips = Timers.Time("mips", () => Mips(rgba, img.Width, img.Height, mode));
        var blocks = Timers.Time("bc_encode", () => mips.Select(m => BcEncode.Encode(f, m.Px, m.W, m.H)).ToList());
        using var ms = new MemoryStream();
        WriteHeader(ms, img.Width, img.Height, mips.Count, f, srgb, blocks[0].Length);
        foreach (var b in blocks) ms.Write(b);
        return ms.ToArray();
    }

    private static void WriteHeader(Stream s, int w, int h, int mipCount, BcFormat f, bool srgb, int linearSize)
    {
        var hd = new byte[4 + 124 + 20];
        "DDS "u8.CopyTo(hd);
        void U32(int off, uint v) => BinaryPrimitives.WriteUInt32LittleEndian(hd.AsSpan(4 + off), v);
        U32(0, 124);                       // dwSize
        U32(4, 0x1 | 0x2 | 0x4 | 0x1000 | 0x20000 | 0x80000); // CAPS HEIGHT WIDTH PIXELFORMAT MIPMAPCOUNT LINEARSIZE
        U32(8, (uint)h);
        U32(12, (uint)w);
        U32(16, (uint)linearSize);         // bytes of the top mip
        U32(20, 0);                        // depth
        U32(24, (uint)mipCount);
        // 28..71 reserved; pixel format at 72
        U32(72, 32);                       // ddspf.dwSize
        U32(76, 0x4);                      // DDPF_FOURCC
        "DX10"u8.CopyTo(hd.AsSpan(4 + 80));
        U32(104, 0x1000 | 0x400000 | 0x8); // DDSCAPS_TEXTURE | MIPMAP | COMPLEX
        // DX10 extension
        U32(124, (uint)Dxgi(f, srgb));
        U32(128, 3);                       // D3D10_RESOURCE_DIMENSION_TEXTURE2D
        U32(132, 0);                       // misc flags
        U32(136, 1);                       // array size
        U32(140, 0);                       // misc flags 2 (alpha mode unknown)
        s.Write(hd);
    }

    private static byte[] ToRgba(Image img)
    {
        if (img.Channels == 4) return img.Pixels;
        var n = img.Width * img.Height;
        var o = new byte[n * 4];
        for (var i = 0; i < n; i++)
        {
            for (var c = 0; c < 3; c++) o[i * 4 + c] = img.Channels >= 3 ? img.Pixels[i * img.Channels + c] : c < img.Channels ? img.Pixels[i * img.Channels + c] : img.Channels == 1 ? img.Pixels[i] : (byte)0;
            o[i * 4 + 3] = 255;
        }
        return o;
    }

    private readonly record struct Mip(int W, int H, byte[] Px);

    private static List<Mip> Mips(byte[] px, int w, int h, MipMode mode)
    {
        var list = new List<Mip> { new(w, h, px) };
        var coverage = mode == MipMode.Cutout ? Coverage(px, 1f) : 0;
        while (w > 1 || h > 1)
        {
            int nw = Math.Max(1, w / 2), nh = Math.Max(1, h / 2);
            var o = new byte[nw * nh * 4];
            for (var y = 0; y < nh; y++)
                for (var x = 0; x < nw; x++)
                {
                    int x0 = Math.Min(x * 2, w - 1), x1 = Math.Min(x * 2 + 1, w - 1), y0 = Math.Min(y * 2, h - 1), y1 = Math.Min(y * 2 + 1, h - 1);
                    for (var c = 0; c < 4; c++)
                        o[(y * nw + x) * 4 + c] = (byte)((px[(y0 * w + x0) * 4 + c] + px[(y0 * w + x1) * 4 + c] + px[(y1 * w + x0) * 4 + c] + px[(y1 * w + x1) * 4 + c] + 2) >> 2);
                    if (mode == MipMode.Normal) Renormalize(o, (y * nw + x) * 4);
                }
            if (mode == MipMode.Cutout) KeepCoverage(o, coverage);
            list.Add(new Mip(nw, nh, o));
            (px, w, h) = (o, nw, nh);
        }
        return list;
    }

    /// <summary>Averaged XY is shorter (flatter normal, Z is rebuilt in the shader); only XY longer than 1 is pulled back.</summary>
    private static void Renormalize(byte[] o, int i)
    {
        float x = o[i] / 127.5f - 1, y = o[i + 1] / 127.5f - 1;
        var l = MathF.Sqrt(x * x + y * y);
        if (l <= 1f) return;
        o[i] = (byte)Math.Clamp((x / l + 1) * 127.5f + 0.5f, 0, 255);
        o[i + 1] = (byte)Math.Clamp((y / l + 1) * 127.5f + 0.5f, 0, 255);
    }

    /// <summary>Fraction of pixels whose alpha x scale passes the cut-out threshold.</summary>
    private static float Coverage(byte[] px, float scale)
    {
        long pass = 0, n = px.Length / 4;
        var t = CutoutThreshold * 255f;
        for (var i = 3; i < px.Length; i += 4) if (px[i] * scale >= t) pass++;
        return n == 0 ? 0 : (float)pass / n;
    }

    /// <summary>Scales the mip's alpha so the same share of pixels passes the cut-out as in the top mip (foliage stays full at distance).</summary>
    private static void KeepCoverage(byte[] o, float target)
    {
        if (target <= 0) return;
        float lo = 0.25f, hi = 8f;
        for (var it = 0; it < 12; it++)
        {
            var mid = (lo + hi) / 2;
            if (Coverage(o, mid) < target) lo = mid; else hi = mid;
        }
        for (var i = 3; i < o.Length; i += 4) o[i] = (byte)Math.Min(255, o[i] * hi + 0.5f);
    }

    /// <summary>Dev check: decodes one level of BC blocks back to RGBA (TinyBCSharp).</summary>
    public static byte[] DecodeBlocks(BcFormat f, byte[] blocks, int w, int h) => BlockDecoder.Create(f switch
    {
        BcFormat.BC1 => BlockFormat.BC1,
        BcFormat.BC3 => BlockFormat.BC3,
        BcFormat.BC5 => BlockFormat.BC5U,
        _ => BlockFormat.BC7,
    }).Decode(w, h, blocks);

    /// <summary>Dev check: header fields of a DDS file written by <see cref="Encode"/> (width, height, mips, dxgi) or null.</summary>
    public static (int W, int H, int Mips, int Dxgi)? ReadHeader(ReadOnlySpan<byte> d)
    {
        if (d.Length < 148 || !d[..4].SequenceEqual("DDS "u8) || !d.Slice(84, 4).SequenceEqual("DX10"u8)) return null;
        static int R(ReadOnlySpan<byte> b, int off) => BinaryPrimitives.ReadInt32LittleEndian(b[(4 + off)..]);
        return (R(d, 12), R(d, 8), R(d, 24), R(d, 124));
    }
}
