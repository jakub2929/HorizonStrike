using System.Numerics;

namespace Hzs.Decima.Assets;

/// <summary>
/// Own block encoders (no dependency), written from the public BCn format descriptions:
/// BC1 = 4-colour mode, endpoints from the principal axis + one least-squares refinement;
/// BC4 (and BC5 = BC4 on R and G, BC3 = BC4 alpha + BC1 colour) = 8-value mode from min/max;
/// BC7 = mode 6 only (one subset, RGBA 7.7.7.7 endpoints + p-bit each, 4-bit indices), principal axis + refinement.
/// Input: RGBA8 rows, any size (edge blocks repeat the last texel). Output: blocks row by row.
/// </summary>
public static class BcEncode
{
    public static byte[] Encode(BcFormat f, byte[] rgba, int w, int h)
    {
        int bw = Math.Max(1, (w + 3) / 4), bh = Math.Max(1, (h + 3) / 4), bb = Dds.BlockBytes(f);
        var o = new byte[bw * bh * bb];
        Parallel.For(0, bh, new ParallelOptions { MaxDegreeOfParallelism = (long)w * h >= 1 << 20 ? Environment.ProcessorCount : 1 }, by =>
        {
            Span<byte> blk = stackalloc byte[64];
            for (var bx = 0; bx < bw; bx++)
            {
                for (var y = 0; y < 4; y++)
                    for (var x = 0; x < 4; x++)
                    {
                        int sx = Math.Min(bx * 4 + x, w - 1), sy = Math.Min(by * 4 + y, h - 1);
                        for (var c = 0; c < 4; c++) blk[(y * 4 + x) * 4 + c] = rgba[(sy * w + sx) * 4 + c];
                    }
                var dst = o.AsSpan((by * bw + bx) * bb, bb);
                switch (f)
                {
                    case BcFormat.BC1: Bc1(blk, dst); break;
                    case BcFormat.BC3: Bc4(blk, 3, dst[..8]); Bc1(blk, dst[8..]); break;
                    case BcFormat.BC5: Bc4(blk, 0, dst[..8]); Bc4(blk, 1, dst[8..]); break;
                    case BcFormat.BC7: Bc7Mode6(blk, dst); break;
                }
            }
        });
        return o;
    }

    // ---------------------------------------------------------------- BC1

    private static void Bc1(ReadOnlySpan<byte> blk, Span<byte> dst)
    {
        Span<Vector3> px = stackalloc Vector3[16];
        for (var i = 0; i < 16; i++) px[i] = new Vector3(blk[i * 4], blk[i * 4 + 1], blk[i * 4 + 2]);
        var (lo, hi) = Axis3(px);
        Span<int> idx = stackalloc int[16];
        var (c0, c1) = (To565(hi), To565(lo));
        Indices1(px, c0, c1, idx);
        // least-squares refinement of the endpoints for the chosen indices
        if (Refine1(px, idx, out var e0, out var e1))
        {
            var (r0, r1) = (To565(e0), To565(e1));
            Span<int> idx2 = stackalloc int[16];
            if (Err1(px, r0, r1, idx2) < Err1(px, c0, c1, idx)) { (c0, c1) = (r0, r1); idx2.CopyTo(idx); }
        }
        if (c0 < c1)
        {
            (c0, c1) = (c1, c0);
            for (var i = 0; i < 16; i++) idx[i] = idx[i] switch { 0 => 1, 1 => 0, 2 => 3, _ => 2 };
        }
        else if (c0 == c1) idx.Fill(0);
        dst[0] = (byte)c0; dst[1] = (byte)(c0 >> 8); dst[2] = (byte)c1; dst[3] = (byte)(c1 >> 8);
        uint bits = 0;
        for (var i = 0; i < 16; i++) bits |= (uint)idx[i] << (i * 2);
        dst[4] = (byte)bits; dst[5] = (byte)(bits >> 8); dst[6] = (byte)(bits >> 16); dst[7] = (byte)(bits >> 24);
    }

