namespace Hzs.Decima.Core;

/// <summary>
/// Registry of the hand-written layouts (see <see cref="Layout"/>) and the generic decoder. Layouts are grouped
/// by area in partial files (Layouts.*.cs); each group registers itself from the static constructor.
/// </summary>
public static partial class Layouts
{
    private static readonly Dictionary<ulong, Layout> ById = new();
    private static readonly Dictionary<string, Layout> ByName = new(StringComparer.Ordinal);

    static Layouts()
    {
        RegisterBasic();
        RegisterGame();
        RegisterAssets();
        RegisterWorld();
    }

    /// <summary>Structs with handler-defined (MsgReadBinary) payloads embedded inside other objects.</summary>
    private static readonly Dictionary<string, Func<BinReader, object?>> Custom = new(StringComparer.Ordinal)
    {
        // Pose: Ref Skeleton, then u8 present; if present: u32 n, n x Mat34 (per joint local rotation quat xyzw,
        // translation xyz_, scale xyz_), n x Mat44 (model-space matrices), u32 m, m x u32.
        ["Pose"] = r =>
        {
            var o = new Obj("Pose");
            o.Fields["Skeleton"] = r.Ref();
            if (r.U8() != 0)
            {
                var n = r.Count();
                var local = new float[n * 12];
                for (var i = 0; i < local.Length; i++) local[i] = r.F32();
                var model = new float[n * 16];
                for (var i = 0; i < model.Length; i++) model[i] = r.F32();
                var m = r.Count();
                r.Skip(m * 4);
                o.Fields["Local"] = local;
                o.Fields["Model"] = model;
            }
            return o;
        },
    };

    private static void L(ulong id, string name, string members, string? lead = null, bool binary = false, bool partial = false)
    {
        var l = new Layout(id, name, members, lead, binary, partial);
        ByName[name] = l;
        if (id != 0) ById[id] = l;
    }

    public static Layout? Get(ulong typeId) => ById.GetValueOrDefault(typeId);
    public static Layout? Get(string name) => ByName.GetValueOrDefault(name);
    public static string? NameOf(ulong typeId) => ById.TryGetValue(typeId, out var l) ? l.Name : null;
    public static ulong IdOf(string name) => ByName.TryGetValue(name, out var l) && l.Id != 0 ? l.Id : throw new KeyNotFoundException($"no layout for {name}");

    /// <summary>Fixed serialized size of a type, or null if variable (strings, arrays, refs).</summary>
    public static int? FixedSize(TypeSpec t) => t.Kind switch
    {
        "bool" or "int8" or "uint8" or "e1" or "tchar" => 1,
        "int16" or "uint16" or "HalfFloat" or "e2" or "wchar" => 2,
        "int" or "int32" or "uint" or "uint32" or "float" or "e4" or "ucs4" => 4,
        "int64" or "uint64" or "double" or "e8" => 8,
        "GGUUID" or "uint128" => 16,
        "Struct" => Get(t.Struct!) is { IsRefObject: false } l ? SumFixed(l.Members) : null,
        _ => null,
    };

    private static int? SumFixed(IEnumerable<Member> members)
    {
        var total = 0;
        foreach (var m in members)
        {
            if (FixedSize(m.Type) is not { } s) return null;
            total += s;
        }
        return total;
    }

    /// <summary>Bytes serialized before the ObjectUUID of objects of this type (0 if unknown).</summary>
    public static int LeadSize(ulong typeId) => Get(typeId) is { Lead.Length: > 0 } l ? SumFixed(l.Lead) ?? 0 : 0;

    /// <summary>Decodes one object of a core file with its layout.</summary>
    public static Obj Decode(CoreFile file, CoreObject o)
    {
        var l = Get(o.Type) ?? throw new NotSupportedException($"{file.Path}: no layout for type {o.TypeName}");
        var r = new BinReader(file.Data, o.Offset, o.Offset + o.Size);
        var obj = new Obj(l.Name) { File = file, Source = o, Uuid = o.Uuid };
        foreach (var m in l.Lead) obj.Fields[m.Name] = ReadValue(m.Type, r);
        r.Skip(16); // ObjectUUID
        foreach (var m in l.Members) obj.Fields[m.Name] = ReadValue(m.Type, r);
        if (l.Binary)
        {
            obj.ExtraOffset = r.Position;
            obj.ExtraEnd = r.End;
        }
        else if (!l.Partial && r.Remaining != 0)
            throw new InvalidDataException($"{file.Path}: layout {l.Name} left {r.Remaining} of {o.Size} bytes unread");
        return obj;
    }

    public static Obj ReadStruct(Layout l, BinReader r)
    {
        var obj = new Obj(l.Name);
        foreach (var m in l.Members) obj.Fields[m.Name] = ReadValue(m.Type, r);
        return obj;
    }

    public static object? ReadValue(TypeSpec t, BinReader r)
    {
        switch (t.Kind)
        {
            case "bool": return r.Bool();
            case "int8": case "tchar": return r.I8();
            case "uint8": case "e1": return r.U8();
            case "int16": return r.I16();
            case "uint16": case "e2": case "wchar": return r.U16();
            case "int": case "int32": case "e4": return r.I32();
            case "uint": case "uint32": case "ucs4": return r.U32();
            case "int64": case "e8": return r.I64();
            case "uint64": return r.U64();
            case "float": return r.F32();
            case "double": return r.F64();
            case "HalfFloat": return (float)r.F16();
            case "String": return r.Str();
            case "WString": return r.WStr();
            case "GGUUID": return r.Guid();
            case "uint128": return r.Bytes(16);
            case "Ref": return r.Ref();
            case "Array":
                switch (t.Item!.Kind)
                {
                    case "float": return r.F32Array();
                    case "int": case "int32": return r.I32Array();
                    case "uint": case "uint32": return r.U32Array();
                    case "uint16": return r.U16Array();
                    case "uint8": return r.U8Array();
                }
                {
                    var n = r.Count();
                    var a = new object?[n];
                    for (var i = 0; i < n; i++) a[i] = ReadValue(t.Item, r);
                    return a;
                }
            case "Map":
                {
                    var n = r.Count();
                    var a = new object?[n];
                    for (var i = 0; i < n; i++) { r.Skip(4); a[i] = ReadValue(t.Item!, r); }
                    return a;
                }
            case "Struct":
                {
                    if (Custom.TryGetValue(t.Struct!, out var custom)) return custom(r);
                    var l = Get(t.Struct!) ?? throw new NotSupportedException($"no layout for struct {t.Struct}");
                    return ReadStruct(l, r);
                }
            default:
                throw new NotSupportedException($"type kind {t.Kind}");
        }
    }
}
