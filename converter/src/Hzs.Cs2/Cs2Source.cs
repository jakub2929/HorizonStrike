using SteamDatabase.ValvePak;
using ValveResourceFormat;
using ValveResourceFormat.IO;

namespace Hzs.Cs2;

/// <summary>
/// Read-only access to the player's CS2 install: game/csgo/pak01_dir.vpk (+ chunks) and game/core/pak01_dir.vpk.
/// ValvePak opens every file with FileAccess.Read; nothing is ever written below the install.
/// </summary>
internal sealed class Cs2Source : IDisposable
{
    private readonly Package _main;
    private readonly Package? _core;

    private Cs2Source(string root, Package main, Package? core)
    {
        Root = root;
        _main = main;
        _core = core;
        // currentFileName = null: no gameinfo.gi walk (it prints to stdout, which is the protocol in serve mode);
        // the core VPK is added explicitly instead.
        Loader = new GameFileLoader(main, null);
        if (core is not null) Loader.AddPackageToSearch(core);
    }

    /// <summary>CS2 install root (the folder that contains game/csgo/pak01_dir.vpk).</summary>
    public string Root { get; }
    public string CsgoDir => Path.Combine(Root, "game", "csgo");
    public GameFileLoader Loader { get; }

    public static Cs2Source Open(string cs2Dir)
    {
        var root = Path.GetFullPath(cs2Dir);
        var mainPath = Path.Combine(root, "game", "csgo", "pak01_dir.vpk");
        if (!File.Exists(mainPath))
            throw new FileNotFoundException($"not a CS2 install (missing game/csgo/pak01_dir.vpk): {root}", mainPath);
        var main = OpenPackage(mainPath);
        var corePath = Path.Combine(root, "game", "core", "pak01_dir.vpk");
        var core = File.Exists(corePath) ? OpenPackage(corePath) : null;
        return new Cs2Source(root, main, core);
    }

    private static Package OpenPackage(string path)
    {
        var p = new Package();
        p.OptimizeEntriesForBinarySearch(StringComparison.OrdinalIgnoreCase);
        p.Read(path);
        return p;
    }

    public bool Exists(string path) => _main.FindEntry(path) is not null || _core?.FindEntry(path) is not null;

    /// <summary>Compiled resource (path including the _c suffix), or null when absent.</summary>
    public Resource? Load(string path) => Loader.LoadFile(path);

    /// <summary>Raw bytes of a VPK entry (e.g. scripts/items/items_game.txt), or null when absent.</summary>
    public byte[]? ReadRaw(string path)
    {
        foreach (var p in new[] { _main, _core })
        {
            var e = p?.FindEntry(path);
            if (e is null) continue;
            p!.ReadEntry(e, out var bytes);
            return bytes;
        }
        return null;
    }

    /// <summary>All entries of the main VPK whose full path starts with the prefix (lower-case, '/' separated).</summary>
    public IEnumerable<string> List(string prefix)
    {
        foreach (var (_, entries) in _main.Entries ?? new())
            foreach (var e in entries)
            {
                var full = e.GetFullPath();
                if (full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) yield return full;
            }
    }

    public void Dispose()
    {
        Loader.Dispose(); // disposes the added core package
        _main.Dispose();
    }
}
