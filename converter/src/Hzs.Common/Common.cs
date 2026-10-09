using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hzs.Common;

/// <summary>Cache layout from docs/ARCHITECTURE.md. All converter output goes below Root.</summary>
public sealed class CachePaths
{
    public CachePaths(string root) => Root = Path.GetFullPath(root);
    public string Root { get; }
    public string Manifest => Path.Combine(Root, "manifest.json");
    public string Cs2 => Path.Combine(Root, "cs2");
    public string Cs2WeaponsJson => Path.Combine(Cs2, "weapons.json");
    public string Cs2Weapon(string id) => Path.Combine(Cs2, "weapons", id);
    public string Hzd => Path.Combine(Root, "hzd");
    public string HzdIndex => Path.Combine(Hzd, "index.json");
    public string Machine(string id) => Path.Combine(Hzd, "machines", id);
    public string Meshes => Path.Combine(Hzd, "meshes");
    public string Cell(int x, int y) => Path.Combine(Hzd, "cells", $"{x}_{y}");
    public string LogDir => Path.Combine(Path.GetDirectoryName(Root) ?? Root, "logs");
}

/// <summary>Build a folder or file next to its target, then move it into place (readers never see half a result).</summary>
public static class Atomic
{
    public static string BeginDir(string target)
    {
        var tmp = target + ".tmp";
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        Directory.CreateDirectory(tmp);
        return tmp;
    }

    public static void CommitDir(string tmp, string target)
    {
        if (Directory.Exists(target)) Directory.Delete(target, true);
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        Directory.Move(tmp, target);
    }

    public static void WriteFile(string target, byte[] data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        var tmp = target + ".tmp";
        File.WriteAllBytes(tmp, data);
        File.Move(tmp, target, true);
    }

    public static void WriteJson(string target, JsonNode node) =>
        WriteFile(target, JsonSerializer.SerializeToUtf8Bytes(node, new JsonSerializerOptions { WriteIndented = true }));
}

/// <summary>Opens game files strictly read-only (games are never written to).</summary>
public static class GameFiles
{
    public static FileStream OpenRead(string path) =>
        new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16, FileOptions.RandomAccess);
}

/// <summary>Converter log: logs/converter.log plus "log" events when serving.</summary>
public sealed class Log : IDisposable
{
    private readonly StreamWriter? _file;
    private readonly object _lock = new();
    public Protocol? Events { get; set; }

    public Log(string? dir)
    {
        if (dir is null) return;
        Directory.CreateDirectory(dir);
        // A second converter (e.g. an autotest child process) must not fail on a log held by the first one.
        FileStream fs;
        try { fs = new FileStream(Path.Combine(dir, "converter.log"), FileMode.Create, FileAccess.Write, FileShare.Read); }
        catch (IOException) { fs = new FileStream(Path.Combine(dir, $"converter-{Environment.ProcessId}.log"), FileMode.Create, FileAccess.Write, FileShare.ReadWrite); }
        _file = new StreamWriter(fs) { AutoFlush = true };
    }

    public void Info(string msg) => Write("info", msg);
    public void Warn(string msg) => Write("warn", msg);
    public void Error(string msg) => Write("error", msg);

    private void Write(string level, string msg)
    {
        lock (_lock)
        {
            var line = $"{DateTime.Now:HH:mm:ss.fff} [{level}] {msg}";
            _file?.WriteLine(line);
            if (Events is null) Console.Error.WriteLine(line);
        }
        Events?.Emit(new JsonObject { ["event"] = "log", ["level"] = level, ["message"] = msg });
    }

    public void Dispose() => _file?.Dispose();
}

/// <summary>JSON-lines protocol over stdout (server mode).</summary>
public sealed class Protocol
{
    private readonly TextWriter _out;
    private readonly object _lock = new();
    public Protocol(TextWriter output) => _out = output;

    public void Emit(JsonObject evt)
    {
        var line = evt.ToJsonString();
        lock (_lock) { _out.WriteLine(line); _out.Flush(); }
    }

    public void Progress(long id, string stage, int done, int total) =>
        Emit(new JsonObject { ["id"] = id, ["event"] = "progress", ["stage"] = stage, ["done"] = done, ["total"] = total });

    public void Done(long id, long bytes, JsonObject? extra = null)
    {
        var o = new JsonObject { ["id"] = id, ["event"] = "done", ["ok"] = true, ["bytes"] = bytes };
        if (extra is not null) foreach (var kv in extra) o[kv.Key] = kv.Value?.DeepClone();
        Emit(o);
    }

    public void Error(long id, string message) =>
        Emit(new JsonObject { ["id"] = id, ["event"] = "error", ["message"] = message });
}

public interface IProgressSink
{
    void Report(string stage, int done, int total);
}

public sealed record ConvContext(string? Cs2Dir, string? HzdDir, CachePaths Cache, Log Log, CancellationToken Ct);

public static class Sizes
{
    public static long DirBytes(string dir) =>
        Directory.Exists(dir) ? new DirectoryInfo(dir).EnumerateFiles("*", SearchOption.AllDirectories).Sum(f => f.Length) : 0;
}
