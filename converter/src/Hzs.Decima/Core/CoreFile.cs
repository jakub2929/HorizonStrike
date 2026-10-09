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
            var lead = Layouts.LeadSize(type); // members serialized before the ObjectUUID (e.g. WorldNode.Orientation)
            var uuid = size >= lead + 16 ? new Guid(data.AsSpan(pos + 12 + lead, 16)) : Guid.Empty;
            var o = new CoreObject(type, pos + 12, size, uuid, Objects.Count);
            Objects.Add(o);
            _byUuid.TryAdd(uuid, o);
            pos += 12 + size;
        }
    }

    public CoreObject? Find(Guid uuid) => _byUuid.GetValueOrDefault(uuid);

    public IEnumerable<CoreObject> OfType(ulong type) => Objects.Where(o => o.Type == type);

    public CoreObject? First(ulong type) => Objects.FirstOrDefault(o => o.Type == type);

    public IEnumerable<CoreObject> OfType(string type) => OfType(Types.Id(type));

    /// <summary>Decodes an object with its hand-written layout.</summary>
    public Obj Decode(CoreObject o) => Layouts.Decode(this, o);

    /// <summary>Decodes all objects of a type.</summary>
    public IEnumerable<Obj> All(string type) => OfType(type).Select(Decode);

    /// <summary>Decodes the first object of a type, or null.</summary>
    public Obj? FirstObj(string type) => First(Types.Id(type)) is { } o ? Decode(o) : null;
}
