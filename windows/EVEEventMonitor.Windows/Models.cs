using System.Text.Json.Serialization;

namespace EVEEventMonitor.Windows;

internal enum CaptureMode
{
    Region,
    Window
}

internal sealed class NormalizedRect
{
    public double X { get; set; }
    public double Y { get; set; }
    public double Width { get; set; }
    public double Height { get; set; }

    public Rectangle ToRectangle(int width, int height)
    {
        var x = Math.Clamp((int)Math.Round(X * width), 0, Math.Max(0, width - 1));
        var y = Math.Clamp((int)Math.Round(Y * height), 0, Math.Max(0, height - 1));
        var w = Math.Clamp((int)Math.Round(Width * width), 1, Math.Max(1, width - x));
        var h = Math.Clamp((int)Math.Round(Height * height), 1, Math.Max(1, height - y));
        return new Rectangle(x, y, w, h);
    }

    public static NormalizedRect FromRectangle(Rectangle crop, Rectangle parent) => new()
    {
        X = (double)(crop.Left - parent.Left) / parent.Width,
        Y = (double)(crop.Top - parent.Top) / parent.Height,
        Width = (double)crop.Width / parent.Width,
        Height = (double)crop.Height / parent.Height
    };
}

internal sealed class AppConfig
{
    public CaptureMode CaptureMode { get; set; } = CaptureMode.Region;
    public Rectangle? ScreenRegion { get; set; }
    public string? WindowTitle { get; set; }
    public string? WindowProcessName { get; set; }
    public NormalizedRect? WindowCrop { get; set; }
    public List<int> ColorsArgb { get; set; } = [];
    public int ColorTolerance { get; set; } = 33;
    public int MinimumMatchingPixels { get; set; } = 20;
    public List<string> TemplatePaths { get; set; } = [];
    public double TemplateSimilarity { get; set; } = 0.85;
    public int IntervalMilliseconds { get; set; } = 200;
    public int RequiredHits { get; set; } = 2;
    public int RequiredMisses { get; set; } = 2;
    public string? AlarmSoundPath { get; set; }
}

internal sealed record WindowInfo(IntPtr Handle, string Title, string ProcessName, Rectangle Bounds)
{
    public override string ToString() => $"{Title}  ·  {ProcessName}";
}

internal sealed record DetectionResult(bool IsMatch, int MatchingPixels, string? MatchingColor, double TemplateSimilarity);
