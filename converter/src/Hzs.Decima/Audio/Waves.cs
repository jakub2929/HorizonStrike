using System.Buffers.Binary;
using Hzs.Decima.Archive;
using Hzs.Decima.Core;

using Hzs.Decima.Sheets;

namespace Hzs.Decima.Audio;

/// <summary>
/// WaveResource -> playable file. Layout facts: members EncodingQuality, IsStreaming, UseVBR come before the ObjectUUID;
/// WaveData is inline unless IsStreaming (then the binary part is a data source into a .stream, holding a RIFF file).
/// EWaveDataEncoding: 0 PCM, 1 PCM_FLOAT, 2 XWMA, 3 ATRAC9, 4 MP3, 5 ADPCM, 6 AAC. On PC the small effects are MP3
/// (inline frames) or 16-bit PCM; the weather/ambience beds are 6-channel ATRAC9 (no decoder: skipped).
/// </summary>
public static class Waves
{
    public sealed record Exported(string Ext, byte[] Data, double Seconds);

    public static Exported? Export(HzdArchive arc, Obj wave)
    {
        var enc = wave.Int("Encoding");
        byte[] data;
        if (wave.Bool("IsStreaming"))
        {
            var r = wave.ExtraReader();
            var loc = System.Text.Encoding.UTF8.GetString(r.Span(r.I32()));
            loc = HzdNames.StripStream(loc);
            var off = (long)r.U64();
            var len = (long)r.U64();
            data = arc.ReadRange(loc, off, len);
            if (enc == 0 && data.AsSpan(0, 4).SequenceEqual("RIFF"u8)) return new Exported("wav", data, Seconds(wave));
        }
        else data = wave.Prims<byte>("WaveData");
        if (data.Length == 0) return null;
        return enc switch
        {
            4 => new Exported("mp3", data, Seconds(wave)),
            0 => new Exported("wav", Riff(data, wave.Int("SampleRate"), wave.Int("ChannelCount"), wave.Int("BitsPerSample")), Seconds(wave)),
            _ => null,
        };
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
