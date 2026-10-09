namespace Hzs.Decima.Core;

/// <summary>
/// Serialized member type: a primitive (bool, int8..uint64, float, double, HalfFloat, String, WString, GGUUID),
/// an enum of N bytes (<c>eN</c>), a reference (<c>Ref</c>: Ref/cptr/StreamingRef/UUIDRef/WeakPtr), a container
/// (<c>Array&lt;T&gt;</c>, <c>Map&lt;T&gt;</c> for HashMap/HashSet) or an embedded struct with its own layout.
/// </summary>
public sealed record TypeSpec(string Kind, TypeSpec? Item = null, string? Struct = null)
{
    private static readonly Dictionary<string, TypeSpec> Cache = new();

    public static TypeSpec Parse(string s)
    {
        lock (Cache)
        {
            if (Cache.TryGetValue(s, out var t)) return t;
            var lt = s.IndexOf('<');
            if (lt > 0)
            {
                var outer = s[..lt];
                var inner = Parse(s[(lt + 1)..s.LastIndexOf('>')]);
                t = outer switch
                {
                    "Array" => new TypeSpec("Array", inner),
                    "Map" => new TypeSpec("Map", inner),
                    _ => throw new ArgumentException($"unknown container {outer}"),
                };
            }
            else
            {
                t = s switch
                {
                    "bool" or "int8" or "uint8" or "int16" or "uint16" or "int" or "int32" or "uint" or "uint32" or "int64"
                        or "uint64" or "float" or "double" or "HalfFloat" or "String" or "WString" or "GGUUID" or "Ref"
                        or "e1" or "e2" or "e4" or "e8" or "wchar" or "ucs4" or "tchar" or "uint128" => new TypeSpec(s),
                    _ => new TypeSpec("Struct", null, s),
                };
            }
            Cache[s] = t;
            return t;
        }
    }
}

public sealed record Member(string Name, TypeSpec Type);

/// <summary>
/// Hand-written serialized layout of one RTTI class: members in serialization order (ascending member offset,
/// bases flattened). <see cref="Lead"/> are members serialized before the ObjectUUID (lower offsets than
/// RTTIRefObject.ObjectUUID). <see cref="Partial"/> layouts stop after the last member we read.
/// <see cref="Binary"/> classes append handler-specific data after the members.
/// </summary>
public sealed class Layout
{
    public ulong Id { get; }
    public string Name { get; }
    public Member[] Lead { get; }
    public Member[] Members { get; }
    public bool Binary { get; }
    public bool Partial { get; }
    public bool IsRefObject => Id != 0;

    public Layout(ulong id, string name, string members, string? lead, bool binary, bool partial)
    {
        Id = id;
        Name = name;
        Members = ParseMembers(members);
        Lead = ParseMembers(lead ?? "");
        Binary = binary;
        Partial = partial;
    }

    private static Member[] ParseMembers(string s) => s.Split(' ', StringSplitOptions.RemoveEmptyEntries)
        .Select(m => { var i = m.IndexOf(':'); return new Member(m[..i], TypeSpec.Parse(m[(i + 1)..])); }).ToArray();

    public int IndexOf(string member) => Array.FindIndex(Members, m => m.Name == member);
}
