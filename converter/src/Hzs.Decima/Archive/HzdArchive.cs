using Hzs.Decima.Core;

namespace Hzs.Decima.Archive;

/// <summary>
/// The player's HZD archive set (read-only): <c>Packed_DX12/{DLC1,FGRWin32,Initial,Remainder,Patch}.bin</c>; Patch
/// overrides the others. Lookup by path hash. Thread-safe. The path list comes from the game's own prefetch list
/// (<c>prefetch/fullgame.prefetch.core</c>); nothing path-related is shipped.
/// </summary>
public sealed class HzdArchive : IDisposable
{
    public static readonly string[] ArchiveNames = ["DLC1", "FGRWin32", "Initial", "Remainder", "Patch"];
    public const string PrefetchPath = "prefetch/fullgame.prefetch";

    private readonly List<Packfile> _packs = [];
    private readonly Dictionary<ulong, (Packfile Pack, Packfile.FileEntry Entry)> _files = new();
    private readonly Lazy<string[]> _paths;
    private readonly ChunkCache _cache = new(160);

    public string HzdDir { get; }
    public IReadOnlyList<Packfile> Packs => _packs;
    public int FileCount => _files.Count;

    private HzdArchive(string hzdDir)
    {
        HzdDir = hzdDir;
        var oodle = Oodle.Load(hzdDir);
        var packed = Path.Combine(hzdDir, "Packed_DX12");
        foreach (var name in ArchiveNames)
        {
            var file = Path.Combine(packed, name + ".bin");
            if (!File.Exists(file))
            {
                if (name is "Initial" or "Remainder") throw new FileNotFoundException("HZD archive missing", file);
                continue;
            }
            var p = new Packfile(file, oodle, _cache);
            _packs.Add(p);
            foreach (var e in p.Files) _files[e.Hash] = (p, e); // later archives (Patch) override
        }
        _paths = new Lazy<string[]>(LoadPrefetchPaths, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    private static readonly object OpenLock = new();
    private static readonly Dictionary<string, HzdArchive> Opened = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Opens (once per process) the archive set of an HZD install.</summary>
    public static HzdArchive Open(string hzdDir)
    {
        var full = Path.GetFullPath(hzdDir);
        lock (OpenLock)
        {
            if (!Opened.TryGetValue(full, out var a)) Opened[full] = a = new HzdArchive(full);
            return a;
        }
    }

    /// <summary>Normalized archive path: forward slashes, no leading slash, ".core" unless it ends in .core/.stream.</summary>
    public static string Normalize(string path)
    {
        path = path.Replace('\\', '/').TrimStart('/');
        if (!path.EndsWith(".core", StringComparison.Ordinal) && !path.EndsWith(".stream", StringComparison.Ordinal)) path += ".core";
        return path;
    }

    public bool Exists(string path) => _files.ContainsKey(Murmur3.PathHash(Normalize(path)));

    public int SizeOf(string path) => _files.TryGetValue(Murmur3.PathHash(Normalize(path)), out var f) ? (int)f.Entry.Size : -1;

    public string? ArchiveOf(string path) => _files.TryGetValue(Murmur3.PathHash(Normalize(path)), out var f) ? f.Pack.Name : null;

    public byte[]? TryRead(string path) =>
        _files.TryGetValue(Murmur3.PathHash(Normalize(path)), out var f) ? f.Pack.Read(f.Entry) : null;

    public byte[] Read(string path) => TryRead(path) ?? throw new FileNotFoundException($"not in the HZD archives: {Normalize(path)}");

    public CoreFile ReadCore(string path) => new(Normalize(path), Read(path));

    public CoreFile? TryReadCore(string path) => TryRead(path) is { } d ? new CoreFile(Normalize(path), d) : null;

    /// <summary>All resource paths named by the game's prefetch list (without extension), sorted.</summary>
    public IReadOnlyList<string> Paths => _paths.Value;

    private string[] LoadPrefetchPaths()
    {
        var core = ReadCore(PrefetchPath);
        var obj = core.First(Types.PrefetchList) ?? throw new InvalidDataException("prefetch list object not found");
        var r = core.Reader(obj);
        var files = r.Array(x => x.Str()); // Array<AssetPath>, AssetPath = { String Path }
        var set = new HashSet<string>(files.Length, StringComparer.Ordinal);
        foreach (var f in files)
        {
            var p = f.Replace('\\', '/').TrimStart('/');
            if (p.EndsWith(".core", StringComparison.Ordinal)) p = p[..^5];
            set.Add(p);
        }
        var list = set.ToArray();
        Array.Sort(list, StringComparer.Ordinal);
        return list;
    }

    public void Dispose()
    {
        foreach (var p in _packs) p.Dispose();
    }
}
