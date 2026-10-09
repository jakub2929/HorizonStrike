using System.Globalization;
using System.Text;

namespace Hzs.Decima.Core;

/// <summary>A decoded object or struct: member values by name (as far as the hand-written layout goes).</summary>
public sealed class Obj
{
    public string Type { get; }
    public Guid Uuid { get; init; }
    public Dictionary<string, object?> Fields { get; } = new(StringComparer.Ordinal);
    /// <summary>For binary (MsgReadBinary) classes: offset of the handler data in <see cref="File"/>.Data.</summary>
    public int ExtraOffset { get; set; } = -1;
    public int ExtraEnd { get; set; } = -1;
    public CoreFile? File { get; init; }
    public CoreObject? Source { get; init; }

    public Obj(string type) => Type = type;

    public object? this[string name] => Fields.TryGetValue(name, out var v) ? v : throw new KeyNotFoundException($"{Type}.{name} not decoded");
    public bool Has(string name) => Fields.ContainsKey(name);

    public float Float(string n) => Convert.ToSingle(this[n], CultureInfo.InvariantCulture);
    public double Double(string n) => Convert.ToDouble(this[n], CultureInfo.InvariantCulture);
    public int Int(string n) => Convert.ToInt32(this[n], CultureInfo.InvariantCulture);
    public long Long(string n) => Convert.ToInt64(this[n], CultureInfo.InvariantCulture);
    public bool Bool(string n) => (bool)this[n]!;
    public string Str(string n) => (string)this[n]!;
    public Ref Ref(string n) => (Ref)this[n]!;
    public Obj Struct(string n) => (Obj)this[n]!;
    public object?[] Arr(string n) => this[n] switch
    {
        object?[] a => a,
        System.Array a => a.Cast<object?>().ToArray(),
        var v => throw new InvalidCastException($"{Type}.{n} is {v?.GetType().Name}"),
    };
    public Ref[] Refs(string n) => Arr(n).Select(x => (Ref)x!).ToArray();
    public Obj[] Structs(string n) => Arr(n).Select(x => (Obj)x!).ToArray();
    public T[] Prims<T>(string n) => (T[])this[n]!;

    public BinReader ExtraReader() =>
        ExtraOffset < 0 || File is null ? throw new InvalidOperationException($"{Type} has no binary data") : new BinReader(File.Data, ExtraOffset, ExtraEnd);

    public override string ToString() => Format(this, 0);

    public static string Format(object? v, int depth)
    {
        switch (v)
        {
            case null: return "null";
            case float f: return f.ToString("R", CultureInfo.InvariantCulture);
            case double d: return d.ToString("R", CultureInfo.InvariantCulture);
            case string s: return "\"" + s + "\"";
            case Obj o:
                if (depth > 4) return "{...}";
                var sb = new StringBuilder("{");
                foreach (var (k, val) in o.Fields) sb.Append(' ').Append(k).Append('=').Append(Format(val, depth + 1)).Append(';');
                return sb.Append(" }").ToString();
            case byte[] b: return $"<{b.Length} bytes>";
            case System.Array a:
                if (a.Length > 16) return $"[{a.Length} items]";
                return "[" + string.Join(", ", a.Cast<object?>().Select(x => Format(x, depth + 1))) + "]";
            case IFormattable fm: return fm.ToString(null, CultureInfo.InvariantCulture);
            default: return v.ToString() ?? "";
        }
    }
}
