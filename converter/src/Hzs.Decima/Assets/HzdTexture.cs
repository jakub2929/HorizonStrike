using System.Buffers.Binary;
using Hzs.Decima.Archive;
using Hzs.Decima.Core;
using TinyBCSharp;

using Hzs.Decima.Sheets;

namespace Hzs.Decima.Assets;

/// <summary>Decoded image: 8-bit channels, row-major.</summary>
public sealed record Image(int Width, int Height, int Channels, byte[] Pixels)
{
    public byte[] ToPng() => Png.Encode(Width, Height, Channels, Pixels);

    /// <summary>Box-downscales by 2 until both edges are at most <paramref name="maxPx"/>.</summary>
    public Image Fit(int maxPx)
    {
        var img = this;
        while (img.Width > maxPx || img.Height > maxPx) img = img.Half();
        return img;
    }

    public Image Half()
    {
        int w = Math.Max(1, Width / 2), h = Math.Max(1, Height / 2), c = Channels;
        var dst = new byte[w * h * c];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                for (var k = 0; k < c; k++)
                {
                    int x0 = Math.Min(x * 2, Width - 1), x1 = Math.Min(x * 2 + 1, Width - 1);
                    int y0 = Math.Min(y * 2, Height - 1), y1 = Math.Min(y * 2 + 1, Height - 1);
                    var s = Pixels[(y0 * Width + x0) * c + k] + Pixels[(y0 * Width + x1) * c + k] + Pixels[(y1 * Width + x0) * c + k] + Pixels[(y1 * Width + x1) * c + k];
                    dst[(y * w + x) * c + k] = (byte)((s + 2) >> 2);
                }
        return new Image(w, h, c, dst);
    }
}

/// <summary>
/// HZD <c>Texture</c> (binary part after Name): 32-byte header (u16 type, u16 width, u16 height, u16 depth/slices,
/// u8 mip count, u8 EPixelFormat, ...), then u32 remaining size, u32 internal size, u32 external size, u32 external
/// mip count, the external data source (u32 length + "cache:&lt;path&gt;.core.stream", u64 offset, u64 length) and the
/// internal data. The largest <c>externalMips</c> mips live in the stream, the smaller ones inline, mip-major.
/// </summary>
public sealed class HzdTexture
{
    public string Name { get; init; } = "";
    public int Type { get; init; }       // ETextureType: 0 2D, 1 3D, 2 cube, 3 2D array
    public int Width { get; init; }
    public int Height { get; init; }
    public int Depth { get; init; }      // slices for arrays/3D
    public int Mips { get; init; }
    public int Format { get; init; }     // EPixelFormat
    public int ExternalSize { get; init; }
    public int ExternalMips { get; init; }
    public string? StreamPath { get; init; }
    public long StreamOffset { get; init; }
    public byte[] Internal { get; init; } = [];

    public const int RGBA_8888 = 12, RGBA_8888_REV = 13, RGBA_UNORM_8 = 29, RG_UNORM_8 = 30, R_UNORM_8 = 31, R_UNORM_16 = 28,
        R_FLOAT_16 = 22, R_FLOAT_32 = 18, RGBA_FLOAT_16 = 19, BC1 = 66, BC2 = 67, BC3 = 68, BC4U = 69, BC4S = 70, BC5U = 71, BC5S = 72,
        BC6U = 73, BC6S = 74, BC7 = 75;

    public static HzdTexture Parse(Obj tex)
    {
        var r = tex.ExtraReader();
        var type = r.U16(); var w = r.U16(); var h = r.U16(); var depth = r.U16();
        var mips = r.U8(); var fmt = r.U8();
        r.Skip(2 + 4 + 16);
        r.Skip(4); // remaining size
        var internalSize = r.I32();
        var externalSize = r.I32();
        var externalMips = r.I32();
        string? stream = null; long off = 0;
        if (externalSize > 0)
        {
            var n = r.I32();
            stream = System.Text.Encoding.UTF8.GetString(r.Span(n));
            stream = HzdNames.StripStream(stream);
            off = (long)r.U64();
            r.U64();
        }
        var inl = r.Bytes(Math.Min(internalSize, r.Remaining));
        return new HzdTexture
        {
            Name = tex.Has("Name") ? tex.Str("Name") : "", Type = type, Width = w, Height = h, Depth = Math.Max(1, (int)depth), Mips = mips, Format = fmt,
            ExternalSize = externalSize, ExternalMips = externalMips, StreamPath = stream, StreamOffset = off, Internal = inl,
        };
    }

    public static bool IsBlock(int f) => f is >= BC1 and <= BC7;
    public static int BlockBytes(int f) => f is BC1 or BC4U or BC4S ? 8 : 16;

    public static int BytesPerPixel(int f) => f switch
    {
        RGBA_8888 or RGBA_8888_REV or RGBA_UNORM_8 or R_FLOAT_32 => 4,
        RG_UNORM_8 or R_UNORM_16 or R_FLOAT_16 => 2,
        R_UNORM_8 => 1,
        RGBA_FLOAT_16 => 8,
        _ => throw new NotSupportedException($"pixel format {f}"),
    };

    public int SliceCount => Type is 1 or 3 ? Depth : Type == 2 ? 6 : 1;

