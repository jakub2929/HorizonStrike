using System.Runtime;
using System.Runtime.InteropServices;

namespace Hzs.Decima;

/// <summary>
/// Gives memory back while the converter has nothing to do: drops the archive set, the shared mesh exporter (resolver
/// caches, decoded images), compacts the managed heap including the large-object heap (aggressive mode decommits free
/// segments) and trims the working set. Only call it when no conversion runs.
/// </summary>
public static class Memory
{
    public static void ReleaseCaches()
    {
        World.CellConverter.ReleaseShared();
        Archive.HzdArchive.CloseAll();
        GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, blocking: true, compacting: true);
        GC.WaitForPendingFinalizers();
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, blocking: true, compacting: true);
        if (OperatingSystem.IsWindows())
        {
            try { SetProcessWorkingSetSize(System.Diagnostics.Process.GetCurrentProcess().Handle, -1, -1); }
            catch (Exception) { }
        }
    }

    /// <summary>
    /// Private bytes of this process. Windows: GetProcessMemoryInfo (microseconds; Process.PrivateMemorySize64 snapshots
    /// every process and thread of the system on each call). Elsewhere: the GC's committed bytes.
    /// </summary>
    public static long PrivateBytes()
    {
        if (OperatingSystem.IsWindows())
        {
            var c = new ProcessMemoryCounters { Cb = (uint)Marshal.SizeOf<ProcessMemoryCounters>() };
            if (K32GetProcessMemoryInfo(-1, ref c, c.Cb)) return (long)c.PrivateUsage;
        }
        return GC.GetGCMemoryInfo().TotalCommittedBytes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessMemoryCounters
    {
        public uint Cb, PageFaultCount;
        public nuint PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage,
            QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage, PrivateUsage;
    }

    // PROCESS_MEMORY_COUNTERS_EX; process -1 = the current-process pseudo handle
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool K32GetProcessMemoryInfo(nint process, ref ProcessMemoryCounters counters, uint cb);

    private static void Compact()
    {
        GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
        // aggressive: compacts and gives the freed regions back to the OS at once (private bytes drop, not only the heap)
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, blocking: true, compacting: true);
    }

    /// <summary>
    /// After a conversion job (or bootstrap stage): when private memory is above half of
    /// <see cref="ConversionLimits.SoftCapBytes"/>, the job's garbage is freed now instead of at the next gen-2 budget.
    /// Returns private MiB before and after (equal when nothing ran).
    /// </summary>
    public static (long BeforeMb, long AfterMb) AfterJob()
    {
        var before = PrivateBytes();
        if (before <= ConversionLimits.SoftCapBytes / 2) return (before >> 20, before >> 20);
        Compact();
        return (before >> 20, PrivateBytes() >> 20);
    }

    private static int _governor;

    /// <summary>
    /// Soft cap while jobs run: a background thread compacts the heap when private memory goes above
    /// <see cref="ConversionLimits.SoftCapBytes"/> (at most every 2 s, so a live set above the cap costs little time).
    /// Garbage of evicted core files and decoded textures sits on the large-object heap, which the GC otherwise collects
    /// only with gen 2, long after the cap. Started once; <paramref name="log"/> gets one line per collection.
    /// </summary>
    public static void StartGovernor(Action<string> log)
    {
        if (Interlocked.Exchange(ref _governor, 1) == 1) return;
        new Thread(() =>
        {
            var last = 0L;
            while (true)
            {
                Thread.Sleep(100);
                if (Environment.TickCount64 - last < 2000) continue;
                var before = PrivateBytes();
                if (before <= ConversionLimits.SoftCapBytes) continue;
                var sw = System.Diagnostics.Stopwatch.StartNew();
                Compact();
                last = Environment.TickCount64;
                log($"soft cap: private {before >> 20} -> {PrivateBytes() >> 20} MB ({sw.ElapsedMilliseconds} ms)");
            }
        }) { IsBackground = true, Name = "memory-governor", Priority = ThreadPriority.BelowNormal }.Start();
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessWorkingSetSize(IntPtr process, nint min, nint max);
}
