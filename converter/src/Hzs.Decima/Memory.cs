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

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessWorkingSetSize(IntPtr process, nint min, nint max);
}
