using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Android.App;
using Android.Content;
using Android.Content.PM;
using Android.Graphics;
using Android.OS;
using Android.Text.InputMethods;
using Android.Views;
using Android.Widget;

namespace ClipRemote.Mobile;

[Activity(
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

    private readonly SemaphoreSlim _socketGate = new(1, 1);
    private readonly JsonSerializerOptions _jsonOptions = new(JsonSerializerDefaults.Web);

    private ClientWebSocket? _socket;
    private EditText _addressText = null!;
    private EditText _tokenText = null!;
    private TextView _statusText = null!;
    private Button _connectButton = null!;
    private Button _undoButton = null!;
    private Button _redoButton = null!;

    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);
        Window?.SetStatusBarColor(Color.ParseColor("#101419"));
        Window?.SetNavigationBarColor(Color.ParseColor("#101419"));

        SetContentView(BuildUi());
        LoadSavedConnection();
        SetControlsConnected(false);
    }

    protected override void OnDestroy()
    {
        try
        {
            _socket?.Dispose();
            _socket = null;
        }
        finally
        {
            _socketGate.Dispose();
            base.OnDestroy();
        }
    }

    private View BuildUi()
    {
        var root = new ScrollView(this)
        {
            FillViewport = true
        };
        root.SetBackgroundColor(Color.ParseColor("#101419"));

        var content = new LinearLayout(this)
        {
            Orientation = Orientation.Vertical
        };
        content.SetPadding(Dp(22), Dp(28), Dp(22), Dp(28));

        content.AddView(CreateText("ClipRemote", 30, Color.White, TypefaceStyle.Bold));
        content.AddView(CreateText(
            "Control local de Clip Studio Paint",
            16,
            Color.ParseColor("#AAB3BE"),
            TypefaceStyle.Normal,
            topMargin: 4,
            bottomMargin: 28));

        _statusText = CreateText("DESCONECTADO", 17, Color.ParseColor("#E0A94F"), TypefaceStyle.Bold);
        content.AddView(_statusText, WithMargins(matchWidth: true, height: WrapContent, bottom: 22));

        content.AddView(CreateLabel("DIRECCIÓN DEL PC"));
        _addressText = CreateInput("192.168.1.3:5057", singleLine: true);
        content.AddView(_addressText, WithMargins(matchWidth: true, height: Dp(54), bottom: 18));

        content.AddView(CreateLabel("TOKEN DE EMPAREJAMIENTO"));
        _tokenText = CreateInput("Pega aquí el token del Agent", singleLine: true);
        _tokenText.InputType = Android.Text.InputTypes.ClassText |
                               Android.Text.InputTypes.TextVariationVisiblePassword;
        content.AddView(_tokenText, WithMargins(matchWidth: true, height: Dp(54), bottom: 20));

        _connectButton = CreateButton("CONECTAR");
        _connectButton.Click += async (_, _) => await ToggleConnectionAsync();
        content.AddView(_connectButton, WithMargins(matchWidth: true, height: Dp(58), bottom: 32));

        content.AddView(CreateText("ANIMACIÓN / EDICIÓN", 13, Color.ParseColor("#AAB3BE"), TypefaceStyle.Bold));

        var actionRow = new LinearLayout(this)
        {
            Orientation = Orientation.Horizontal,
            WeightSum = 2f
        };

        _undoButton = CreateButton("DESHACER");
        _redoButton = CreateButton("REHACER");
        _undoButton.Click += async (_, _) => await SendActionAsync("undo");
        _redoButton.Click += async (_, _) => await SendActionAsync("redo");

        actionRow.AddView(_undoButton, WeightedButtonParams(rightMargin: 6));
        actionRow.AddView(_redoButton, WeightedButtonParams(leftMargin: 6));
        content.AddView(actionRow, WithMargins(matchWidth: true, height: Dp(72), top: 10));

        content.AddView(CreateText(
            "Primera prueba: abre Clip Studio Paint en el PC, haz un trazo y pulsa DESHACER.",
            14,
            Color.ParseColor("#7F8995"),
            TypefaceStyle.Normal,
            topMargin: 24));

        root.AddView(content, new ScrollView.LayoutParams(
            ViewGroup.LayoutParams.MatchParent,
            ViewGroup.LayoutParams.WrapContent));
        return root;
    }

    private async Task ToggleConnectionAsync()
    {
        if (_socket?.State == WebSocketState.Open)
        {
            await DisconnectAsync();
            return;
        }

        await ConnectAsync();
    }

    private async Task<bool> ConnectAsync()
    {
        var address = NormalizeAddress(_addressText.Text);
        var token = _tokenText.Text?.Trim() ?? string.Empty;

        if (string.IsNullOrWhiteSpace(address) || string.IsNullOrWhiteSpace(token))
        {
            SetStatus("FALTA DIRECCIÓN O TOKEN", success: false);
            return false;
        }

        HideKeyboard();
        SetStatus("CONECTANDO…", success: null);
        _connectButton.Enabled = false;

        try
        {
            await _socketGate.WaitAsync();
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
                _socketGate.Release();
            }

            SetStatus("CONECTADO", success: true);
            SetControlsConnected(true);
            return true;
        }
        catch (Exception ex)
        {
            _socket?.Dispose();
            _socket = null;
            SetStatus($"NO CONECTA · {FriendlyError(ex)}", success: false);
            SetControlsConnected(false);
            return false;
        }
        finally
        {
            _connectButton.Enabled = true;
        }
    }

    private async Task DisconnectAsync()
    {
        await _socketGate.WaitAsync();
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
                    // Closing is best-effort; disposing below is enough.
                }
            }

            _socket?.Dispose();
            _socket = null;
        }
        finally
        {
            _socketGate.Release();
        }

        SetStatus("DESCONECTADO", success: null);
        SetControlsConnected(false);
    }

    private async Task SendActionAsync(string action)
    {
        if (_socket?.State != WebSocketState.Open && !await ConnectAsync())
        {
            return;
        }

        await _socketGate.WaitAsync();
        try
        {
            if (_socket?.State != WebSocketState.Open)
            {
                SetStatus("CONEXIÓN PERDIDA", success: false);
                SetControlsConnected(false);
                return;
            }

            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            var request = JsonSerializer.Serialize(new ActionRequest("action", action), _jsonOptions);
            var requestBytes = Encoding.UTF8.GetBytes(request);

            await _socket.SendAsync(
                new ArraySegment<byte>(requestBytes),
                WebSocketMessageType.Text,
                true,
                timeout.Token);

            var responseText = await ReceiveTextAsync(_socket, timeout.Token);
            var response = JsonSerializer.Deserialize<ActionResponse>(responseText, _jsonOptions);

            if (response is null)
            {
                SetStatus("RESPUESTA NO VÁLIDA", success: false);
                return;
            }

            SetStatus(response.Success ? "HECHO" : response.Message.ToUpperInvariant(), response.Success);
        }
        catch (Exception ex)
        {
            _socket?.Dispose();
            _socket = null;
            SetStatus($"CONEXIÓN PERDIDA · {FriendlyError(ex)}", success: false);
            SetControlsConnected(false);
        }
        finally
        {
            _socketGate.Release();
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
            var result = await socket.ReceiveAsync(
                new ArraySegment<byte>(buffer),
                cancellationToken);

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

    private void LoadSavedConnection()
    {
        var preferences = GetSharedPreferences(PreferencesName, FileCreationMode.Private);
        _addressText.Text = preferences?.GetString(AddressPreference, string.Empty) ?? string.Empty;
        _tokenText.Text = preferences?.GetString(TokenPreference, string.Empty) ?? string.Empty;
    }

    private void SaveConnection(string address, string token)
    {
        var editor = GetSharedPreferences(PreferencesName, FileCreationMode.Private)?.Edit();
        editor?.PutString(AddressPreference, address);
        editor?.PutString(TokenPreference, token);
        editor?.Apply();
    }

    private void SetControlsConnected(bool connected)
    {
        RunOnUiThread(() =>
        {
            _connectButton.Text = connected ? "DESCONECTAR" : "CONECTAR";
            _undoButton.Enabled = connected;
            _redoButton.Enabled = connected;
        });
    }

    private void SetStatus(string text, bool? success)
    {
        RunOnUiThread(() =>
        {
            _statusText.Text = text;
            _statusText.SetTextColor(success switch
            {
                true => Color.ParseColor("#36C98F"),
                false => Color.ParseColor("#EF6A6A"),
                _ => Color.ParseColor("#E0A94F")
            });
        });
    }

    private void HideKeyboard()
    {
        var input = GetSystemService(InputMethodService) as InputMethodManager;
        input?.HideSoftInputFromWindow(CurrentFocus?.WindowToken, HideSoftInputFlags.None);
        CurrentFocus?.ClearFocus();
    }

    private TextView CreateLabel(string text) =>
        CreateText(text, 12, Color.ParseColor("#AAB3BE"), TypefaceStyle.Bold, bottomMargin: 6);

    private TextView CreateText(
        string text,
        float size,
        Color color,
        TypefaceStyle style,
        int topMargin = 0,
        int bottomMargin = 0)
    {
        var view = new TextView(this)
        {
            Text = text,
            TextSize = size
        };
        view.SetTextColor(color);
        view.SetTypeface(Typeface.Default, style);
        view.LayoutParameters = WithMargins(
            matchWidth: true,
            height: WrapContent,
            top: topMargin,
            bottom: bottomMargin);
        return view;
    }

    private EditText CreateInput(string hint, bool singleLine)
    {
        var input = new EditText(this)
        {
            Hint = hint,
            TextSize = 16,
            SingleLine = singleLine,
            InputType = Android.Text.InputTypes.ClassText
        };
        input.SetTextColor(Color.White);
        input.SetHintTextColor(Color.ParseColor("#66717D"));
        input.SetBackgroundColor(Color.ParseColor("#202730"));
        input.SetPadding(Dp(14), 0, Dp(14), 0);
        return input;
    }

    private Button CreateButton(string text)
    {
        var button = new Button(this)
        {
            Text = text,
            TextSize = 15
        };
        button.SetTextColor(Color.White);
        button.SetBackgroundColor(Color.ParseColor("#2C6BE8"));
        return button;
    }

    private LinearLayout.LayoutParams WeightedButtonParams(int leftMargin = 0, int rightMargin = 0)
    {
        var parameters = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MatchParent, 1f);
        parameters.LeftMargin = Dp(leftMargin);
        parameters.RightMargin = Dp(rightMargin);
        return parameters;
    }

    private LinearLayout.LayoutParams WithMargins(
        bool matchWidth,
        int height,
        int left = 0,
        int top = 0,
        int right = 0,
        int bottom = 0)
    {
        var parameters = new LinearLayout.LayoutParams(
            matchWidth ? ViewGroup.LayoutParams.MatchParent : ViewGroup.LayoutParams.WrapContent,
            height);
        parameters.SetMargins(Dp(left), Dp(top), Dp(right), Dp(bottom));
        return parameters;
    }

    private int Dp(int value) =>
        (int)Math.Round(value * Resources!.DisplayMetrics!.Density);

    private static string NormalizeAddress(string? address)
    {
        var value = address?.Trim() ?? string.Empty;
        value = value
            .Replace("ws://", string.Empty, StringComparison.OrdinalIgnoreCase)
            .Replace("http://", string.Empty, StringComparison.OrdinalIgnoreCase)
            .TrimEnd('/');

        if (value.EndsWith("/ws", StringComparison.OrdinalIgnoreCase))
        {
            value = value[..^3].TrimEnd('/');
        }

        return value;
    }

    private static string FriendlyError(Exception exception) => exception switch
    {
        OperationCanceledException => "TIEMPO AGOTADO",
        WebSocketException => "WEBSOCKET",
        _ => exception.Message
    };

    private const int WrapContent = ViewGroup.LayoutParams.WrapContent;

    private sealed record ActionRequest(string Type, string Action);
    private sealed record ActionResponse(bool Success, string Message, string? Action = null);
}