    private static ushort To565(Vector3 c)
    {
        int r = Math.Clamp((int)MathF.Round(c.X * 31 / 255f), 0, 31), g = Math.Clamp((int)MathF.Round(c.Y * 63 / 255f), 0, 63), b = Math.Clamp((int)MathF.Round(c.Z * 31 / 255f), 0, 31);
        return (ushort)(r << 11 | g << 5 | b);
    }

    private static Vector3 From565(int c) => new((c >> 11 & 31) * 255f / 31, (c >> 5 & 63) * 255f / 63, (c & 31) * 255f / 31);

    private static float Err1(ReadOnlySpan<Vector3> px, int c0, int c1, Span<int> idx)
    {
        Indices1(px, c0, c1, idx);
        Span<Vector3> pal = stackalloc Vector3[4];
        Palette1(c0, c1, pal);
        float e = 0;
        for (var i = 0; i < 16; i++) e += Vector3.DistanceSquared(px[i], pal[idx[i]]);
        return e;
    }

    private static void Palette1(int c0, int c1, Span<Vector3> pal)
    {
        var (a, b) = (From565(c0), From565(c1));
        pal[0] = a; pal[1] = b; pal[2] = (2 * a + b) / 3; pal[3] = (a + 2 * b) / 3;
    }

    private static void Indices1(ReadOnlySpan<Vector3> px, int c0, int c1, Span<int> idx)
    {
        Span<Vector3> pal = stackalloc Vector3[4];
        Palette1(c0, c1, pal);
        for (var i = 0; i < 16; i++)
        {
            var best = 0; var bd = float.MaxValue;
            for (var k = 0; k < 4; k++) { var d = Vector3.DistanceSquared(px[i], pal[k]); if (d < bd) { bd = d; best = k; } }
            idx[i] = best;
        }
    }

    private static bool Refine1(ReadOnlySpan<Vector3> px, ReadOnlySpan<int> idx, out Vector3 e0, out Vector3 e1)
    {
        // weights of endpoint 0 per palette index: 1, 0, 2/3, 1/3
        float aa = 0, ab = 0, bb = 0;
        Vector3 ax = default, bx = default;
        for (var i = 0; i < 16; i++)
        {
            var a = idx[i] switch { 0 => 1f, 1 => 0f, 2 => 2f / 3, _ => 1f / 3 };
            var b = 1 - a;
            aa += a * a; ab += a * b; bb += b * b; ax += a * px[i]; bx += b * px[i];
        }
        var det = aa * bb - ab * ab;
        if (MathF.Abs(det) < 1e-6f) { e0 = e1 = default; return false; }
        e0 = Vector3.Clamp((ax * bb - bx * ab) / det, Vector3.Zero, new Vector3(255));
        e1 = Vector3.Clamp((bx * aa - ax * ab) / det, Vector3.Zero, new Vector3(255));
        return true;
    }

    /// <summary>Extremes of the block along its principal axis (mean +- projections).</summary>
    private static (Vector3 Lo, Vector3 Hi) Axis3(ReadOnlySpan<Vector3> px)
    {
        var mean = Vector3.Zero;
        foreach (var p in px) mean += p;
        mean /= px.Length;
        float xx = 0, xy = 0, xz = 0, yy = 0, yz = 0, zz = 0;
        foreach (var p in px)
        {
            var d = p - mean;
            xx += d.X * d.X; xy += d.X * d.Y; xz += d.X * d.Z; yy += d.Y * d.Y; yz += d.Y * d.Z; zz += d.Z * d.Z;
        }
        var axis = new Vector3(1, 1, 1);
        for (var it = 0; it < 8; it++)
        {
            var n = new Vector3(xx * axis.X + xy * axis.Y + xz * axis.Z, xy * axis.X + yy * axis.Y + yz * axis.Z, xz * axis.X + yz * axis.Y + zz * axis.Z);
            var l = n.Length();
            if (l < 1e-6f) break;
            axis = n / l;
        }
        float mn = float.MaxValue, mx = float.MinValue;
        foreach (var p in px) { var t = Vector3.Dot(p - mean, axis); mn = Math.Min(mn, t); mx = Math.Max(mx, t); }
        return (Vector3.Clamp(mean + axis * mn, Vector3.Zero, new Vector3(255)), Vector3.Clamp(mean + axis * mx, Vector3.Zero, new Vector3(255)));
    }

