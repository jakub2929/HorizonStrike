using System.Buffers.Binary;
using Hzs.Decima.Archive;
using Hzs.Decima.Core;

using Hzs.Decima.Sheets;

namespace Hzs.Decima.Audio;

/// <summary>
/// WaveResource -> playable file. Layout facts: members EncodingQuality, IsStreaming, UseVBR come before the ObjectUUID;
/// WaveData is inline unless IsStreaming (then the binary part is a data source into a .stream, holding a RIFF file).
/// EWaveDataEncoding: 0 PCM, 1 PCM_FLOAT, 2 XWMA, 3 ATRAC9, 4 MP3, 5 ADPCM, 6 AAC. On PC the small effects are MP3
/// (inline frames) or 16-bit PCM; weather beds and spot sounds are ATRAC9 in an AT9 RIFF file (decoded with the vendored
/// LibAtrac9, MIT; more than 2 channels are downmixed to stereo).
/// </summary>
public static class Waves
{
    public sealed record Exported(string Ext, byte[] Data, double Seconds);

    /// <summary>Dev: the streamed data source of a wave (location, offset, length) or null when inline.</summary>
    public static (string Loc, long Off, long Len)? StreamSource(Obj wave)
    {
        if (!wave.Bool("IsStreaming")) return null;
        var r = wave.ExtraReader();
        var loc = System.Text.Encoding.UTF8.GetString(r.Span(r.I32()));
        return (loc, (long)r.U64(), (long)r.U64());
    }

    /// <summary>The wave's payload: inline WaveData, or the streamed range of the .stream file.</summary>
    public static byte[] RawData(HzdArchive arc, Obj wave)
    {
        if (!wave.Bool("IsStreaming")) return wave.Prims<byte>("WaveData");
        var r = wave.ExtraReader();
        var loc = System.Text.Encoding.UTF8.GetString(r.Span(r.I32()));
        loc = HzdNames.StripStream(loc);
        var off = (long)r.U64();
        var len = (long)r.U64();
        if (len == 0 && wave.Has("WaveDataSize")) len = wave.Long("WaveDataSize"); // bank waves: the source length is 0
        return len > 0 ? arc.ReadRange(loc, off, len) : [];
    }

    public static Exported? Export(HzdArchive arc, Obj wave)
    {
        var enc = wave.Int("Encoding");
        var data = RawData(arc, wave);
        if (wave.Bool("IsStreaming") && enc == 0 && data.Length >= 4 && data.AsSpan(0, 4).SequenceEqual("RIFF"u8)) return new Exported("wav", data, Seconds(wave));
        if (data.Length == 0) return null;
        return enc switch
        {
            4 => new Exported("mp3", data, Seconds(wave)),
            3 => DecodeAt9(data) is { } at9 ? new Exported("wav", Riff(at9.Pcm, at9.Rate, at9.Channels, 16), Seconds(wave)) : null,
            0 => new Exported("wav", Riff(data, wave.Int("SampleRate"), wave.Int("ChannelCount"), wave.Int("BitsPerSample")), Seconds(wave)),
            _ => null,
        };
    }

