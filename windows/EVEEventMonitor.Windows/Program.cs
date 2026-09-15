namespace EVEEventMonitor.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        DpiAwareness.Enable();
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
    }
}
