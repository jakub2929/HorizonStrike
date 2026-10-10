namespace Hzs.Decima;

/// <summary>
/// CPU budget of one conversion job: every parallel loop of the HZD converter (mesh export, BC encoding) uses at most
/// <see cref="Threads"/> threads. The server lowers it while the player is in the world (protocol op "throttle") so the
/// game keeps its frame time; default: half the logical processors, at least 1.
/// </summary>
public static class ConversionLimits
{
    private static volatile int _threads = Math.Max(1, Environment.ProcessorCount / 2);

    public static int Threads
    {
        get => _threads;
        set => _threads = Math.Clamp(value, 1, Environment.ProcessorCount);
    }

    public static ParallelOptions Options(CancellationToken ct = default) => new() { MaxDegreeOfParallelism = Threads, CancellationToken = ct };

    /// <summary>Byte limit of the shared core-file cache (sheet systems perf.converter_resolver_mb).</summary>
    public static readonly long ResolverBytes = Mb(Hzs.Generated.SystemsSheet.PerfConverterResolverMb);

    /// <summary>Byte limit of cached decoded material images (sheet systems perf.converter_image_cache_mb).</summary>
    public static readonly long ImageCacheBytes = Mb(Hzs.Generated.SystemsSheet.PerfConverterImageCacheMb);

    private static readonly long PlayCap = Mb(Hzs.Generated.SystemsSheet.PerfConverterSoftCapMb);
    private static readonly long BootstrapCap = Mb(Hzs.Generated.SystemsSheet.PerfConverterSoftCapBootstrapMb);
    private static int _bootstraps;

    /// <summary>
    /// Soft cap on the process' private memory (see <see cref="Memory"/>): sheet systems perf.converter_soft_cap_mb,
    /// perf.converter_soft_cap_bootstrap_mb while a bootstrap runs (<see cref="BeginBootstrap"/>).
    /// </summary>
    public static long SoftCapBytes => Volatile.Read(ref _bootstraps) > 0 ? BootstrapCap : PlayCap;

    /// <summary>A bootstrap starts (the loading screen waits for it); dispose when it ends.</summary>
    public static IDisposable BeginBootstrap()
    {
        Interlocked.Increment(ref _bootstraps);
        return new End();
    }

    private sealed class End : IDisposable
    {
        private int _done;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) == 0) Interlocked.Decrement(ref _bootstraps);
        }
    }

    private static long Mb(Hzs.Generated.SystemsRow r) => long.Parse(r.Value, System.Globalization.CultureInfo.InvariantCulture) << 20;
}
