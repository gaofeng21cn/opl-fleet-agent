using CodexTPS.Core;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CodexTPS.WindowsApp;

internal sealed class SettingsForm : RoundedPopupForm
{
    private static readonly Color Background = Color.White;
    private static readonly Color Surface = Color.FromArgb(246, 246, 248);
    private static readonly Color Primary = Color.FromArgb(36, 36, 38);
    private static readonly Color Secondary = Color.FromArgb(128, 128, 132);
    private static readonly Color Border = Color.FromArgb(224, 224, 226);
    private static readonly Color Selection = Color.FromArgb(0, 122, 255);
    private static readonly Color Success = Color.FromArgb(52, 199, 89);
    private static readonly Color Warning = Color.FromArgb(255, 149, 0);
    private static readonly Color Failure = Color.FromArgb(255, 59, 48);

    private readonly TextBox codexHome = TextInput();
    private readonly ToggleSwitch ambientEnabled = new();
    private readonly ToggleSwitch autoDiscover = new();
    private readonly TextBox manualUrl = TextInput();
    private readonly TextBox token = TextInput(password: true);
    private readonly Button pasteToken = IconButton("\uE77F", "从剪贴板粘贴令牌并连接");
    private readonly Button? openPairing;
    private readonly TextBox preferredInstance = TextInput();
    private readonly TextBox machineId = TextInput();
    private readonly TextBox machineName = TextInput();
    private readonly ToggleSwitch petEnabled = new();
    private readonly ToggleSwitch startWithWindows = new();
    private readonly ToolTip toolTip = new();
    private readonly TableLayoutPanel content = new();
    private readonly Panel manualUrlRow = new();
    private readonly Label manualUrlLabel;
    private readonly int manualUrlRowIndex;
    private readonly int refreshSeconds;
    private readonly string devicePrivateKey;

