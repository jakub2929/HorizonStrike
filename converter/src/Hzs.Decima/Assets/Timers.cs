using System.Collections.Concurrent;
using System.Diagnostics;

namespace Hzs.Decima.Assets;

/// <summary>Process-wide CPU time per conversion phase (summed over threads), for the per-cell log line.</summary>
public static class Timers
{
    private static readonly ConcurrentDictionary<string, long> Ticks = new();

    public static T Time<T>(string phase, Func<T> f)
    {
        var t0 = Stopwatch.GetTimestamp();
        try { return f(); }
        finally { Ticks.AddOrUpdate(phase, Stopwatch.GetTimestamp() - t0, (_, v) => v + Stopwatch.GetTimestamp() - t0); }
    }

    /// <summary>Phase -> ms since the given snapshot.</summary>
    public static Dictionary<string, long> Snapshot() => Ticks.ToDictionary(k => k.Key, k => k.Value);

    public static string Since(Dictionary<string, long> before) => string.Join(", ", Ticks
        .Select(k => (k.Key, Ms: (k.Value - before.GetValueOrDefault(k.Key)) * 1000 / Stopwatch.Frequency))
        .Where(k => k.Ms > 0).OrderByDescending(k => k.Ms).Select(k => $"{k.Key} {k.Ms}"));
}
