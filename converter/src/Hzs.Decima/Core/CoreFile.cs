using System.Buffers.Binary;

namespace Hzs.Decima.Core;

/// <summary>One serialized object in a core file: u64 type id, u32 size, then the data (starting with the 16-byte ObjectUUID).</summary>
public sealed record CoreObject(ulong Type, int Offset, int Size, Guid Uuid, int Index)
{
    public string TypeName => Types.NameOf(Type);
}

/// <summary>A decompressed core file: a flat list of objects. Typed readers parse objects on demand.</summary>
public sealed class CoreFile
{
    public string Path { get; }
    public byte[] Data { get; }
    public List<CoreObject> Objects { get; } = [];
    private readonly Dictionary<Guid, CoreObject> _byUuid = new();

    public CoreFile(string path, byte[] data)
    {
        Path = path;
        Data = data;
        var pos = 0;
        while (pos + 12 <= data.Length)
        {
            var type = BinaryPrimitives.ReadUInt64LittleEndian(data.AsSpan(pos));
            var size = BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(pos + 8));
            if (size < 0 || pos + 12 + size > data.Length) throw new InvalidDataException($"{path}: bad object header at {pos}");
            var uuid = size >= 16 ? new Guid(data.AsSpan(pos + 12, 16)) : Guid.Empty;
            var o = new CoreObject(type, pos + 12, size, uuid, Objects.Count);
            Objects.Add(o);
            _byUuid.TryAdd(uuid, o);
            pos += 12 + size;
        }
    }

    public CoreObject? Find(Guid uuid) => _byUuid.GetValueOrDefault(uuid);

    public IEnumerable<CoreObject> OfType(ulong type) => Objects.Where(o => o.Type == type);

    public CoreObject? First(ulong type) => Objects.FirstOrDefault(o => o.Type == type);

    /// <summary>Reader positioned after the ObjectUUID of <paramref name="o"/>, bounded to the object.</summary>
    public BinReader Reader(CoreObject o) => new(Data, o.Offset + 16, o.Offset + o.Size);
}
