using System.Runtime;
using System.Runtime.InteropServices;

namespace Hzs.Common;

/// <summary>
/// Shared memory helpers for the converter sides: private bytes, a full collection that also runs finalizers (native
/// buffers such as SkiaSharp bitmaps are only freed by their finalizer) and compacts the large-object heap, and a
/// dev peak sampler (env HZS_MEMPROBE=1).
/// </summary>
public static class ProcessMemory
{
    public static readonly bool ProbeEnabled = Environment.GetEnvironmentVariable("HZS_MEMPROBE") == "1";
    private static long _peak;

    static ProcessMemory()
    {
        if (!ProbeEnabled) return;
        new Thread(() =>
        {
            while (true)
            {
                var p = PrivateBytes();
                long cur;
                while (p > (cur = Interlocked.Read(ref _peak)) && Interlocked.CompareExchange(ref _peak, p, cur) != cur) { }
                Thread.Sleep(50);
            }
        }) { IsBackground = true, Name = "memprobe-common" }.Start();
    }

    /// <summary>Peak private MiB since the last call (HZS_MEMPROBE=1), else -1.</summary>
    public static long TakePeakMb() => ProbeEnabled ? Interlocked.Exchange(ref _peak, PrivateBytes()) >> 20 : -1;

    /// <summary>Private bytes (Windows GetProcessMemoryInfo; elsewhere the GC's committed bytes).</summary>
    public static long PrivateBytes()
    {
        if (OperatingSystem.IsWindows())
        {
            var c = new Counters { Cb = (uint)Marshal.SizeOf<Counters>() };
            if (K32GetProcessMemoryInfo(-1, ref c, c.Cb)) return (long)c.PrivateUsage;
        }
        return GC.GetGCMemoryInfo().TotalCommittedBytes;
    }

    /// <summary>
    /// Collect everything unreachable now: finalizers run (native memory of disposable-less objects), then an aggressive
    /// compacting collection gives the freed regions back to the OS. Call between independent items, not in a loop.
    /// </summary>
    /// <summary>Total milliseconds spent in <see cref="CollectNow"/> (diagnostics).</summary>
    public static long CollectMs => Interlocked.Read(ref _collectMs);
    private static long _collectMs;

    public static void CollectNow(bool light = false)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        try { Collect(light); }
        finally { Interlocked.Add(ref _collectMs, sw.ElapsedMilliseconds); }
    }

    private static void Collect(bool light)
    {
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true);
        GC.WaitForPendingFinalizers();
        if (light) return; // finalizers ran (native buffers freed); no compaction / decommit
        GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, blocking: true, compacting: true);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Counters
    {
        public uint Cb, PageFaultCount;
        public nuint PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage,
            QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage, PrivateUsage;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool K32GetProcessMemoryInfo(nint process, ref Counters counters, uint cb);
}
