using System.Net;
using System.Net.Sockets;
using ClipRemote.Agent.Services;

namespace ClipRemote.Agent.ViewModels;

public sealed class MainViewModel
{
    public MainViewModel(SettingsService settingsService, LocalServerService server)
    {
        var settings = server.Settings;
        var localAddress = Dns.GetHostAddresses(Dns.GetHostName())
            .FirstOrDefault(address =>
                address.AddressFamily == AddressFamily.InterNetwork &&
                !IPAddress.IsLoopback(address));

        Status = server.IsRunning ? "LISTO · ESPERANDO MÓVIL" : "DETENIDO";
        Address = $"{localAddress ?? IPAddress.Loopback}:{settings.Port}";
        PairingToken = settings.PairingToken;
        SettingsPath = settingsService.SettingsPath;
    }

    public string Status { get; }
    public string Address { get; }
    public string PairingToken { get; }
    public string SettingsPath { get; }
}