    public SettingsForm(AppSettings settings, AmbientOpsConnectionStatus connection)
    {
        Text = "OPL Fleet Agent 设置";
        BackColor = Background;
        ForeColor = Primary;
        Font = new Font("Segoe UI Variable Text", 9f);
        ClientSize = new Size(520, 620);
        StartPosition = FormStartPosition.CenterParent;
        refreshSeconds = settings.RefreshSeconds;
        devicePrivateKey = settings.DevicePrivateKey;

        var executableIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        if (executableIcon is not null)
        {
            Icon = (Icon)executableIcon.Clone();
            executableIcon.Dispose();
        }

        codexHome.Text = settings.CodexHome;
        codexHome.PlaceholderText = "默认：%USERPROFILE%\\.codex";
        ambientEnabled.Checked = settings.AmbientEnabled;
        autoDiscover.Checked = settings.AutoDiscover;
        manualUrl.Text = settings.ManualUrl;
        manualUrl.PlaceholderText = "http://ambient-ops.local:8787";
        token.Text = settings.Token;
        token.PlaceholderText = "仅旧版 Ambient Ops 需要";
        preferredInstance.Text = settings.PreferredInstanceId;
        preferredInstance.PlaceholderText = "可选";
        machineId.Text = settings.MachineId;
        machineName.Text = settings.MachineName;
        petEnabled.Checked = settings.PetEnabled;
        startWithWindows.Checked = settings.StartWithWindows;

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 3,
            BackColor = Background,
            Margin = Padding.Empty,
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 64));
        Controls.Add(root);
        root.Controls.Add(BuildHeader(), 0, 0);

        content.Dock = DockStyle.Fill;
        content.AutoScroll = true;
        content.Padding = new Padding(24, 14, 24, 8);
        content.ColumnCount = 2;
        content.RowCount = 0;
        content.BackColor = Background;
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 128));
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.Controls.Add(content, 0, 1);

        AddSection("数据源");
        var browse = IconButton("\uE8B7", "选择 Codex home");
        browse.Click += (_, _) => BrowseCodexHome();
        var homePanel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            BackColor = Background,
        };
        homePanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        homePanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 44));
        codexHome.Dock = DockStyle.Fill;
        homePanel.Controls.Add(codexHome, 0, 0);
        homePanel.Controls.Add(browse, 1, 0);
        AddField("Codex home", homePanel);
        AddSeparator();

        AddSection("OPL Fleet Agent / Ambient Ops Gateway");
        AddToggle("发送聚合指标", ambientEnabled);
        AddToggle("自动发现", autoDiscover);
        AddConnection(connection);
        if (connection.ApprovalUri is not null)
        {
            openPairing = CommandButton("打开批准页", primary: true);
            openPairing.Click += (_, _) => OpenPairingPage(connection.ApprovalUri);
            AddField("安全配对", openPairing);
        }

        manualUrlRow.Dock = DockStyle.Fill;
        manualUrlRow.BackColor = Background;
        manualUrl.Dock = DockStyle.Fill;
        manualUrlRow.Controls.Add(manualUrl);
        manualUrlRowIndex = content.RowCount;
        manualUrlLabel = AddField("手动地址", manualUrlRow);
        var tokenPanel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            BackColor = Background,
        };
        tokenPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        tokenPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 44));
        token.Dock = DockStyle.Fill;
        pasteToken.Click += (_, _) => PasteTokenAndSave();
        toolTip.SetToolTip(pasteToken, "粘贴剪贴板中的令牌并立即连接");
        tokenPanel.Controls.Add(token, 0, 0);
        tokenPanel.Controls.Add(pasteToken, 1, 0);
        AddField("兼容令牌", tokenPanel);
        AddField("首选实例", preferredInstance);
        AddSeparator();

        AddSection("本机身份");
        AddField("Machine ID", machineId);
        AddField("Machine name", machineName);
        AddToggle("同步本机 Codex 宠物", petEnabled);
        AddSeparator();

        AddSection("系统");
        AddToggle("登录时启动", startWithWindows);
        AddWide(new Label
        {
            AutoSize = true,
            MaximumSize = new Size(510, 0),
            ForeColor = Secondary,
            BackColor = Background,
            Font = new Font("Microsoft YaHei UI", 8.5f),
            Text = "首次连接会自动打开 Ambient Ops 批准页，无需复制 NAS 密钥。本机私钥由 Windows DPAPI 加密；仅发送聚合指标、宠物元数据和本机 WebP 图集。",
            Margin = new Padding(0, 10, 0, 18),
        });

        autoDiscover.CheckedChanged += (_, _) => UpdateManualUrlVisibility();
        ambientEnabled.CheckedChanged += (_, _) => UpdateAmbientEnabledState();
        UpdateManualUrlVisibility();
        UpdateAmbientEnabledState();

        root.Controls.Add(BuildFooter(), 0, 2);
    }

    public AppSettings? ResultSettings { get; private set; }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            toolTip.Dispose();
        }
        base.Dispose(disposing);
    }

    private Control BuildHeader()
    {
        var panel = new Panel
        {
            Dock = DockStyle.Fill,
            BackColor = Background,
            Margin = Padding.Empty,
        };
        var header = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            BackColor = Background,
            Padding = new Padding(24, 0, 14, 0),
            Margin = Padding.Empty,
        };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 32));
        var title = new Label
        {
            Text = "OPL Fleet Agent 设置",
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            ForeColor = Primary,
            BackColor = Background,
            Font = new Font("Segoe UI Semibold", 12),
        };
        header.Controls.Add(title, 0, 0);
        var close = IconButton("\uE711", "关闭设置");
        close.Size = new Size(28, 28);
        close.Dock = DockStyle.None;
        close.Anchor = AnchorStyles.Right;
        close.DialogResult = DialogResult.Cancel;
        header.Controls.Add(close, 1, 0);
        panel.Controls.Add(header);
        panel.Controls.Add(new Panel
        {
            Dock = DockStyle.Bottom,
            Height = 1,
            BackColor = Border,
        });
        EnableWindowDrag(panel);
        EnableWindowDrag(header);
        EnableWindowDrag(title);
        return panel;
    }

    private Control BuildFooter()
    {
        var footer = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            BackColor = Background,
            Padding = new Padding(24, 10, 24, 10),
        };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        var cancel = CommandButton("取消", primary: false);
        cancel.DialogResult = DialogResult.Cancel;
        cancel.Anchor = AnchorStyles.Left;
        var save = CommandButton("保存", primary: true);
        save.Anchor = AnchorStyles.Right;
        save.Click += (_, _) => SaveSettings();
        footer.Controls.Add(cancel, 0, 0);
        footer.Controls.Add(save, 1, 0);
        AcceptButton = save;
        CancelButton = cancel;
        return footer;
    }

    private void AddSection(string title)
    {
        AddWide(new Label
        {
            Text = title,
            AutoSize = true,
            ForeColor = Primary,
            BackColor = Background,
            Font = new Font("Segoe UI Semibold", 11.5f),
            Margin = new Padding(0, 8, 0, 10),
        });
    }

    private Label AddField(string label, Control control)
    {
        var row = content.RowCount++;
        content.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
        var fieldLabel = FieldLabel(label);
        content.Controls.Add(fieldLabel, 0, row);
        control.Dock = DockStyle.Fill;
        control.Margin = new Padding(0, 5, 0, 7);
        content.Controls.Add(control, 1, row);
        return fieldLabel;
    }

    private void AddToggle(string label, ToggleSwitch toggle)
    {
        var row = content.RowCount++;
        content.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
        content.Controls.Add(FieldLabel(label), 0, row);
        toggle.Anchor = AnchorStyles.Right;
        toggle.Margin = new Padding(0, 8, 0, 8);
        content.Controls.Add(toggle, 1, row);
    }

    private void AddConnection(AmbientOpsConnectionStatus connection)
    {
        var row = content.RowCount++;
        content.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));
        var panel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = true,
            BackColor = Background,
            Margin = new Padding(0, 6, 0, 4),
        };
        var color = connection.Kind switch
        {
            AmbientOpsConnectionKind.Live => Success,
            AmbientOpsConnectionKind.Discovering or AmbientOpsConnectionKind.Ready or
                AmbientOpsConnectionKind.NeedsToken or AmbientOpsConnectionKind.Pairing or
                AmbientOpsConnectionKind.Pushing => Warning,
            AmbientOpsConnectionKind.Disabled => Secondary,
            _ => Failure,
        };
        panel.Controls.Add(new Label
        {
            Text = "●",
            AutoSize = true,
            ForeColor = color,
            Font = new Font("Microsoft YaHei UI", 9f),
            Margin = new Padding(0, 2, 7, 0),
        });
        panel.Controls.Add(new Label
        {
            Text = connection.Message,
            AutoSize = true,
            ForeColor = Primary,
                Font = new Font("Microsoft YaHei UI", 9f, FontStyle.Bold),
            Margin = new Padding(0, 2, 10, 0),
        });
        if (connection.Endpoint is not null)
        {
            panel.Controls.Add(new Label
            {
                Text = connection.Endpoint.AbsoluteUri,
                AutoSize = true,
                ForeColor = Secondary,
                Font = new Font("Cascadia Mono", 8.5f),
                Margin = new Padding(0, 3, 0, 0),
            });
        }
        content.SetColumnSpan(panel, 2);
        content.Controls.Add(panel, 0, row);
    }

    private void AddSeparator()
    {
        AddWide(new Panel
        {
            Dock = DockStyle.Top,
            Height = 1,
            BackColor = Border,
            Margin = new Padding(0, 8, 0, 8),
        }, 17);
    }

    private void AddWide(Control control, int height = 42)
    {
        var row = content.RowCount++;
        content.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        content.SetColumnSpan(control, 2);
        control.Dock = DockStyle.Fill;
        content.Controls.Add(control, 0, row);
    }

    private void SaveSettings()
    {
        try
        {
            _ = new AmbientOpsMachineIdentity(machineId.Text.Trim(), machineName.Text.Trim(), "Windows");
            if (ambientEnabled.Checked && !autoDiscover.Checked &&
                (!Uri.TryCreate(manualUrl.Text.Trim(), UriKind.Absolute, out var endpoint) ||
                 endpoint.Scheme is not ("http" or "https")))
            {
                throw new InvalidOperationException("请输入有效的 Ambient Ops HTTP(S) 地址。");
            }
            ResultSettings = new AppSettings
            {
                CodexHome = codexHome.Text.Trim(),
                AmbientEnabled = ambientEnabled.Checked,
                AutoDiscover = autoDiscover.Checked,
                ManualUrl = manualUrl.Text.Trim(),
                Token = token.Text,
                DevicePrivateKey = devicePrivateKey,
                PreferredInstanceId = preferredInstance.Text.Trim(),
                MachineId = machineId.Text.Trim(),
                MachineName = machineName.Text.Trim(),
                PetEnabled = petEnabled.Checked,
                StartWithWindows = startWithWindows.Checked,
                RefreshSeconds = refreshSeconds,
            };
            DialogResult = DialogResult.OK;
            Close();
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException)
        {
            MessageBox.Show(
                this,
                error.Message,
                "设置无效",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
    }

    private void PasteTokenAndSave()
    {
        try
        {
            var value = Clipboard.GetText(TextDataFormat.Text).Trim();
            if (value.Length < 16)
            {
                throw new InvalidOperationException("剪贴板中没有有效的 Ambient Ops 推送令牌。");
            }
            token.Text = value;
            SaveSettings();
        }
        catch (ExternalException error)
        {
            MessageBox.Show(
                this,
                error.Message,
                "无法读取剪贴板",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
        catch (InvalidOperationException error)
        {
            MessageBox.Show(
                this,
                error.Message,
                "未找到推送令牌",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
    }

    private static void OpenPairingPage(Uri uri)
    {
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri)
        {
            UseShellExecute = true,
        });
    }

    private void BrowseCodexHome()
    {
        using var dialog = new FolderBrowserDialog
        {
            Description = "选择包含 sessions 的 Codex home",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = false,
        };
        if (Directory.Exists(codexHome.Text))
        {
            dialog.SelectedPath = codexHome.Text;
        }
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            codexHome.Text = dialog.SelectedPath;
        }
    }

    private void UpdateManualUrlVisibility()
    {
        var visible = !autoDiscover.Checked;
        manualUrlLabel.Visible = visible;
        manualUrlRow.Visible = visible;
        content.RowStyles[manualUrlRowIndex].Height = visible ? 52 : 0;
        manualUrl.Enabled = ambientEnabled.Checked && !autoDiscover.Checked;
    }

    private void UpdateAmbientEnabledState()
    {
        autoDiscover.Enabled = ambientEnabled.Checked;
        token.Enabled = ambientEnabled.Checked;
        pasteToken.Enabled = ambientEnabled.Checked;
        if (openPairing is not null)
        {
            openPairing.Enabled = ambientEnabled.Checked;
        }
        preferredInstance.Enabled = ambientEnabled.Checked;
        petEnabled.Enabled = ambientEnabled.Checked;
        UpdateManualUrlVisibility();
    }

    private static Label FieldLabel(string text) => new()
    {
        Text = text,
        AutoSize = true,
        Anchor = AnchorStyles.Left,
        ForeColor = Secondary,
        BackColor = Background,
        Font = new Font("Microsoft YaHei UI", 9f),
        Margin = new Padding(0, 9, 12, 0),
    };

    private static TextBox TextInput(bool password = false) => new()
    {
        BorderStyle = BorderStyle.FixedSingle,
        BackColor = Surface,
        ForeColor = Primary,
        Font = new Font("Microsoft YaHei UI", 9f),
        UseSystemPasswordChar = password,
    };

    private static Button IconButton(string glyph, string accessibleName)
    {
        var button = new Button
        {
            Text = glyph,
            AccessibleName = accessibleName,
            Dock = DockStyle.Fill,
            FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe MDL2 Assets", 14),
            ForeColor = Secondary,
            BackColor = Surface,
            Cursor = Cursors.Hand,
            Margin = new Padding(6, 0, 0, 0),
        };
        button.FlatAppearance.BorderColor = Border;
        button.FlatAppearance.MouseOverBackColor = Color.FromArgb(236, 236, 238);
        return button;
    }

    private static Button CommandButton(string text, bool primary)
    {
        var button = new Button
        {
            Text = text,
            AutoSize = false,
            Size = new Size(96, 36),
            FlatStyle = FlatStyle.Flat,
            Font = new Font("Microsoft YaHei UI", 9f, FontStyle.Bold),
            ForeColor = primary ? Color.White : Primary,
            BackColor = primary ? Selection : Surface,
            Cursor = Cursors.Hand,
        };
        button.FlatAppearance.BorderColor = primary ? Selection : Border;
        button.FlatAppearance.MouseOverBackColor = primary
            ? Color.FromArgb(0, 108, 226)
            : Color.FromArgb(236, 236, 238);
        return button;
    }
}
