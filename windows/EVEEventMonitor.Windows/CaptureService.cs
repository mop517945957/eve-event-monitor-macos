using System.Diagnostics;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

namespace EVEEventMonitor.Windows;

internal static class DpiAwareness
{
    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    public static void Enable()
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); }
        catch { /* Older Windows versions use the manifest fallback. */ }
    }
}

internal static class CaptureService
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out NativeRect rect);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")]
    internal static extern bool IsWindow(IntPtr hWnd);

    public static List<WindowInfo> GetWindows()
    {
        var result = new List<WindowInfo>();
        EnumWindows((handle, _) =>
        {
            if (!IsWindowVisible(handle)) return true;
            var length = GetWindowTextLength(handle);
            if (length == 0 || !GetWindowRect(handle, out var native)) return true;
            var bounds = Rectangle.FromLTRB(native.Left, native.Top, native.Right, native.Bottom);
            if (bounds.Width < 80 || bounds.Height < 60) return true;
            var text = new StringBuilder(length + 1);
            GetWindowText(handle, text, text.Capacity);
            GetWindowThreadProcessId(handle, out var pid);
            var processName = "Unknown";
            try { processName = Process.GetProcessById((int)pid).ProcessName; } catch { }
            result.Add(new WindowInfo(handle, text.ToString(), processName, bounds));
            return true;
        }, IntPtr.Zero);
        return result.OrderBy(x => x.ProcessName).ThenBy(x => x.Title).ToList();
    }

    public static WindowInfo? ResolveWindow(string? title, string? processName) =>
        GetWindows().FirstOrDefault(x =>
            string.Equals(x.ProcessName, processName, StringComparison.OrdinalIgnoreCase) &&
            string.Equals(x.Title, title, StringComparison.Ordinal));

    public static Rectangle? GetBounds(IntPtr handle)
    {
        if (!IsWindow(handle) || !GetWindowRect(handle, out var native)) return null;
        return Rectangle.FromLTRB(native.Left, native.Top, native.Right, native.Bottom);
    }

    public static Bitmap CaptureRegion(Rectangle bounds)
    {
        if (bounds.Width < 1 || bounds.Height < 1) throw new InvalidOperationException("监控区域无效。");
        var bitmap = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size, CopyPixelOperation.SourceCopy);
        return bitmap;
    }

    public static Bitmap CaptureWindow(IntPtr handle, NormalizedRect? crop)
    {
        var bounds = GetBounds(handle) ?? throw new InvalidOperationException("监控窗口已关闭，请重新选择。");
        using var full = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(full))
        {
            var hdc = graphics.GetHdc();
            try
            {
                if (!PrintWindow(handle, hdc, 2))
                    throw new InvalidOperationException("无法读取该窗口画面，请确认窗口没有最小化。");
            }
            finally { graphics.ReleaseHdc(hdc); }
        }

        var source = crop?.ToRectangle(full.Width, full.Height) ?? new Rectangle(Point.Empty, full.Size);
        return full.Clone(source, PixelFormat.Format32bppArgb);
    }
}
