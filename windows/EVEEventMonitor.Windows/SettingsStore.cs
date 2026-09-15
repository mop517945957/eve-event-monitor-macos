using System.Text.Json;

namespace EVEEventMonitor.Windows;

internal static class SettingsStore
{
    private static readonly string Root = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "EVEEventMonitor");

    private static readonly string SettingsPath = Path.Combine(Root, "settings.json");
    internal static string TemplatesDirectory => Path.Combine(Root, "Templates");

    public static AppConfig Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
                return JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(SettingsPath)) ?? new AppConfig();
        }
        catch
        {
            // A corrupt settings file should never prevent the app from starting.
        }

        return new AppConfig();
    }

    public static void Save(AppConfig config)
    {
        Directory.CreateDirectory(Root);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true }));
    }
}
