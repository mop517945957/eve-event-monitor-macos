using System.Drawing.Imaging;
using System.Media;
using System.Runtime.InteropServices;

namespace EVEEventMonitor.Windows;

internal static class DetectionService
{
    private sealed record PixelBuffer(byte[] Bytes, int Width, int Height, int Stride);

    public static DetectionResult Detect(Bitmap source, IReadOnlyList<Color> colors, int tolerance,
        int minimumPixels, IReadOnlyList<Bitmap> templates, double templateThreshold)
    {
        var sourcePixels = Read(source);
        var counts = new int[colors.Count];
        var toleranceSquared = tolerance * tolerance;
        for (var y = 0; y < sourcePixels.Height; y++)
        {
            var row = y * sourcePixels.Stride;
            for (var x = 0; x < sourcePixels.Width; x++)
            {
                var offset = row + x * 4;
                var b = sourcePixels.Bytes[offset];
                var g = sourcePixels.Bytes[offset + 1];
                var r = sourcePixels.Bytes[offset + 2];
                for (var i = 0; i < colors.Count; i++)
                {
                    var dr = r - colors[i].R;
                    var dg = g - colors[i].G;
                    var db = b - colors[i].B;
                    if (dr * dr + dg * dg + db * db <= toleranceSquared) { counts[i]++; break; }
                }
            }
        }

        var maxPixels = counts.Length == 0 ? 0 : counts.Max();
        var colorIndex = counts.Length == 0 ? -1 : Array.IndexOf(counts, maxPixels);
        var matchedColor = colorIndex >= 0 && maxPixels >= minimumPixels
            ? $"#{colors[colorIndex].R:X2}{colors[colorIndex].G:X2}{colors[colorIndex].B:X2}"
            : null;
        var bestTemplate = 0.0;
        foreach (var template in templates)
        {
            bestTemplate = Math.Max(bestTemplate, BestSimilarity(Read(template), sourcePixels, templateThreshold));
            if (bestTemplate >= templateThreshold) break;
        }

        return new DetectionResult(matchedColor is not null || bestTemplate >= templateThreshold,
            maxPixels, matchedColor, bestTemplate);
    }

    private static PixelBuffer Read(Bitmap bitmap)
    {
        var converted = bitmap.PixelFormat == PixelFormat.Format32bppArgb
            ? bitmap
            : bitmap.Clone(new Rectangle(Point.Empty, bitmap.Size), PixelFormat.Format32bppArgb);
        try
        {
            var rect = new Rectangle(Point.Empty, converted.Size);
            var data = converted.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                var bytes = new byte[Math.Abs(data.Stride) * data.Height];
                Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
                return new PixelBuffer(bytes, data.Width, data.Height, Math.Abs(data.Stride));
            }
            finally { converted.UnlockBits(data); }
        }
        finally { if (!ReferenceEquals(converted, bitmap)) converted.Dispose(); }
    }

    private static double BestSimilarity(PixelBuffer template, PixelBuffer source, double threshold)
    {
        if (template.Width > source.Width || template.Height > source.Height) return 0;
        var step = Math.Max(1, Math.Min(template.Width, template.Height) / 14);
        var quickStep = Math.Max(1, step * 3);
        var requiredQuick = threshold * 0.82;
        var best = 0.0;
        for (var y = 0; y <= source.Height - template.Height; y += 2)
        for (var x = 0; x <= source.Width - template.Width; x += 2)
        {
            double quickDiff = 0;
            var quickCount = 0;
            for (var ty = 0; ty < template.Height; ty += quickStep)
            for (var tx = 0; tx < template.Width; tx += quickStep)
            {
                quickDiff += PixelDifference(template, tx, ty, source, x + tx, y + ty);
                quickCount += 3;
            }
            if (quickCount == 0 || 1 - quickDiff / (quickCount * 255.0) < requiredQuick) continue;

            double diff = 0;
            var count = 0;
            for (var ty = 0; ty < template.Height; ty += step)
            for (var tx = 0; tx < template.Width; tx += step)
            {
                diff += PixelDifference(template, tx, ty, source, x + tx, y + ty);
                count += 3;
            }
            best = Math.Max(best, 1 - diff / (count * 255.0));
            if (best >= threshold) return best;
        }
        return best;
    }

    private static int PixelDifference(PixelBuffer a, int ax, int ay, PixelBuffer b, int bx, int by)
    {
        var ai = ay * a.Stride + ax * 4;
        var bi = by * b.Stride + bx * 4;
        return Math.Abs(a.Bytes[ai] - b.Bytes[bi]) +
               Math.Abs(a.Bytes[ai + 1] - b.Bytes[bi + 1]) +
               Math.Abs(a.Bytes[ai + 2] - b.Bytes[bi + 2]);
    }
}

internal sealed class AlarmPlayer : IDisposable
{
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 1000 };
    private SoundPlayer? _player;
    private string? _path;

    public AlarmPlayer() => _timer.Tick += (_, _) => PlayOnce();

    public void Start(string? path)
    {
        _path = path;
        PlayOnce();
        _timer.Start();
    }

    public void Stop()
    {
        _timer.Stop();
        _player?.Stop();
    }

    public void PlayOnce(string? path = null)
    {
        var chosen = path ?? _path;
        if (!string.IsNullOrWhiteSpace(chosen) && File.Exists(chosen))
        {
            _player?.Dispose();
            _player = new SoundPlayer(chosen);
            _player.Play();
        }
        else SystemSounds.Exclamation.Play();
    }

    public void Dispose() { Stop(); _timer.Dispose(); _player?.Dispose(); }
}
