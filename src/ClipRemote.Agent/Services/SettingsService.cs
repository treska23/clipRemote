using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using ClipRemote.Agent.Models;

namespace ClipRemote.Agent.Services;

public sealed class SettingsService
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    public SettingsService()
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ClipRemote");

        Directory.CreateDirectory(directory);
        SettingsPath = Path.Combine(directory, "settings.json");
    }

    public string SettingsPath { get; }

    public AgentSettings Load()
    {
        AgentSettings settings;

        if (File.Exists(SettingsPath))
        {
            try
            {
                settings = JsonSerializer.Deserialize<AgentSettings>(File.ReadAllText(SettingsPath), JsonOptions)
                           ?? CreateDefaults();
            }
            catch
            {
                settings = CreateDefaults();
            }
        }
        else
        {
            settings = CreateDefaults();
        }

        var changed = false;

        if (string.IsNullOrWhiteSpace(settings.PairingToken))
        {
            settings.PairingToken = CreateToken();
            changed = true;
        }

        foreach (var action in DefaultActions())
        {
            if (!settings.Actions.ContainsKey(action.Key))
            {
                settings.Actions[action.Key] = action.Value;
                changed = true;
            }
        }

        if (changed || !File.Exists(SettingsPath))
        {
            Save(settings);
        }

        return settings;
    }

    public void Save(AgentSettings settings)
        => File.WriteAllText(SettingsPath, JsonSerializer.Serialize(settings, JsonOptions));

    private static AgentSettings CreateDefaults() => new()
    {
        Port = 5057,
        PairingToken = CreateToken(),
        Actions = DefaultActions()
    };

    private static Dictionary<string, string> DefaultActions() => new(StringComparer.OrdinalIgnoreCase)
    {
        ["undo"] = "CTRL+Z",
        ["redo"] = "CTRL+Y",
        ["playPause"] = "",
        ["previousFrame"] = "",
        ["nextFrame"] = "",
        ["newCel"] = "",
        ["duplicateCel"] = "",
        ["onionSkin"] = ""
    };

    private static string CreateToken()
    {
        var bytes = RandomNumberGenerator.GetBytes(18);
        return Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }
}
