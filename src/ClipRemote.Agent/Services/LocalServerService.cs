using System.IO;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ClipRemote.Agent.Models;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace ClipRemote.Agent.Services;

public sealed class LocalServerService : IAsyncDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly SettingsService _settingsService;
    private readonly ShortcutExecutor _shortcutExecutor;
    private WebApplication? _app;

    public LocalServerService(SettingsService settingsService, ShortcutExecutor shortcutExecutor)
    {
        _settingsService = settingsService;
        _shortcutExecutor = shortcutExecutor;
    }

    public AgentSettings Settings { get; private set; } = new();
    public bool IsRunning => _app is not null;

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_app is not null)
        {
            return;
        }

        Settings = _settingsService.Load();

        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseUrls($"http://0.0.0.0:{Settings.Port}");

        var app = builder.Build();
        app.UseWebSockets(new WebSocketOptions
        {
            KeepAliveInterval = TimeSpan.FromSeconds(20)
        });

        app.MapGet("/health", () => Results.Json(new
        {
            service = "ClipRemote.Agent",
            status = "ok",
            version = "0.1"
        }));

        app.Map("/ws", HandleWebSocketAsync);

        await app.StartAsync(cancellationToken);
        _app = app;
    }

    private async Task HandleWebSocketAsync(HttpContext context)
    {
        if (!context.WebSockets.IsWebSocketRequest)
        {
            context.Response.StatusCode = StatusCodes.Status426UpgradeRequired;
            return;
        }

        var suppliedToken = context.Request.Headers["X-ClipRemote-Token"].ToString();
        if (!SecureEquals(suppliedToken, Settings.PairingToken))
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }

        using var socket = await context.WebSockets.AcceptWebSocketAsync();
        var buffer = new byte[4096];

        while (socket.State == WebSocketState.Open && !context.RequestAborted.IsCancellationRequested)
        {
            using var messageStream = new MemoryStream();
            WebSocketReceiveResult receiveResult;

            do
            {
                receiveResult = await socket.ReceiveAsync(
                    new ArraySegment<byte>(buffer),
                    context.RequestAborted);

                if (receiveResult.MessageType == WebSocketMessageType.Close)
                {
                    await socket.CloseAsync(
                        WebSocketCloseStatus.NormalClosure,
                        "Closing",
                        CancellationToken.None);
                    return;
                }

                if (messageStream.Length + receiveResult.Count > 16 * 1024)
                {
                    await SendAsync(socket, new ActionResponse(false, "Mensaje demasiado grande."), context.RequestAborted);
                    return;
                }

                messageStream.Write(buffer, 0, receiveResult.Count);
            }
            while (!receiveResult.EndOfMessage);

            if (receiveResult.MessageType != WebSocketMessageType.Text)
            {
                continue;
            }

            var response = HandleMessage(Encoding.UTF8.GetString(messageStream.ToArray()));
            await SendAsync(socket, response, context.RequestAborted);
        }
    }

    private ActionResponse HandleMessage(string json)
    {
        ActionRequest? request;
        try
        {
            request = JsonSerializer.Deserialize<ActionRequest>(json, JsonOptions);
        }
        catch
        {
            return new ActionResponse(false, "JSON no válido.");
        }

        if (request is null ||
            !string.Equals(request.Type, "action", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(request.Action))
        {
            return new ActionResponse(false, "Petición no válida.");
        }

        if (!Settings.Actions.TryGetValue(request.Action, out var shortcut))
        {
            return new ActionResponse(false, $"Acción desconocida: {request.Action}");
        }

        var result = _shortcutExecutor.Execute(shortcut);
        return new ActionResponse(result.Success, result.Message, request.Action);
    }

    private static async Task SendAsync(
        WebSocket socket,
        ActionResponse response,
        CancellationToken cancellationToken)
    {
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(response, JsonOptions));
        await socket.SendAsync(
            new ArraySegment<byte>(bytes),
            WebSocketMessageType.Text,
            true,
            cancellationToken);
    }

    private static bool SecureEquals(string left, string right)
    {
        if (string.IsNullOrEmpty(left) || string.IsNullOrEmpty(right))
        {
            return false;
        }

        var leftBytes = Encoding.UTF8.GetBytes(left);
        var rightBytes = Encoding.UTF8.GetBytes(right);

        return leftBytes.Length == rightBytes.Length &&
               CryptographicOperations.FixedTimeEquals(leftBytes, rightBytes);
    }

    public async ValueTask DisposeAsync()
    {
        if (_app is null)
        {
            return;
        }

        await _app.StopAsync();
        await _app.DisposeAsync();
        _app = null;
    }

    private sealed record ActionRequest(string Type, string Action);
    private sealed record ActionResponse(bool Success, string Message, string? Action = null);
}
