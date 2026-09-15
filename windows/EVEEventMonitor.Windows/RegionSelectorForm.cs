namespace EVEEventMonitor.Windows;

internal sealed class RegionSelectorForm : Form
{
    private Point _start;
    private Point _current;
    private bool _dragging;
    public Rectangle SelectedScreenRectangle { get; private set; }

    private RegionSelectorForm(Rectangle bounds)
    {
        Bounds = bounds;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        ShowInTaskbar = false;
        BackColor = Color.Black;
        Opacity = 0.32;
        Cursor = Cursors.Cross;
        DoubleBuffered = true;
        KeyPreview = true;
    }

    public static Rectangle? SelectRegion(IWin32Window owner, Rectangle? limit = null)
    {
        using var selector = new RegionSelectorForm(limit ?? SystemInformation.VirtualScreen);
        return selector.ShowDialog(owner) == DialogResult.OK ? selector.SelectedScreenRectangle : null;
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Activate();
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        _start = e.Location;
        _current = e.Location;
        _dragging = true;
        Invalidate();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (!_dragging) return;
        _current = e.Location;
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (!_dragging || e.Button != MouseButtons.Left) return;
        _dragging = false;
        var local = Normalize(_start, e.Location);
        if (local.Width < 3 || local.Height < 3) return;
        SelectedScreenRectangle = new Rectangle(local.X + Left, local.Y + Top, local.Width, local.Height);
        DialogResult = DialogResult.OK;
        Close();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.KeyCode == Keys.Escape) { DialogResult = DialogResult.Cancel; Close(); }
        base.OnKeyDown(e);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (!_dragging) return;
        var rect = Normalize(_start, _current);
        using var fill = new SolidBrush(Color.FromArgb(90, Color.DodgerBlue));
        using var pen = new Pen(Color.DeepSkyBlue, 3);
        e.Graphics.FillRectangle(fill, rect);
        e.Graphics.DrawRectangle(pen, rect);
    }

    private static Rectangle Normalize(Point a, Point b) => Rectangle.FromLTRB(
        Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));
}