    /// <summary>Byte size of one slice of mip <paramref name="mip"/>.</summary>
    public int MipSliceBytes(int mip)
    {
        int w = Math.Max(1, Width >> mip), h = Math.Max(1, Height >> mip);
        return IsBlock(Format) ? ((w + 3) / 4) * ((h + 3) / 4) * BlockBytes(Format) : w * h * BytesPerPixel(Format);
    }

    public int MipBytes(int mip) => MipSliceBytes(mip) * (Type == 1 ? Math.Max(1, Depth >> mip) : SliceCount);

    /// <summary>Raw bytes of one mip (all slices), from the stream or the inline data.</summary>
    public byte[] MipData(HzdArchive arc, int mip)
    {
        if (mip < ExternalMips)
        {
            long off = StreamOffset;
            for (var m = 0; m < mip; m++) off += MipBytes(m);
            return arc.ReadRange(StreamPath! + "", off, MipBytes(mip));
        }
        var ioff = 0;
        for (var m = ExternalMips; m < mip; m++) ioff += MipBytes(m);
        var len = MipBytes(mip);
        if (ioff + len > Internal.Length) throw new InvalidDataException($"{Name}: mip {mip} beyond inline data");
        return Internal.AsSpan(ioff, len).ToArray();
    }

    /// <summary>Smallest mip index whose edges are at most <paramref name="maxPx"/>.</summary>
    public int MipFor(int maxPx)
    {
        var mip = 0;
        while (mip < Mips - 1 && (Math.Max(1, Width >> mip) > maxPx || Math.Max(1, Height >> mip) > maxPx)) mip++;
        return mip;
    }

    /// <summary>Decodes one slice of one mip to 8-bit pixels (RGBA for colour formats, 1-2 channels for BC4/BC5/R8).</summary>
    public Image Decode(HzdArchive arc, int mip, int slice = 0) => Timers.Time("tex_decode", () => DecodeNow(arc, mip, slice));

    private Image DecodeNow(HzdArchive arc, int mip, int slice)
    {
        int w = Math.Max(1, Width >> mip), h = Math.Max(1, Height >> mip);
        var all = MipData(arc, mip);
        var sb = MipSliceBytes(mip);
        var src = all.AsSpan(slice * sb, sb).ToArray();
        switch (Format)
        {
            case BC1: return new Image(w, h, 4, Dec(BlockFormat.BC1, w, h, src));
            case BC2: return new Image(w, h, 4, Dec(BlockFormat.BC2, w, h, src));
            case BC3: return new Image(w, h, 4, Dec(BlockFormat.BC3, w, h, src));
            case BC7: return new Image(w, h, 4, Dec(BlockFormat.BC7, w, h, src));
            case BC4U: return new Image(w, h, 1, Narrow(Dec(BlockFormat.BC4U, w, h, src), 1));
            case BC4S: return new Image(w, h, 1, Narrow(Dec(BlockFormat.BC4S, w, h, src), 1));
            case BC5U: return new Image(w, h, 2, Narrow(Dec(BlockFormat.BC5U, w, h, src), 2));
            case BC5S: return new Image(w, h, 2, Narrow(Dec(BlockFormat.BC5S, w, h, src), 2));
            case BC6U: return new Image(w, h, 4, Bc6(Dec(BlockFormat.BC6HUf32, w, h, src), false));
            case BC6S: return new Image(w, h, 4, Bc6(Dec(BlockFormat.BC6HSf32, w, h, src), true));
            case RGBA_8888: case RGBA_UNORM_8: return new Image(w, h, 4, src);
            case RGBA_8888_REV:
                for (var i = 0; i < src.Length; i += 4) (src[i], src[i + 2]) = (src[i + 2], src[i]);
                return new Image(w, h, 4, src);
            case RG_UNORM_8: return new Image(w, h, 2, src);
            case R_UNORM_8: return new Image(w, h, 1, src);
            case R_UNORM_16:
                {
                    var d = new byte[w * h];
                    for (var i = 0; i < d.Length; i++) d[i] = (byte)(BinaryPrimitives.ReadUInt16LittleEndian(src.AsSpan(i * 2)) >> 8);
                    return new Image(w, h, 1, d);
                }
            default: throw new NotSupportedException($"{Name}: pixel format {Format}");
        }
    }

    private static byte[] Dec(BlockFormat f, int w, int h, byte[] src) => BlockDecoder.Create(f).Decode(w, h, src);

    /// <summary>BC6H decoded as RGBA float32 -> 8 bit: unsigned 0..1, signed -1..1 (normal maps of a few assets); alpha 255.</summary>
    private static byte[] Bc6(byte[] f32, bool signed)
    {
        var n = f32.Length / 16;
        var o = new byte[n * 4];
        for (var i = 0; i < n; i++)
        {
            for (var c = 0; c < 3; c++)
            {
                var v = BitConverter.ToSingle(f32, i * 16 + c * 4);
                if (signed) v = v * 0.5f + 0.5f;
                o[i * 4 + c] = (byte)Math.Clamp(v * 255f + 0.5f, 0, 255);
            }
            o[i * 4 + 3] = 255;
        }
        return o;
    }

    /// <summary>TinyBCSharp always writes 4 bytes per pixel (BC4: R replicated to RGB, BC5: R, G, 0); keeps the first channels.</summary>
    private static byte[] Narrow(byte[] rgba, int channels)
    {
        var n = rgba.Length / 4;
        var o = new byte[n * channels];
        for (var i = 0; i < n; i++)
            for (var c = 0; c < channels; c++) o[i * channels + c] = rgba[i * 4 + c];
        return o;
    }
}
