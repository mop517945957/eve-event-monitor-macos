namespace EVEEventMonitor.Windows;

internal sealed class WindowPickerForm : Form
{
    private readonly ListBox _windows = new() { Dock = DockStyle.Fill };
    public WindowInfo? SelectedWindow => _windows.SelectedItem as WindowInfo;

    public WindowPickerForm(IReadOnlyList<WindowInfo> windows)
    {
        Text = "选择监控窗口";
        Width = 720;
        Height = 520;
        StartPosition = FormStartPosition.CenterParent;
        _windows.DataSource = windows.ToList();
        _windows.DoubleClick += (_, _) => Accept();
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 52, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(8) };
        var ok = new Button { Text = "选择", AutoSize = true };
        var cancel = new Button { Text = "取消", AutoSize = true, DialogResult = DialogResult.Cancel };
        ok.Click += (_, _) => Accept();
        buttons.Controls.Add(ok);
        buttons.Controls.Add(cancel);
        Controls.Add(_windows);
        Controls.Add(buttons);
        AcceptButton = ok;
        CancelButton = cancel;
    }

    private void Accept()
    {
        if (SelectedWindow is null) return;
        DialogResult = DialogResult.OK;
        Close();
    }
}
