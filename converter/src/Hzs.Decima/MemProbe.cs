using System.Collections.Concurrent;

namespace Hzs.Decima;

/// <summary>
/// DEV diagnostics (env HZS_MEMPROBE=1): samples private bytes and the managed heap every 50 ms and keeps the peak per
/// phase label (<see cref="Phase"/>; meaningful with one worker). <see cref="Report"/> returns and resets the peaks.
/// Disabled: every call is a no-op.
/// </summary>
public static class MemProbe
{
    public static readonly bool Enabled = Environment.GetEnvironmentVariable("HZS_MEMPROBE") == "1";
    private static volatile string _phase = "-";
    private static readonly ConcurrentDictionary<string, (long Priv, long Heap)> Peaks = new();

    static MemProbe()
    {
        if (!Enabled) return;
        var t = new Thread(() =>
        {
            while (true)
            {
                var priv = Memory.PrivateBytes();
                var heap = GC.GetTotalMemory(false);
                Peaks.AddOrUpdate(_phase, (priv, heap), (_, o) => (Math.Max(o.Priv, priv), Math.Max(o.Heap, heap)));
                Thread.Sleep(50);
            }
        }) { IsBackground = true, Name = "memprobe" };
        t.Start();
    }

    public static void Phase(string name)
    {
        if (Enabled) _phase = name;
    }

    public static string Report()
    {
        if (!Enabled) return "";
        var s = string.Join(", ", Peaks.OrderBy(k => k.Key).Select(k => $"{k.Key} {k.Value.Priv >> 20}/{k.Value.Heap >> 20}"));
        Peaks.Clear();
        var gi = GC.GetGCMemoryInfo();
        return $"; mem peak private/heap MB: {s}; now heap {gi.HeapSizeBytes >> 20} frag {gi.FragmentedBytes >> 20} loh {gi.GenerationInfo[3].SizeAfterBytes >> 20} committed {gi.TotalCommittedBytes >> 20}";
    }
}
