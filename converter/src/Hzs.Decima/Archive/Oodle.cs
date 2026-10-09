using System.Runtime.InteropServices;

using Hzs.Decima.Sheets;

namespace Hzs.Decima.Archive;

/// <summary>
/// Oodle decompressor from the player's own HZD install. The DLL is loaded in place
/// (<c>&lt;hzd&gt;/oo2core_3_win64.dll</c>) and never copied anywhere.
/// </summary>
public sealed unsafe class Oodle
{
    private static readonly object Gate = new();
    private static Oodle? _instance;
    private static string? _loadedFrom;

    private readonly delegate* unmanaged<byte*, long, byte*, long, int, int, int, void*, long, void*, void*, void*, long, int, long> _decompress;

    private Oodle(IntPtr lib)
    {
        _decompress = (delegate* unmanaged<byte*, long, byte*, long, int, int, int, void*, long, void*, void*, void*, long, int, long>)
            NativeLibrary.GetExport(lib, "OodleLZ_Decompress");
    }

    /// <summary>Loads oo2core_3_win64.dll from the HZD folder (once per process).</summary>
    public static Oodle Load(string hzdDir)
    {
        lock (Gate)
        {
            if (_instance is not null) return _instance;
            var dll = Path.Combine(hzdDir, HzdNames.Str("archive.oodle_dll"));
            if (!File.Exists(dll)) throw new FileNotFoundException("Oodle library not found in the HZD install", dll);
            _instance = new Oodle(NativeLibrary.Load(dll));
            _loadedFrom = dll;
            return _instance;
        }
    }

    public static string? LoadedFrom => _loadedFrom;

    /// <summary>Decompresses one block; <paramref name="dst"/> length must be the exact raw size.</summary>
    public void Decompress(ReadOnlySpan<byte> src, Span<byte> dst)
    {
        long n;
        fixed (byte* s = src)
        fixed (byte* d = dst)
            n = _decompress(s, src.Length, d, dst.Length, 1, 0, 0, null, 0, null, null, null, 0, 3);
        if (n != dst.Length) throw new InvalidDataException($"Oodle decompression failed ({n} of {dst.Length} bytes)");
    }
}
