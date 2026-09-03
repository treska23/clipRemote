using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Android.App;
using Android.Content;
using Android.Content.PM;
using Android.Graphics;
using Android.OS;
using Android.Views;
using Android.Views.InputMethods;
using Android.Widget;

namespace ClipRemote.Mobile;

[Activity(
    Name = "com.treska23.clipremote.MainActivity",
    Label = "ClipRemote",
    MainLauncher = true,
    Exported = true,
    ScreenOrientation = ScreenOrientation.Portrait,
    Theme = "@android:style/Theme.Material.Light.NoActionBar")]
public sealed class MainActivity : Activity
{
    private const string PreferencesName = "clipremote";
    private const string AddressPreference = "address";
    private const string TokenPreference = "token";

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly JsonSerializerOptions _json = new(JsonSerializerDefaults.Web);

    private ClientWebSocket? _socket;
    private EditText _address = null!;
    private EditText _token = null!;
    private TextView _status = null!;
    private Button _connect = null!;
    private Button _undo = null!;
    private Button _redo = null!;

    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);
        Window?.SetStatusBarColor(Color.ParseColor("#101419"));
        Window?.SetNavigationBarColor(Color.ParseColor("#101419"));

        SetContentView(BuildUi());
        LoadSavedConnection();
        var autoConnect = ApplyProvisioning(Intent);
        SetConnected(false);

        if (autoConnect)
        {
            _ = ConnectAsync();
        }
    }

    protected override void OnDestroy()
    {
        _socket?.Dispose();
        _socket = null;
        _gate.Dispose();
        base.OnDestroy();
    }

    private View BuildUi()
    {
        var scroll = new ScrollView(this) { FillViewport = true };
        scroll.SetBackgroundColor(Color.ParseColor("#101419"));

        var root = new LinearLayout(this) { Orientation = Orientation.Vertical };
        root.SetPadding(Dp(22), Dp(28), Dp(22), Dp(28));

        root.AddView(Text("ClipRemote", 30, Color.White, TypefaceStyle.Bold));
        root.AddView(Text("Control local de Clip Studio Paint", 16, "#AAB3BE", bottom: 26));

        _status = Text("DESCONECTADO", 17, "#E0A94F", TypefaceStyle.Bold, bottom: 24);
        root.AddView(_status);

        root.AddView(Label("DIRECCIÓN DEL PC"));
        _address = Input("192.168.1.3:5057");
        root.AddView(_address, Params(54, bottom: 18));

        root.AddView(Label("TOKEN DE EMPAREJAMIENTO"));
        _token = Input("Token del Agent");
        _token.InputType = Android.Text.InputTypes.ClassText |
                           Android.Text.InputTypes.TextVariationVisiblePassword;
        root.AddView(_token, Params(54, bottom: 20));

        _connect = Button("CONECTAR");
        _connect.Click += async (_, _) =>
        {
            if (_socket?.State == WebSocketState.Open)
            {
                await DisconnectAsync();
            }
            else
            {
                await ConnectAsync();
            }
        };
        root.AddView(_connect, Params(58, bottom: 32));

        root.AddView(Label("PRIMERA PRUEBA"));

        var row = new LinearLayout(this)
        {
            Orientation = Orientation.Horizontal,
            WeightSum = 2f
        };

        _undo = Button("DESHACER");
        _redo = Button("REHACER");
        _undo.Click += async (_, _) => await SendActionAsync("undo");
        _redo.Click += async (_, _) => await SendActionAsync("redo");

        row.AddView(_undo, Weighted(right: 6));
        row.AddView(_redo, Weighted(left: 6));
        root.AddView(row, Params(72, top: 8));

        root.AddView(Text(
            "Con Clip Studio en primer plano, haz un trazo y pulsa DESHACER.",
            14,
            "#7F8995",
            top: 22));

        scroll.AddView(root, new ScrollView.LayoutParams(
            ViewGroup.LayoutParams.MatchParent,
            ViewGroup.LayoutParams.WrapContent));
        return scroll;
    }

    private async Task<bool> ConnectAsync()
    {
        var address = NormalizeAddress(_address.Text);
        var token = _token.Text?.Trim() ?? string.Empty;

        if (string.IsNullOrWhiteSpace(address) || string.IsNullOrWhiteSpace(token))
        {
            SetStatus("FALTA DIRECCIÓN O TOKEN", false);
            return false;
        }

        HideKeyboard();
        SetStatus("CONECTANDO…", null);
        RunOnUiThread(() => _connect.Enabled = false);

        try
        {
            await _gate.WaitAsync();
            try
            {
                _socket?.Dispose();
                _socket = new ClientWebSocket();
                _socket.Options.SetRequestHeader("X-ClipRemote-Token", token);

                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(4));
                await _socket.ConnectAsync(new Uri($"ws://{address}/ws"), timeout.Token);
                SaveConnection(address, token);
            }
            finally
            {
                _gate.Release();
            }

            SetStatus("CONECTADO", true);
            SetConnected(true);
            return true;
        }
        catch (Exception ex)
        {
            _socket?.Dispose();
            _socket = null;
            SetStatus($"NO CONECTA · {FriendlyError(ex)}", false);
            SetConnected(false);
            return false;
        }
        finally
        {
            RunOnUiThread(() => _connect.Enabled = true);
        }
    }

    private async Task DisconnectAsync()
    {
        await _gate.WaitAsync();
        try
        {
            if (_socket?.State == WebSocketState.Open)
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(1));
                try
                {
                    await _socket.CloseAsync(
                        WebSocketCloseStatus.NormalClosure,
                        "Mobile disconnect",
                        timeout.Token);
                }
                catch
                {
                    // Dispose below is enough if the graceful close fails.
                }
            }

            _socket?.Dispose();
            _socket = null;
        }
        finally
        {
            _gate.Release();
        }

        SetStatus("DESCONECTADO", null);
        SetConnected(false);
    }

    private async Task SendActionAsync(string action)
    {
        if (_socket?.State != WebSocketState.Open && !await ConnectAsync())
        {
            return;
        }

        await _gate.WaitAsync();
        try
        {
            if (_socket?.State != WebSocketState.Open)
            {
                SetStatus("CONEXIÓN PERDIDA", false);
                SetConnected(false);
                return;
            }

            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            var payload = Encoding.UTF8.GetBytes(
                JsonSerializer.Serialize(new ActionRequest("action", action), _json));

            await _socket.SendAsync(
                new ArraySegment<byte>(payload),
                WebSocketMessageType.Text,
                true,
                timeout.Token);

            var responseJson = await ReceiveTextAsync(_socket, timeout.Token);
            var response = JsonSerializer.Deserialize<ActionResponse>(responseJson, _json);

            if (response is null)
            {
                SetStatus("RESPUESTA NO VÁLIDA", false);
                return;
            }

            SetStatus(response.Success ? "HECHO" : response.Message.ToUpperInvariant(), response.Success);
        }
        catch (Exception ex)
        {
            _socket?.Dispose();
            _socket = null;
            SetStatus($"CONEXIÓN PERDIDA · {FriendlyError(ex)}", false);
            SetConnected(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private static async Task<string> ReceiveTextAsync(
        ClientWebSocket socket,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[4096];
        using var stream = new MemoryStream();

        while (true)
        {
            var result = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), cancellationToken);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                throw new WebSocketException("El Agent cerró la conexión.");
            }

            if (result.MessageType != WebSocketMessageType.Text)
            {
                continue;
            }

            stream.Write(buffer, 0, result.Count);
            if (stream.Length > 16 * 1024)
            {
                throw new InvalidDataException("Respuesta demasiado grande.");
            }

            if (result.EndOfMessage)
            {
                return Encoding.UTF8.GetString(stream.ToArray());
            }
        }
    }

    private bool ApplyProvisioning(Intent? intent)
    {
        if (intent is null)
        {
            return false;
        }

        var address = intent.GetStringExtra("address")?.Trim();
        var token = intent.GetStringExtra("token")?.Trim();

        if (!string.IsNullOrWhiteSpace(address))
        {
            _address.Text = NormalizeAddress(address);
        }

        if (!string.IsNullOrWhiteSpace(token))
        {
            _token.Text = token;
        }

        if (!string.IsNullOrWhiteSpace(address) && !string.IsNullOrWhiteSpace(token))
        {
            SaveConnection(_address.Text ?? string.Empty, _token.Text ?? string.Empty);
        }

        return intent.GetBooleanExtra("autoconnect", false);
    }

    private void LoadSavedConnection()
    {
        var preferences = GetSharedPreferences(PreferencesName, FileCreationMode.Private);
        _address.Text = preferences?.GetString(AddressPreference, string.Empty) ?? string.Empty;
        _token.Text = preferences?.GetString(TokenPreference, string.Empty) ?? string.Empty;
    }

    private void SaveConnection(string address, string token)
    {
        var editor = GetSharedPreferences(PreferencesName, FileCreationMode.Private)?.Edit();
        editor?.PutString(AddressPreference, address);
        editor?.PutString(TokenPreference, token);
        editor?.Apply();
    }

    private void SetConnected(bool connected) => RunOnUiThread(() =>
    {
        _connect.Text = connected ? "DESCONECTAR" : "CONECTAR";
        _undo.Enabled = connected;
        _redo.Enabled = connected;
    });

    private void SetStatus(string text, bool? success) => RunOnUiThread(() =>
    {
        _status.Text = text;
        _status.SetTextColor(success switch
        {
            true => Color.ParseColor("#36C98F"),
            false => Color.ParseColor("#EF6A6A"),
            _ => Color.ParseColor("#E0A94F")
        });
    });

    private void HideKeyboard()
    {
        var input = GetSystemService(InputMethodService) as InputMethodManager;
        input?.HideSoftInputFromWindow(CurrentFocus?.WindowToken, HideSoftInputFlags.None);
        CurrentFocus?.ClearFocus();
    }

    private TextView Label(string value) =>
        Text(value, 12, "#AAB3BE", TypefaceStyle.Bold, bottom: 6);

    private TextView Text(
        string value,
        float size,
        string color,
        TypefaceStyle style = TypefaceStyle.Normal,
        int top = 0,
        int bottom = 0) =>
        Text(value, size, Color.ParseColor(color), style, top, bottom);

    private TextView Text(
        string value,
        float size,
        Color color,
        TypefaceStyle style = TypefaceStyle.Normal,
        int top = 0,
        int bottom = 0)
    {
        var view = new TextView(this) { Text = value, TextSize = size };
        view.SetTextColor(color);
        view.SetTypeface(Typeface.Default, style);
        view.LayoutParameters = Params(ViewGroup.LayoutParams.WrapContent, top, bottom);
        return view;
    }

    private EditText Input(string hint)
    {
        var input = new EditText(this)
        {
            Hint = hint,
            TextSize = 16,
            InputType = Android.Text.InputTypes.ClassText
        };
        input.SetSingleLine(true);
        input.SetTextColor(Color.White);
        input.SetHintTextColor(Color.ParseColor("#66717D"));
        input.SetBackgroundColor(Color.ParseColor("#202730"));
        input.SetPadding(Dp(14), 0, Dp(14), 0);
        return input;
    }

    private Button Button(string value)
    {
        var button = new Button(this) { Text = value, TextSize = 15 };
        button.SetTextColor(Color.White);
        button.SetBackgroundColor(Color.ParseColor("#2C6BE8"));
        return button;
    }

    private LinearLayout.LayoutParams Params(int heightDp, int top = 0, int bottom = 0)
    {
        var height = heightDp < 0 ? heightDp : Dp(heightDp);
        var result = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MatchParent, height);
        result.SetMargins(0, Dp(top), 0, Dp(bottom));
        return result;
    }

    private LinearLayout.LayoutParams Weighted(int left = 0, int right = 0)
    {
        var result = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MatchParent, 1f);
        result.SetMargins(Dp(left), 0, Dp(right), 0);
        return result;
    }

    private int Dp(int value) =>
        (int)Math.Round(value * (Resources?.DisplayMetrics?.Density ?? 1f));

    private static string NormalizeAddress(string? address)
    {
        var value = address?.Trim() ?? string.Empty;
        value = value
            .Replace("ws://", string.Empty, StringComparison.OrdinalIgnoreCase)
            .Replace("http://", string.Empty, StringComparison.OrdinalIgnoreCase)
            .TrimEnd('/');

        return value.EndsWith("/ws", StringComparison.OrdinalIgnoreCase)
            ? value[..^3].TrimEnd('/')
            : value;
    }

    private static string FriendlyError(Exception exception) => exception switch
    {
        OperationCanceledException => "TIEMPO AGOTADO",
        WebSocketException => "WEBSOCKET",
        _ => exception.Message
    };

    private sealed record ActionRequest(string Type, string Action);
    private sealed record ActionResponse(bool Success, string Message, string? Action = null);
}
