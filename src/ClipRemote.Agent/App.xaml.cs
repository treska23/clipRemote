using System.Windows;
using ClipRemote.Agent.Services;
using ClipRemote.Agent.ViewModels;

namespace ClipRemote.Agent;

public partial class App : Application
{
    private LocalServerService? _server;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var settingsService = new SettingsService();
        var shortcutExecutor = new ShortcutExecutor();
        _server = new LocalServerService(settingsService, shortcutExecutor);

        await _server.StartAsync();

        var window = new MainWindow
        {
            DataContext = new MainViewModel(settingsService, _server)
        };

        MainWindow = window;
        window.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_server is not null)
        {
            _server.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }

        base.OnExit(e);
    }
}
