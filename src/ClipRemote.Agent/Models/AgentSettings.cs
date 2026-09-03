namespace ClipRemote.Agent.Models;

public sealed class AgentSettings
{
    public int Port { get; set; } = 5057;
    public string PairingToken { get; set; } = string.Empty;
    public Dictionary<string, string> Actions { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}
