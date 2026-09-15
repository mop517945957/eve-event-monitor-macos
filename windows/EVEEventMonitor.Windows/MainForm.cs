namespace EVEEventMonitor.Windows;

internal sealed class MainForm : Form
{
    private readonly AppConfig _config = SettingsStore.Load();
    private readonly AlarmPlayer _alarm = new();
    private readonly System.Windows.Forms.Timer _captureTimer = new();
    private readonly List<Bitmap> _templates = [];
    private readonly Label _status = new() { AutoSize = true, Text = "未运行", ForeColor = Color.DimGray };
    private readonly Label _source = new() { AutoSize = true, Text = "尚未选择监控区域或窗口" };
    private readonly Label _debug = new() { AutoSize = true, ForeColor = Color.DimGray };
    private readonly FlowLayoutPanel _colors = new() { AutoSize = true, WrapContents = true, Dock = DockStyle.Fill };
    private readonly ListBox _templateList = new() { Height = 90, Dock = DockStyle.Top };
    private readonly PictureBox _preview = new() { Width = 520, Height = 240, SizeMode = PictureBoxSizeMode.Zoom, BackColor = Color.FromArgb(28, 28, 28) };
    private readonly NumericUpDown _tolerance = NumberBox(0, 100, 33);
    private readonly NumericUpDown _minimumPixels = NumberBox(1, 100000, 20);
    private readonly NumericUpDown _similarity = NumberBox(50, 100, 85);
    private readonly NumericUpDown _hits = NumberBox(1, 20, 2);
    private readonly NumericUpDown _misses = NumberBox(1, 20, 2);
    private readonly ComboBox _interval = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 100 };
    private readonly Button _start = new() { Text = "开始监控", AutoSize = true, Height = 38 };
    private IntPtr _windowHandle;
    private bool _monitoring;
    private bool _processing;
    private int _hitFrames;
    private int _missFrames;

    public MainForm()
    {
        Text = "EVE 事件监测（Windows）";
        Width = 820;
        Height = 900;
        MinimumSize = new Size(720, 680);
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;

        _interval.Items.AddRange(new object[] { 50, 100, 200, 500 });
        BuildInterface();
        LoadConfigIntoControls();
        LoadTemplates();
        RefreshSourceLabel();

        _captureTimer.Tick += CaptureTick;
        FormClosing += (_, _) => { StopMonitoring(); SaveControls(); DisposeResources(); };
    }

    private void BuildInterface()
    {
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, AutoScroll = true, AutoSize = true, Padding = new Padding(20), ColumnCount = 1 };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.Controls.Add(Row(new Label { Text = "EVE 事件监测", Font = new Font(Font.FontFamily, 22, FontStyle.Bold), AutoSize = true }, _status));
        root.Controls.Add(new Label { Text = "Windows 本地屏幕与窗口事件监测", AutoSize = true, ForeColor = Color.DimGray });

        root.Controls.Add(Section("监控来源", _source,
            Row(ActionButton("选择屏幕区域", SelectScreenRegion), ActionButton("选择窗口", SelectWindow), ActionButton("选择窗口内区域", SelectWindowCrop))));

        root.Controls.Add(Section("实时预览", _preview));
        root.Controls.Add(Section("颜色规则", _colors,
            Row(ActionButton("＋ 添加颜色", AddColor), Field("颜色容差", _tolerance), Field("最小匹配像素", _minimumPixels))));

        root.Controls.Add(Section("固定样式 / 图标", _templateList,
            Row(ActionButton("＋ 截取模板", AddTemplate), ActionButton("删除选中模板", RemoveTemplate), Field("匹配度 %", _similarity))));

        root.Controls.Add(Section("检测设置",
            Row(Field("检测间隔 ms", _interval), Field("连续确认", _hits), Field("解除确认", _misses))));

        root.Controls.Add(Section("报警声音",
            Row(ActionButton("选择 WAV", ChooseSound), ActionButton("试听", () => _alarm.PlayOnce(_config.AlarmSoundPath)), ActionButton("恢复默认", ClearSound))));

        var stopAlarm = ActionButton("关闭报警", () => _alarm.Stop());
        _start.Click += (_, _) => { if (_monitoring) StopMonitoring(); else StartMonitoring(); };
        root.Controls.Add(_debug);
        root.Controls.Add(Row(stopAlarm, _start));
        Controls.Add(root);
    }

    private static NumericUpDown NumberBox(decimal min, decimal max, decimal value) => new()
    {
        Minimum = min, Maximum = max, Value = value, Width = 88
    };

    private static Button ActionButton(string text, Action action)
    {
        var button = new Button { Text = text, AutoSize = true };
        button.Click += (_, _) => action();
        return button;
    }

    private static Control Field(string label, Control control)
    {
        var panel = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        panel.Controls.Add(new Label { Text = label, AutoSize = true, Padding = new Padding(0, 6, 4, 0) });
        panel.Controls.Add(control);
        return panel;
    }

    private static FlowLayoutPanel Row(params Control[] controls)
    {
        var panel = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, WrapContents = true };
        panel.Controls.AddRange(controls);
        return panel;
    }

    private static GroupBox Section(string title, params Control[] controls)
    {
        var box = new GroupBox { Text = title, AutoSize = true, Dock = DockStyle.Top, Padding = new Padding(12) };
        var panel = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false };
        foreach (var control in controls) { control.Margin = new Padding(4, 5, 4, 5); panel.Controls.Add(control); }
        box.Controls.Add(panel);
        return box;
    }

    private void LoadConfigIntoControls()
    {
        _tolerance.Value = Math.Clamp(_config.ColorTolerance, 0, 100);
        _minimumPixels.Value = Math.Clamp(_config.MinimumMatchingPixels, 1, 100000);
        _similarity.Value = Math.Clamp((decimal)(_config.TemplateSimilarity * 100), 50, 100);
        _hits.Value = Math.Clamp(_config.RequiredHits, 1, 20);
        _misses.Value = Math.Clamp(_config.RequiredMisses, 1, 20);
        _interval.SelectedItem = _interval.Items.Cast<int>().Contains(_config.IntervalMilliseconds) ? _config.IntervalMilliseconds : 200;
        RefreshColors();
        RefreshTemplateList();
    }

    private void SaveControls()
    {
        _config.ColorTolerance = (int)_tolerance.Value;
        _config.MinimumMatchingPixels = (int)_minimumPixels.Value;
        _config.TemplateSimilarity = (double)_similarity.Value / 100;
        _config.RequiredHits = (int)_hits.Value;
        _config.RequiredMisses = (int)_misses.Value;
        _config.IntervalMilliseconds = _interval.SelectedItem is int value ? value : 200;
        SettingsStore.Save(_config);
    }

    private void SelectScreenRegion()
    {
        Hide();
        var region = RegionSelectorForm.SelectRegion(this);
        Show(); Activate();
        if (region is null) return;
        _config.CaptureMode = CaptureMode.Region;
        _config.ScreenRegion = region;
        SaveControls();
        RefreshSourceLabel();
        UpdatePreview(CaptureService.CaptureRegion(region.Value));
    }

    private void SelectWindow()
    {
        var windows = CaptureService.GetWindows().Where(x => x.Handle != Handle).ToList();
        using var picker = new WindowPickerForm(windows);
        if (picker.ShowDialog(this) != DialogResult.OK || picker.SelectedWindow is not { } selected) return;
        _windowHandle = selected.Handle;
        _config.CaptureMode = CaptureMode.Window;
        _config.WindowTitle = selected.Title;
        _config.WindowProcessName = selected.ProcessName;
        _config.WindowCrop = null;
        SaveControls();
        RefreshSourceLabel();
    }

    private void SelectWindowCrop()
    {
        if (!ResolveSelectedWindow() || CaptureService.GetBounds(_windowHandle) is not { } bounds)
        {
            ShowError("请先选择一个仍在运行的窗口。");
            return;
        }
        Hide();
        var crop = RegionSelectorForm.SelectRegion(this, bounds);
        Show(); Activate();
        if (crop is null) return;
        _config.WindowCrop = NormalizedRect.FromRectangle(crop.Value, bounds);
        SaveControls();
        RefreshSourceLabel();
        UpdatePreview(CaptureService.CaptureWindow(_windowHandle, _config.WindowCrop));
    }

    private void AddColor()
    {
        using var dialog = new ColorDialog { FullOpen = true };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        if (!_config.ColorsArgb.Contains(dialog.Color.ToArgb())) _config.ColorsArgb.Add(dialog.Color.ToArgb());
        SaveControls();
        RefreshColors();
    }

    private void RefreshColors()
    {
        _colors.Controls.Clear();
        foreach (var argb in _config.ColorsArgb.ToList())
        {
            var color = Color.FromArgb(argb);
            var button = new Button { Text = $"● #{color.R:X2}{color.G:X2}{color.B:X2}  ×", AutoSize = true, ForeColor = color };
            button.Click += (_, _) => { _config.ColorsArgb.Remove(argb); SaveControls(); RefreshColors(); };
            _colors.Controls.Add(button);
        }
    }

    private void AddTemplate()
    {
        Hide();
        var region = RegionSelectorForm.SelectRegion(this);
        Show(); Activate();
        if (region is null) return;
        Directory.CreateDirectory(SettingsStore.TemplatesDirectory);
        var path = Path.Combine(SettingsStore.TemplatesDirectory, $"template-{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}.png");
        using (var bitmap = CaptureService.CaptureRegion(region.Value)) bitmap.Save(path);
        _config.TemplatePaths.Add(path);
        SaveControls();
        LoadTemplates();
    }

    private void RemoveTemplate()
    {
        var index = _templateList.SelectedIndex;
        if (index < 0 || index >= _config.TemplatePaths.Count) return;
        var path = _config.TemplatePaths[index];
        _config.TemplatePaths.RemoveAt(index);
        try { File.Delete(path); } catch { }
        SaveControls();
        LoadTemplates();
    }

    private void LoadTemplates()
    {
        foreach (var template in _templates) template.Dispose();
        _templates.Clear();
        _config.TemplatePaths.RemoveAll(path => !File.Exists(path));
        foreach (var path in _config.TemplatePaths)
        {
            using var source = Image.FromFile(path);
            _templates.Add(new Bitmap(source));
        }
        RefreshTemplateList();
    }

    private void RefreshTemplateList()
    {
        _templateList.DataSource = null;
        _templateList.DataSource = _config.TemplatePaths.Select(Path.GetFileName).ToList();
    }

    private void ChooseSound()
    {
        using var dialog = new OpenFileDialog { Filter = "WAV 音频|*.wav", CheckFileExists = true };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        _config.AlarmSoundPath = dialog.FileName;
        SaveControls();
    }

    private void ClearSound() { _config.AlarmSoundPath = null; SaveControls(); }

    private void StartMonitoring()
    {
        SaveControls();
        if (_config.CaptureMode == CaptureMode.Region && _config.ScreenRegion is null)
        {
            ShowError("请先选择屏幕区域。"); return;
        }
        if (_config.CaptureMode == CaptureMode.Window && (!ResolveSelectedWindow() || _config.WindowCrop is null))
        {
            ShowError("请先选择窗口和窗口内区域。"); return;
        }
        if (_config.ColorsArgb.Count == 0 && _templates.Count == 0)
        {
            ShowError("请至少添加一种颜色或一个图像模板。"); return;
        }
        _monitoring = true;
        _hitFrames = _missFrames = 0;
        _captureTimer.Interval = _config.IntervalMilliseconds;
        _captureTimer.Start();
        _status.Text = "正在监控";
        _status.ForeColor = Color.ForestGreen;
        _start.Text = "停止监控";
        CaptureTick(this, EventArgs.Empty);
    }

    private void StopMonitoring()
    {
        _monitoring = false;
        _captureTimer.Stop();
        _alarm.Stop();
        _status.Text = "未运行";
        _status.ForeColor = Color.DimGray;
        _start.Text = "开始监控";
        _hitFrames = _missFrames = 0;
    }

    private async void CaptureTick(object? sender, EventArgs e)
    {
        if (!_monitoring || _processing) return;
        _processing = true;
        try
        {
            using var frame = CaptureCurrent();
            var preview = new Bitmap(frame);
            var colors = _config.ColorsArgb.Select(Color.FromArgb).ToList();
            var result = await Task.Run(() => DetectionService.Detect(frame, colors, _config.ColorTolerance,
                _config.MinimumMatchingPixels, _templates, _config.TemplateSimilarity));
            UpdatePreview(preview);
            Advance(result);
            _debug.Text = $"匹配像素：{result.MatchingPixels}   颜色：{result.MatchingColor ?? "—"}   模板：{result.TemplateSimilarity:P0}";
        }
        catch (Exception ex)
        {
            StopMonitoring();
            ShowError(ex.Message);
        }
        finally { _processing = false; }
    }

    private Bitmap CaptureCurrent()
    {
        if (_config.CaptureMode == CaptureMode.Region && _config.ScreenRegion is { } region)
            return CaptureService.CaptureRegion(region);
        if (!ResolveSelectedWindow()) throw new InvalidOperationException("监控窗口已关闭，请重新选择。");
        return CaptureService.CaptureWindow(_windowHandle, _config.WindowCrop);
    }

    private void Advance(DetectionResult result)
    {
        if (result.IsMatch)
        {
            _hitFrames++;
            _missFrames = 0;
            if (_hitFrames >= _config.RequiredHits && _status.Text != "已触发报警")
            {
                _status.Text = "已触发报警";
                _status.ForeColor = Color.Red;
                _alarm.Start(_config.AlarmSoundPath);
            }
        }
        else
        {
            _missFrames++;
            _hitFrames = 0;
            if (_status.Text == "已触发报警" && _missFrames >= _config.RequiredMisses)
            {
                _alarm.Stop();
                _status.Text = "正在监控";
                _status.ForeColor = Color.ForestGreen;
            }
        }
    }

    private bool ResolveSelectedWindow()
    {
        if (_windowHandle != IntPtr.Zero && CaptureService.IsWindow(_windowHandle)) return true;
        var resolved = CaptureService.ResolveWindow(_config.WindowTitle, _config.WindowProcessName);
        if (resolved is null) return false;
        _windowHandle = resolved.Handle;
        return true;
    }

    private void RefreshSourceLabel()
    {
        _source.Text = _config.CaptureMode switch
        {
            CaptureMode.Region when _config.ScreenRegion is { } region => $"屏幕区域：{region.Width} × {region.Height}，位置 ({region.X}, {region.Y})",
            CaptureMode.Window when !string.IsNullOrWhiteSpace(_config.WindowTitle) => $"窗口：{_config.WindowTitle} · {(_config.WindowCrop is null ? "尚未选择窗口内区域" : "已选择窗口内区域")}",
            _ => "尚未选择监控区域或窗口"
        };
    }

    private void UpdatePreview(Bitmap bitmap)
    {
        var old = _preview.Image;
        _preview.Image = bitmap;
        old?.Dispose();
    }

    private void ShowError(string message) => MessageBox.Show(this, message, "EVE 事件监测", MessageBoxButtons.OK, MessageBoxIcon.Warning);

    private void DisposeResources()
    {
        _captureTimer.Dispose();
        _alarm.Dispose();
        _preview.Image?.Dispose();
        foreach (var template in _templates) template.Dispose();
    }
}
