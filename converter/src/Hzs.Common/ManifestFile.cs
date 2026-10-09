using System.Text.Json.Nodes;

namespace Hzs.Common;

/// <summary>
/// cache/manifest.json ({"format":1,"converter":..,"cs2_build":..,"hzd_build":..}) is shared by the CS2 and HZD
/// sides: read-modify-write under one process-wide lock, written atomically, unknown fields preserved.
/// </summary>
public static class ManifestFile
{
    private static readonly object Lock = new();

    public static JsonObject Read(CachePaths cache)
    {
        lock (Lock) return ReadUnlocked(cache);
    }

    public static void Update(CachePaths cache, Action<JsonObject> change)
    {
        lock (Lock)
        {
            var m = ReadUnlocked(cache);
            m["format"] ??= 1;
            change(m);
            Atomic.WriteJson(cache.Manifest, m);
        }
    }

    private static JsonObject ReadUnlocked(CachePaths cache)
    {
        try
        {
            return File.Exists(cache.Manifest) ? JsonNode.Parse(File.ReadAllText(cache.Manifest)) as JsonObject ?? new JsonObject() : new JsonObject();
        }
        catch (Exception)
        {
            return new JsonObject(); // a broken manifest only forces a re-conversion
        }
    }
}