    /// <summary>
    /// AT9 RIFF: fmt = WAVEFORMATEXTENSIBLE (channel mask at +20) + ATRAC9 version (+40) + 4-byte config (+44); fact =
    /// sample count, input overlap delay, encoder delay; data = superframes. Returns interleaved 16-bit PCM without the
    /// encoder delay; more than 2 channels are downmixed to stereo (L = FL + 0.707 (FC + BL + SL), R alike; LFE dropped;
    /// scaled down only if the mix would clip).
    /// </summary>
    public static (byte[] Pcm, int Rate, int Channels)? DecodeAt9(byte[] riff)
    {
        if (riff.Length < 12 || !riff.AsSpan(0, 4).SequenceEqual("RIFF"u8) || !riff.AsSpan(8, 4).SequenceEqual("WAVE"u8)) return null;
        int fmt = -1, fact = -1, factLen = 0, data = -1, dataLen = 0;
        for (var o = 12; o + 8 <= riff.Length;)
        {
            var id = System.Text.Encoding.ASCII.GetString(riff, o, 4);
            var len = BinaryPrimitives.ReadInt32LittleEndian(riff.AsSpan(o + 4));
            if (id == "fmt ") fmt = o + 8;
            else if (id == "fact") { fact = o + 8; factLen = len; }
            else if (id == "data") { data = o + 8; dataLen = Math.Min(len, riff.Length - data); }
            o += 8 + len + (len & 1);
        }
        if (fmt < 0 || data < 0 || fmt + 48 > riff.Length) return null;
        var mask = BinaryPrimitives.ReadInt32LittleEndian(riff.AsSpan(fmt + 20));
        var dec = new LibAtrac9.Atrac9Decoder();
        dec.Initialize(riff.AsSpan(fmt + 44, 4).ToArray());
        var cfg = dec.Config;
        int ch = cfg.ChannelCount, sf = cfg.SuperframeSamples, sfBytes = cfg.SuperframeBytes;
        var total = fact >= 0 && factLen >= 4 ? BinaryPrimitives.ReadInt32LittleEndian(riff.AsSpan(fact)) : int.MaxValue;
        var delay = fact >= 0 && factLen >= 12 ? BinaryPrimitives.ReadInt32LittleEndian(riff.AsSpan(fact + 8)) : 0;
        var buf = new short[ch][];
        for (var c = 0; c < ch; c++) buf[c] = new short[sf];
        var frames = dataLen / sfBytes;
        var pcm = new float[ch][];
        for (var c = 0; c < ch; c++) pcm[c] = new float[frames * sf];
        var block = new byte[sfBytes];
        for (var f = 0; f < frames; f++)
        {
            Array.Copy(riff, data + f * sfBytes, block, 0, sfBytes);
            dec.Decode(block, buf);
            for (var c = 0; c < ch; c++)
                for (var i = 0; i < sf; i++) pcm[c][f * sf + i] = buf[c][i];
        }
        var n = Math.Max(0, Math.Min(frames * sf - delay, total));
        var outCh = ch > 2 ? 2 : ch;
        var mix = new float[outCh][];
        for (var c = 0; c < outCh; c++) mix[c] = new float[n];
        if (ch <= 2)
            for (var c = 0; c < ch; c++) Array.Copy(pcm[c], delay, mix[c], 0, n);
        else
        {
            // channel order of the extensible mask: FL FR FC LFE BL BR FLC FRC BC SL SR ...
            var speakers = Enumerable.Range(0, 18).Where(b => (mask >> b & 1) != 0).Take(ch).ToList();
            if (speakers.Count < ch) speakers = [0, 1, 2, 3, 4, 5, 9, 10]; // default 5.1 / 7.1 order
            for (var c = 0; c < ch; c++)
            {
                var sp = speakers[c];
                var (wl, wr) = sp switch
                {
                    0 => (1f, 0f), 1 => (0f, 1f), 2 => (0.707f, 0.707f), 3 => (0f, 0f),
                    4 or 9 => (0.707f, 0f), 5 or 10 => (0f, 0.707f), 8 => (0.5f, 0.5f), _ => (0.5f, 0.5f),
                };
                for (var i = 0; i < n; i++) { mix[0][i] += wl * pcm[c][delay + i]; mix[1][i] += wr * pcm[c][delay + i]; }
            }
        }
        var peak = mix.Max(m => m.Length == 0 ? 0 : m.Max(MathF.Abs));
        var scale = peak > 32767f ? 32767f / peak : 1f;
        var o16 = new byte[n * outCh * 2];
        for (var i = 0; i < n; i++)
            for (var c = 0; c < outCh; c++)
                BinaryPrimitives.WriteInt16LittleEndian(o16.AsSpan((i * outCh + c) * 2), (short)Math.Clamp(MathF.Round(mix[c][i] * scale), -32768, 32767));
        return (o16, cfg.SampleRate, outCh);
    }

    private static double Seconds(Obj w) => w.Int("SampleRate") > 0 ? w.Int("SampleCount") / (double)w.Int("SampleRate") : 0;

    /// <summary>16-bit (or 8-bit) PCM in a canonical RIFF/WAVE container.</summary>
    public static byte[] Riff(byte[] pcm, int rate, int channels, int bits)
    {
        bits = bits is 8 or 16 or 24 or 32 ? bits : 16;
        var o = new byte[44 + pcm.Length];
        var s = o.AsSpan();
        "RIFF"u8.CopyTo(s);
        BinaryPrimitives.WriteInt32LittleEndian(s[4..], 36 + pcm.Length);
        "WAVEfmt "u8.CopyTo(s[8..]);
        BinaryPrimitives.WriteInt32LittleEndian(s[16..], 16);
        BinaryPrimitives.WriteInt16LittleEndian(s[20..], 1);
        BinaryPrimitives.WriteInt16LittleEndian(s[22..], (short)channels);
        BinaryPrimitives.WriteInt32LittleEndian(s[24..], rate);
        BinaryPrimitives.WriteInt32LittleEndian(s[28..], rate * channels * bits / 8);
        BinaryPrimitives.WriteInt16LittleEndian(s[32..], (short)(channels * bits / 8));
        BinaryPrimitives.WriteInt16LittleEndian(s[34..], (short)bits);
        "data"u8.CopyTo(s[36..]);
        BinaryPrimitives.WriteInt32LittleEndian(s[40..], pcm.Length);
        pcm.CopyTo(s[44..]);
        return o;
    }
}
