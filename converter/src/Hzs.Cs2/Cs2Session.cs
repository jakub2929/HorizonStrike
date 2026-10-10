using Hzs.Common;

namespace Hzs.Cs2;

/// <summary>
/// The open CS2 install (VPKs, VRF file loader, sound event index, cached arms GLB) shared by every CS2 job of the
/// process. All CS2 asset work runs under one lock: the VRF file loader is not thread-safe, and one model at a time
/// keeps the memory peak down. <see cref="Release"/> closes it (the server calls it when idle).
/// </summary>
internal sealed class Cs2Session
{
    private static readonly object Lock = new();
    private static Cs2Session? _current;

    private Cs2Session(ConvContext ctx)
    {
        Cs2Dir = ctx.Cs2Dir ?? throw new ArgumentException("--cs2 <dir> is required");
        CacheRoot = ctx.Cache.Root;
        Src = Cs2Source.Open(Cs2Dir);
        Sounds = new SoundExport(Src, ctx.Log);
        Assets = new WeaponAssets(ctx, Src, Sounds);
    }

    public string Cs2Dir { get; }
    public string CacheRoot { get; }
    public Cs2Source Src { get; }
    public SoundExport Sounds { get; }
    public WeaponAssets Assets { get; }

    /// <summary>Run work with the session for this install and cache (opened on first use), Console.Out guarded.</summary>
    public static T Run<T>(ConvContext ctx, Func<Cs2Session, T> work)
    {
        lock (Lock)
        {
            using var guard = StdoutGuard.Begin(ctx.Log);
            if (_current is null || _current.Cs2Dir != ctx.Cs2Dir || _current.CacheRoot != ctx.Cache.Root)
            {
                _current?.Src.Dispose();
                _current = null;
                _current = new Cs2Session(ctx);
            }
            return work(_current);
        }
    }

    /// <summary>Close the install and drop the caches (no job may be running).</summary>
    public static void Release()
    {
        lock (Lock)
        {
            _current?.Src.Dispose();
            _current = null;
        }
    }
}
