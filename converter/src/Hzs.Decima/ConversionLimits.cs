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
}
