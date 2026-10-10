using System.Collections.Concurrent;
using Hzs.Decima.Archive;

namespace Hzs.Decima.Core;

/// <summary>
/// Loads core files on demand (cached) and follows references between objects and files. With a byte limit the cache
/// is an LRU: above <c>maxBytes</c> the least recently used files are dropped down to 3/4 of the limit. A dropped file
/// stays reachable through a weak reference until the GC frees it: a lookup before that revives it instead of reading
/// and decompressing it again (no second copy on the large-object heap). Callers that still hold a dropped file keep
/// using it.
/// </summary>
public sealed class Resolver(HzdArchive arc, long maxBytes = long.MaxValue)
{
    private sealed class Entry(Lazy<CoreFile?> file)
    {
        public readonly Lazy<CoreFile?> File = file;
        public long LastUse;
    }

    private readonly ConcurrentDictionary<string, Entry> _files = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, WeakReference<CoreFile>> _dropped = new(StringComparer.Ordinal);
    private readonly object _evictLock = new();
    private long _bytes, _clock, _loaded;

    /// <summary>Bytes of core files read from the archives so far (re-reads after eviction included).</summary>
    public long LoadedBytes => Interlocked.Read(ref _loaded);

    public HzdArchive Archive => arc;

    /// <summary>Approximate bytes of cached core files.</summary>
    public long CachedBytes => Interlocked.Read(ref _bytes);

    public CoreFile? TryFile(string path)
    {
        var e = _files.GetOrAdd(HzdArchive.Normalize(path), p => new Entry(new Lazy<CoreFile?>(() => Load(p), LazyThreadSafetyMode.ExecutionAndPublication)));
        Volatile.Write(ref e.LastUse, Interlocked.Increment(ref _clock));
        var f = e.File.Value;
        if (CachedBytes > maxBytes) Evict();
        return f;
    }

    private CoreFile? Load(string p)
    {
        if (_dropped.TryRemove(p, out var w) && w.TryGetTarget(out var alive))
        {
            Interlocked.Add(ref _bytes, alive.Data.Length);
            return alive;
        }
        var d = arc.TryRead(p);
        if (d is null) return null;
        Interlocked.Add(ref _bytes, d.Length);
        Interlocked.Add(ref _loaded, d.Length);
        return new CoreFile(p, d);
    }

    private void Evict()
    {
        if (!Monitor.TryEnter(_evictLock)) return; // another thread is evicting
        try
        {
            if (CachedBytes <= maxBytes) return;
            var keep = maxBytes / 4 * 3;
            foreach (var (path, e) in _files.Where(k => k.Value.File.IsValueCreated).OrderBy(k => Volatile.Read(ref k.Value.LastUse)).ToList())
            {
                if (CachedBytes <= keep) break;
                if (_files.TryRemove(new KeyValuePair<string, Entry>(path, e)) && e.File.Value is { } f)
                {
                    Interlocked.Add(ref _bytes, -f.Data.Length);
                    _dropped[path] = new WeakReference<CoreFile>(f);
                }
            }
            // forget weak entries the GC already cleared
            if (_dropped.Count > 4096)
                foreach (var (path, w) in _dropped)
                    if (!w.TryGetTarget(out _)) _dropped.TryRemove(new KeyValuePair<string, WeakReference<CoreFile>>(path, w));
        }
        finally { Monitor.Exit(_evictLock); }
    }

    public CoreFile File(string path) => TryFile(path) ?? throw new FileNotFoundException($"not in the HZD archives: {HzdArchive.Normalize(path)}");

    /// <summary>The object a reference points to (same file for internal refs), decoded; null for null refs.</summary>
    public Obj? Deref(CoreFile from, Ref r)
    {
        if (r.IsNull) return null;
        var file = r.Path is null ? from : File(r.Path);
        var o = file.Find(r.Uuid) ?? throw new InvalidDataException($"{file.Path}: object {r.Uuid} not found");
        return file.Decode(o);
    }

    public Obj? Deref(Obj from, Ref r) => Deref(from.File ?? throw new InvalidOperationException("struct has no file"), r);

    /// <summary>Type name of the referenced object without decoding it (null if unknown or null ref).</summary>
    public CoreObject? Target(CoreFile from, Ref r)
    {
        if (r.IsNull) return null;
        var file = r.Path is null ? from : TryFile(r.Path);
        return file?.Find(r.Uuid);
    }
}
