using System.Runtime.InteropServices;
using System.Text;

namespace ClipRemote.Agent.Services;

public sealed class ShortcutExecutor
{
    public (bool Success, string Message) Execute(string shortcut)
    {
        if (string.IsNullOrWhiteSpace(shortcut))
        {
            return (false, "Esta acción todavía no tiene un atajo configurado.");
        }

        if (!IsClipStudioForeground())
        {
            return (false, "Clip Studio Paint no está en primer plano.");
        }

        var tokens = shortcut
            .Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(token => token.ToUpperInvariant())
            .ToList();

        if (tokens.Count == 0)
        {
            return (false, "El atajo configurado no es válido.");
        }

        var modifiers = new List<ushort>();
        ushort? key = null;

        foreach (var token in tokens)
        {
            if (TryGetModifier(token, out var modifier))
            {
                modifiers.Add(modifier);
                continue;
            }

            if (key is not null || !TryGetKey(token, out var parsedKey))
            {
                return (false, $"No entiendo el atajo '{shortcut}'.");
            }

            key = parsedKey;
        }

        if (key is null)
        {
            return (false, $"No entiendo el atajo '{shortcut}'.");
        }

        var inputs = new List<Input>();
        inputs.AddRange(modifiers.Select(KeyDown));
        inputs.Add(KeyDown(key.Value));
        inputs.Add(KeyUp(key.Value));
        inputs.AddRange(modifiers.AsEnumerable().Reverse().Select(KeyUp));

        var sent = SendInput(
            (uint)inputs.Count,
            inputs.ToArray(),
            Marshal.SizeOf<Input>());

        return sent == inputs.Count
            ? (true, "Hecho.")
            : (false, "Windows no pudo enviar el atajo completo.");
    }

    private static bool IsClipStudioForeground()
    {
        var window = GetForegroundWindow();
        if (window == IntPtr.Zero)
        {
            return false;
        }

        var length = GetWindowTextLength(window);
        if (length <= 0)
        {
            return false;
        }

        var title = new StringBuilder(length + 1);
        GetWindowText(window, title, title.Capacity);

        return title.ToString().Contains("CLIP STUDIO PAINT", StringComparison.OrdinalIgnoreCase);
    }

    private static bool TryGetModifier(string token, out ushort key)
    {
        key = token switch
        {
            "CTRL" or "CONTROL" => 0x11,
            "SHIFT" => 0x10,
            "ALT" => 0x12,
            "WIN" or "WINDOWS" => 0x5B,
            _ => 0
        };

        return key != 0;
    }

    private static bool TryGetKey(string token, out ushort key)
    {
        if (token.Length == 1 && char.IsLetterOrDigit(token[0]))
        {
            key = token[0];
            return true;
        }

        if (token.StartsWith('F') &&
            int.TryParse(token[1..], out var functionNumber) &&
            functionNumber is >= 1 and <= 24)
        {
            key = (ushort)(0x70 + functionNumber - 1);
            return true;
        }

        key = token switch
        {
            "SPACE" => 0x20,
            "ENTER" or "RETURN" => 0x0D,
            "ESC" or "ESCAPE" => 0x1B,
            "TAB" => 0x09,
            "BACKSPACE" => 0x08,
            "DELETE" or "DEL" => 0x2E,
            "LEFT" => 0x25,
            "UP" => 0x26,
            "RIGHT" => 0x27,
            "DOWN" => 0x28,
            "HOME" => 0x24,
            "END" => 0x23,
            "PAGEUP" => 0x21,
            "PAGEDOWN" => 0x22,
            _ => 0
        };

        return key != 0;
    }

    private static Input KeyDown(ushort key) => KeyboardInput(key, 0);
    private static Input KeyUp(ushort key) => KeyboardInput(key, KeyEventKeyUp);

    private static Input KeyboardInput(ushort key, uint flags) => new()
    {
        Type = InputKeyboard,
        Union = new InputUnion
        {
            Keyboard = new KeyboardInput
            {
                VirtualKey = key,
                Flags = flags
            }
        }
    };

    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Union;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)]
        public KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, Input[] inputs, int inputSize);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr window);
}