    // ---------------------------------------------------------------- BC4

    private static void Bc4(ReadOnlySpan<byte> blk, int ch, Span<byte> dst)
    {
        int mn = 255, mx = 0;
        for (var i = 0; i < 16; i++) { int v = blk[i * 4 + ch]; mn = Math.Min(mn, v); mx = Math.Max(mx, v); }
        dst[0] = (byte)mx; dst[1] = (byte)mn;
        ulong bits = 0;
        if (mx > mn)
        {
            Span<int> pal = stackalloc int[8];
            pal[0] = mx; pal[1] = mn;
            for (var k = 1; k <= 6; k++) pal[k + 1] = ((7 - k) * mx + k * mn + 3) / 7;
            for (var i = 0; i < 16; i++)
            {
                int v = blk[i * 4 + ch], best = 0, bd = int.MaxValue;
                for (var k = 0; k < 8; k++) { var d = Math.Abs(v - pal[k]); if (d < bd) { bd = d; best = k; } }
                bits |= (ulong)best << (i * 3);
            }
        }
        for (var k = 0; k < 6; k++) dst[2 + k] = (byte)(bits >> (k * 8));
    }

    // ---------------------------------------------------------------- BC7 mode 6

    private static readonly int[] W4 = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64];

    private static void Bc7Mode6(ReadOnlySpan<byte> blk, Span<byte> dst)
    {
        Span<Vector4> px = stackalloc Vector4[16];
        for (var i = 0; i < 16; i++) px[i] = new Vector4(blk[i * 4], blk[i * 4 + 1], blk[i * 4 + 2], blk[i * 4 + 3]);
        var (lo, hi) = Axis4(px);
        Span<int> e = stackalloc int[8]; // quantised RGBA endpoint 0, endpoint 1 (8-bit with p-bit)
        Span<int> idx = stackalloc int[16];
        Quant7P(lo, e[..4]); Quant7P(hi, e[4..]);
        var err = Indices7(px, e, idx);
        // refinement: least-squares endpoints for the indices
        float aa = 0, ab = 0, bb = 0;
        Vector4 ax = default, bx = default;
        for (var i = 0; i < 16; i++)
        {
            var b = W4[idx[i]] / 64f; var a = 1 - b;
            aa += a * a; ab += a * b; bb += b * b; ax += a * px[i]; bx += b * px[i];
        }
        var det = aa * bb - ab * ab;
        if (MathF.Abs(det) > 1e-6f)
        {
            Span<int> e2 = stackalloc int[8];
            Span<int> idx2 = stackalloc int[16];
            Quant7P(Vector4.Clamp((ax * bb - bx * ab) / det, Vector4.Zero, new Vector4(255)), e2[..4]);
            Quant7P(Vector4.Clamp((bx * aa - ax * ab) / det, Vector4.Zero, new Vector4(255)), e2[4..]);
            var err2 = Indices7(px, e2, idx2);
            if (err2 < err) { e2.CopyTo(e); idx2.CopyTo(idx); }
        }
        // anchor (texel 0) index must have its top bit clear: swap endpoints and invert indices
        if (idx[0] >= 8)
        {
            for (var c = 0; c < 4; c++) (e[c], e[4 + c]) = (e[4 + c], e[c]);
            for (var i = 0; i < 16; i++) idx[i] = 15 - idx[i];
        }
        // pack: mode 6 = bit 6 set; then R0 R1 G0 G1 B0 B1 A0 A1 (7 bits), P0, P1, indices (anchor 3 bits, others 4)
        var w = new BitWriter(dst);
        w.Put(1 << 6, 7);
        for (var c = 0; c < 4; c++) { w.Put(e[c] >> 1, 7); w.Put(e[4 + c] >> 1, 7); }
        w.Put(e[0] & 1, 1); w.Put(e[4] & 1, 1);
        w.Put(idx[0], 3);
        for (var i = 1; i < 16; i++) w.Put(idx[i], 4);
    }

    /// <summary>7-bit endpoint + one p-bit shared by the 4 channels: the p-bit with the smaller error.</summary>
    private static void Quant7P(Vector4 v, Span<int> o)
    {
        float best = float.MaxValue;
        Span<float> vv = [v.X, v.Y, v.Z, v.W];
        Span<int> q = stackalloc int[4];
        for (var p = 0; p < 2; p++)
        {
            float err = 0;
            for (var c = 0; c < 4; c++)
            {
                var k = Math.Clamp((int)MathF.Round((vv[c] - p) / 2f), 0, 127);
                q[c] = k << 1 | p;
                err += (q[c] - vv[c]) * (q[c] - vv[c]);
            }
            if (err < best) { best = err; q.CopyTo(o); }
        }
    }

    private static float Indices7(ReadOnlySpan<Vector4> px, ReadOnlySpan<int> e, Span<int> idx)
    {
        Span<Vector4> pal = stackalloc Vector4[16];
        for (var k = 0; k < 16; k++)
        {
            var wgt = W4[k];
            pal[k] = new Vector4(
                ((64 - wgt) * e[0] + wgt * e[4] + 32) >> 6, ((64 - wgt) * e[1] + wgt * e[5] + 32) >> 6,
                ((64 - wgt) * e[2] + wgt * e[6] + 32) >> 6, ((64 - wgt) * e[3] + wgt * e[7] + 32) >> 6);
        }
        float total = 0;
        for (var i = 0; i < 16; i++)
        {
            var best = 0; var bd = float.MaxValue;
            for (var k = 0; k < 16; k++) { var d = Vector4.DistanceSquared(px[i], pal[k]); if (d < bd) { bd = d; best = k; } }
            idx[i] = best; total += bd;
        }
        return total;
    }

    private static (Vector4 Lo, Vector4 Hi) Axis4(ReadOnlySpan<Vector4> px)
    {
        var mean = Vector4.Zero;
        foreach (var p in px) mean += p;
        mean /= px.Length;
        Span<float> cov = stackalloc float[16];
        foreach (var p in px)
        {
            var d = p - mean;
            Span<float> dv = [d.X, d.Y, d.Z, d.W];
            for (var r = 0; r < 4; r++) for (var c = 0; c < 4; c++) cov[r * 4 + c] += dv[r] * dv[c];
        }
        Span<float> axis = [1, 1, 1, 1];
        Span<float> n = stackalloc float[4];
        for (var it = 0; it < 8; it++)
        {
            for (var r = 0; r < 4; r++) n[r] = cov[r * 4] * axis[0] + cov[r * 4 + 1] * axis[1] + cov[r * 4 + 2] * axis[2] + cov[r * 4 + 3] * axis[3];
            var l = MathF.Sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2] + n[3] * n[3]);
            if (l < 1e-6f) break;
            for (var r = 0; r < 4; r++) axis[r] = n[r] / l;
        }
        var ax = new Vector4(axis[0], axis[1], axis[2], axis[3]);
        float mn = float.MaxValue, mx = float.MinValue;
        foreach (var p in px) { var t = Vector4.Dot(p - mean, ax); mn = Math.Min(mn, t); mx = Math.Max(mx, t); }
        return (Vector4.Clamp(mean + ax * mn, Vector4.Zero, new Vector4(255)), Vector4.Clamp(mean + ax * mx, Vector4.Zero, new Vector4(255)));
    }

    private ref struct BitWriter(Span<byte> dst)
    {
        private readonly Span<byte> _d = dst;
        private int _pos;

        public void Put(int value, int bits)
        {
            for (var b = 0; b < bits; b++, _pos++)
                if ((value >> b & 1) != 0) _d[_pos >> 3] |= (byte)(1 << (_pos & 7));
        }
    }
}
