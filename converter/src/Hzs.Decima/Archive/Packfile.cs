using System.Buffers.Binary;
using Microsoft.Win32.SafeHandles;

namespace Hzs.Decima.Archive;

/// <summary>
/// One Decima archive (<c>Packed_DX12/*.bin</c>), opened read-only. Layout: 40-byte header (magic 0x20304050,
/// key, file size, data size, file count, chunk count, max chunk size), then file entries (32 B: index, key,
/// path hash, offset + size in the decompressed data space, key2) and chunk entries (32 B: decompressed span,
/// compressed span). Chunks are Oodle-compressed blocks of at most 0x40000 bytes. Reads are positional and
/// thread-safe.
/// </summary>
public sealed class Packfile : IDisposable
{
    public const uint MagicPlain = 0x20304050;
    public const uint MagicEncrypted = 0x21304050;

    public readonly record struct FileEntry(ulong Hash, ulong Offset, uint Size);
    public readonly record struct ChunkEntry(ulong DecOffset, uint DecSize, ulong CompOffset, uint CompSize);

    private readonly SafeFileHandle _handle;
    private readonly Oodle _oodle;
    private readonly ChunkEntry[] _chunks; // sorted by DecOffset
    private readonly ChunkCache _cache;

    public string FilePath { get; }
    public string Name { get; }
    public FileEntry[] Files { get; }

    public Packfile(string path, Oodle oodle, ChunkCache cache)
    {
        FilePath = path;
        Name = Path.GetFileNameWithoutExtension(path);
        _oodle = oodle;
        _cache = cache;
        _handle = File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, FileOptions.RandomAccess);
        Span<byte> hdr = stackalloc byte[40];
        RandomAccess.Read(_handle, hdr, 0);
        var magic = BinaryPrimitives.ReadUInt32LittleEndian(hdr);
        if (magic == MagicEncrypted) throw new NotSupportedException($"{Name}: encrypted archives are not supported");
        if (magic != MagicPlain) throw new InvalidDataException($"{Name}: not a Decima archive (magic {magic:X8})");
        var fileSize = BinaryPrimitives.ReadUInt64LittleEndian(hdr[8..]);
        var fileCount = BinaryPrimitives.ReadUInt64LittleEndian(hdr[24..]);
        var chunkCount = BinaryPrimitives.ReadUInt32LittleEndian(hdr[32..]);
        if (fileSize != (ulong)RandomAccess.GetLength(_handle))
            throw new InvalidDataException($"{Name}: header size {fileSize} does not match file size");
        var table = new byte[checked((int)(fileCount * 32 + chunkCount * 32))];
        ReadExactly(table, 40);
        Files = new FileEntry[fileCount];
        for (var i = 0; i < (int)fileCount; i++)
        {
            var e = table.AsSpan(i * 32, 32);
            Files[i] = new FileEntry(BinaryPrimitives.ReadUInt64LittleEndian(e[8..]),
                BinaryPrimitives.ReadUInt64LittleEndian(e[16..]), BinaryPrimitives.ReadUInt32LittleEndian(e[24..]));
        }
        _chunks = new ChunkEntry[chunkCount];
        var cbase = (int)fileCount * 32;
        for (var i = 0; i < chunkCount; i++)
        {
            var e = table.AsSpan(cbase + i * 32, 32);
            _chunks[i] = new ChunkEntry(BinaryPrimitives.ReadUInt64LittleEndian(e), BinaryPrimitives.ReadUInt32LittleEndian(e[8..]),
                BinaryPrimitives.ReadUInt64LittleEndian(e[16..]), BinaryPrimitives.ReadUInt32LittleEndian(e[24..]));
        }
        Array.Sort(_chunks, (a, b) => a.DecOffset.CompareTo(b.DecOffset));
    }

    private void ReadExactly(Span<byte> dst, long offset)
    {
        while (dst.Length > 0)
        {
            var n = RandomAccess.Read(_handle, dst, offset);
            if (n <= 0) throw new EndOfStreamException($"{Name}: unexpected end of file at {offset}");
            dst = dst[n..];
            offset += n;
        }
    }

    /// <summary>Index of the chunk containing decompressed offset <paramref name="off"/>.</summary>
    private int ChunkAt(ulong off)
    {
        int lo = 0, hi = _chunks.Length - 1;
        while (lo < hi)
        {
            var mid = (lo + hi + 1) >> 1;
            if (_chunks[mid].DecOffset <= off) lo = mid; else hi = mid - 1;
        }
        return lo;
    }

    /// <summary>Reads and decompresses one file.</summary>
    public byte[] Read(in FileEntry f)
    {
        var result = new byte[f.Size];
        var pos = f.Offset;
        var end = f.Offset + f.Size;
        var ci = ChunkAt(pos);
        var written = 0;
        while (pos < end)
        {
            var c = _chunks[ci];
            var block = GetChunk(ci, c);
            var inChunk = (int)(pos - c.DecOffset);
            var n = (int)Math.Min((ulong)(block.Length - inChunk), end - pos);
            block.AsSpan(inChunk, n).CopyTo(result.AsSpan(written));
            written += n;
            pos += (ulong)n;
            ci++;
        }
        return result;
    }

    private byte[] GetChunk(int index, in ChunkEntry c)
    {
        if (_cache.TryGet(this, index, out var cached)) return cached;
        var comp = new byte[c.CompSize];
        ReadExactly(comp, (long)c.CompOffset);
        var raw = new byte[c.DecSize];
        _oodle.Decompress(comp, raw);
        _cache.Put(this, index, raw);
        return raw;
    }

    public void Dispose() => _handle.Dispose();
}

/// <summary>Small thread-safe LRU of decompressed chunks (many small resources share a chunk).</summary>
public sealed class ChunkCache(int capacity)
{
    private readonly object _lock = new();
    private readonly Dictionary<(Packfile, int), LinkedListNode<((Packfile, int) Key, byte[] Data)>> _map = new();
    private readonly LinkedList<((Packfile, int) Key, byte[] Data)> _lru = new();

    public bool TryGet(Packfile p, int index, out byte[] data)
    {
        lock (_lock)
        {
            if (_map.TryGetValue((p, index), out var node))
            {
                _lru.Remove(node);
                _lru.AddFirst(node);
                data = node.Value.Data;
                return true;
            }
        }
        data = [];
        return false;
    }

    public void Put(Packfile p, int index, byte[] data)
    {
        lock (_lock)
        {
            if (_map.ContainsKey((p, index))) return;
            _map[(p, index)] = _lru.AddFirst(((p, index), data));
            while (_lru.Count > capacity)
            {
                var last = _lru.Last!;
                _lru.RemoveLast();
                _map.Remove(last.Value.Key);
            }
        }
    }
}
