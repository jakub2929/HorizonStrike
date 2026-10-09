using System.Text;
using Hzs.Common;

namespace Hzs.Cs2;

/// <summary>
/// ValveResourceFormat prints diagnostics with Console.WriteLine. In serve mode stdout is the JSON-lines protocol
/// (the Protocol object keeps the original writer), so while CS2 code runs Console.Out is redirected into the log.
/// </summary>
internal sealed class StdoutGuard : IDisposable
{
    private static readonly object Lock = new();
    private static int _depth;
    private static TextWriter? _original;

    private StdoutGuard() { }

    public static StdoutGuard Begin(Log log)
    {
        lock (Lock)
        {
            if (_depth++ == 0)
            {
                _original = Console.Out;
                Console.SetOut(TextWriter.Synchronized(new LogWriter(log)));
            }
        }
        return new StdoutGuard();
    }

    public void Dispose()
    {
        lock (Lock)
        {
            if (--_depth == 0 && _original is not null)
            {
                Console.Out.Flush();
                Console.SetOut(_original);
                _original = null;
            }
        }
    }

    private sealed class LogWriter(Log log) : TextWriter
    {
        private readonly StringBuilder _line = new();
        public override Encoding Encoding => Encoding.UTF8;

        public override void Write(char value)
        {
            if (value == '\n')
            {
                Flush();
                return;
            }
            if (value != '\r') _line.Append(value);
        }

        public override void Flush()
        {
            if (_line.Length == 0) return;
            log.Info("vrf: " + _line);
            _line.Clear();
        }
    }
}
