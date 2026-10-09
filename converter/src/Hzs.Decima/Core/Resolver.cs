using System.Collections.Concurrent;
using Hzs.Decima.Archive;

namespace Hzs.Decima.Core;

/// <summary>Loads core files on demand (cached) and follows references between objects and files.</summary>
public sealed class Resolver(HzdArchive arc)
{
    private readonly ConcurrentDictionary<string, CoreFile?> _files = new(StringComparer.Ordinal);

    public HzdArchive Archive => arc;

    public CoreFile? TryFile(string path) =>
        _files.GetOrAdd(HzdArchive.Normalize(path), p => arc.TryRead(p) is { } d ? new CoreFile(p, d) : null);

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
