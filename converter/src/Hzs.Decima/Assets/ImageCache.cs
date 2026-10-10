namespace Hzs.Decima.Assets;

/// <summary>
/// Decoded images by key, least recently used dropped above a byte limit. Thread-safe; a missing image is computed
/// outside the lock (two threads may decode the same key once each; the first result is kept). Null results are not kept.
/// </summary>
public sealed class ImageCache(long maxBytes)
{
    private readonly object _lock = new();
    private readonly Dictionary<string, LinkedListNode<(string Key, Image Img)>> _map = new(StringComparer.Ordinal);
    private readonly LinkedList<(string Key, Image Img)> _lru = new();
    private long _bytes;

    public long Bytes { get { lock (_lock) return _bytes; } }

    public Image? GetOrAdd(string key, Func<Image?> make)
    {
        lock (_lock)
        {
            if (_map.TryGetValue(key, out var hit))
            {
                _lru.Remove(hit);
                _lru.AddFirst(hit);
                return hit.Value.Img;
            }
        }
        var img = make();
        if (img is null) return null;
        lock (_lock)
        {
            if (_map.TryGetValue(key, out var raced)) return raced.Value.Img;
            _map[key] = _lru.AddFirst((key, img));
            _bytes += img.Pixels.Length;
            while (_bytes > maxBytes && _lru.Last is { } old && old != _lru.First)
            {
                _lru.RemoveLast();
                _map.Remove(old.Value.Key);
                _bytes -= old.Value.Img.Pixels.Length;
            }
        }
        return img;
    }
}
