using System.Buffers.Binary;
using System.Text;
using Hzs.Decima.Archive;
using Hzs.Decima.Core;

namespace Hzs.Decima.Audio;

/// <summary>
/// HZD music (sounds/music/world/world.core, MusicResource). Binary part: u32 length + "Echo" bank, then one data
/// source per StreamingBankNames entry (InitialChunk, AdditionalChunk, DLC1Chunk -> world_*chunk.stream).
/// Echo bank: "ECHO", -1, u32 table size, entries (magic, offset, length); MEDA chunk = "PICD", u32 count, 8 bytes,
/// count x 48-byte media entries (u64 offset, u64 size, ...); STRL chunk = NUL separated names, the *.mp3 names in
/// media order. A track's stream bank advances when its offset is lower than the previous one. Tracks are MP3.
/// </summary>
public sealed class Music
{
    public sealed record Track(string Name, int Bank, long Offset, long Size);

    public List<Track> Tracks { get; } = [];
    private readonly List<(string Path, long Offset)> _banks = [];
    private readonly HzdArchive _arc;

    public const string WorldMusic = "sounds/music/world/world";

    public Music(Resolver res, string path = WorldMusic)
    {
        _arc = res.Archive;
        var music = res.File(path).FirstObj("MusicResource") ?? throw new InvalidDataException("no MusicResource");
        var r = music.ExtraReader();
        var len = r.I32();
        var bank = r.Bytes(len);
        foreach (var _ in music.Arr("StreamingBankNames"))
        {
            var loc = Encoding.UTF8.GetString(r.Span(r.I32()));
            if (loc.StartsWith("cache:", StringComparison.Ordinal)) loc = loc[6..];
            var off = (long)r.U64();
            r.U64();
            _banks.Add((loc, off));
        }
        var b = bank.AsSpan();
        if (!b[..4].SequenceEqual("ECHO"u8)) throw new InvalidDataException("not an echo bank");
        var table = BinaryPrimitives.ReadInt32LittleEndian(b[8..]);
        (int Off, int Len) meda = default, strl = default;
        for (var i = 0; i < table / 12; i++)
        {
            var e = b.Slice(12 + i * 12, 12);
            var chunk = (BinaryPrimitives.ReadInt32LittleEndian(e[4..]), BinaryPrimitives.ReadInt32LittleEndian(e[8..]));
            if (e[..4].SequenceEqual("MEDA"u8)) meda = chunk;
            else if (e[..4].SequenceEqual("STRL"u8)) strl = chunk;
        }
        var count = BinaryPrimitives.ReadInt32LittleEndian(b[(meda.Off + 4)..]);
        var names = Encoding.UTF8.GetString(b.Slice(strl.Off, strl.Len)).Split('\0', StringSplitOptions.RemoveEmptyEntries)
            .Where(n => n.EndsWith(".mp3", StringComparison.OrdinalIgnoreCase)).ToList();
        long last = 0;
        var bankIndex = 0;
        for (var i = 0; i < Math.Min(count, names.Count); i++)
        {
            var e = b.Slice(meda.Off + 16 + i * 48, 48);
            var off = BinaryPrimitives.ReadInt64LittleEndian(e);
            var size = BinaryPrimitives.ReadInt64LittleEndian(e[8..]);
            if (off < last) bankIndex++;
            last = off;
            Tracks.Add(new Track(names[i][..^4], bankIndex, off, size));
        }
    }

    public byte[] Data(Track t) => _arc.ReadRange(_banks[t.Bank].Path, _banks[t.Bank].Offset + t.Offset, t.Size);

    /// <summary>Concatenated MP3 frames of the given tracks (same encoder settings, plays as one file).</summary>
    public byte[] Join(IEnumerable<Track> tracks)
    {
        using var ms = new MemoryStream();
        foreach (var t in tracks) ms.Write(Data(t));
        return ms.ToArray();
    }
}
