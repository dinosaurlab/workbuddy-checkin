using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("WorkBuddy 自动签到")]
[assembly: AssemblyProduct("WorkBuddy 自动签到")]
[assembly: AssemblyDescription("WorkBuddy 每日自动签到小工具（OCR 自动签到）")]
[assembly: AssemblyVersion("1.0.1.0")]
[assembly: AssemblyFileVersion("1.0.1.0")]
[assembly: AssemblyInformationalVersion("1.0.1")]

namespace WorkBuddyApp
{
    public class Config
    {
        public string Time { get; set; }
        public bool Enabled { get; set; }
        public bool AutoStart { get; set; }
        public string Mode { get; set; }
        public bool AutoSwitch { get; set; }
        public string LastRunDate { get; set; }
        public string LastScheduledDate { get; set; }
        public string NextRunAt { get; set; }
        public string LastResult { get; set; }

        public Config()
        {
            Time = "09:05";
            Enabled = true;
            AutoStart = false;
            Mode = "desktop";
            AutoSwitch = true;
            LastRunDate = "";
            LastScheduledDate = "";
            NextRunAt = "";
            LastResult = "尚未运行";
        }
    }

    internal static class Program
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        private static string configFile;
        private static string enginePath;
        private static string appDir;
        private static bool startMinimized;

        private static readonly Config config = new Config();
        private static bool running;
        private static bool realExit;
        private static Process engineProc;

        private static Form form;
        private static DateTimePicker dtp;
        private static CheckBox chkEnabled;
        private static CheckBox chkAutoStart;
        private static Label statusLabel;
        private static NotifyIcon notify;
        private static float dpiScale = 1f;
        private static System.Windows.Forms.Timer scheduleTimer;
        private static System.Windows.Forms.Timer pollTimer;
        private static long logStartPos;
        private static bool scheduledRun;

        [STAThread]
        private static void Main(string[] args)
        {
            try { SetProcessDPIAware(); } catch { }
            try
            {
                using (var g = System.Drawing.Graphics.FromHwnd(IntPtr.Zero))
                {
                    dpiScale = g.DpiX / 96f;
                }
            }
            catch { }

            ParseArgs(args);
            appDir = Path.GetDirectoryName(Application.ExecutablePath);
            if (string.IsNullOrEmpty(configFile)) configFile = Path.Combine(appDir, "workbuddy-app-config.json");
            if (string.IsNullOrEmpty(enginePath)) enginePath = Path.Combine(appDir, "WorkBuddy-AutoCheckin.ps1");

            bool createdNew;
            using (var mutex = new Mutex(true, "Local\\WorkBuddyAutoCheckinAppNative", out createdNew))
            {
                if (!createdNew) return;

                LoadConfig();
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                BuildUi();
                UpdateStatus();
                ScheduleTick();
                scheduleTimer.Start();
                Application.Run(form);
                mutex.ReleaseMutex();
            }
        }

        private static void ParseArgs(string[] args)
        {
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i];
                if (a.Equals("-StartMinimized", StringComparison.OrdinalIgnoreCase))
                {
                    startMinimized = true;
                }
                else if (a.Equals("-ConfigFile", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    configFile = args[++i];
                }
                else if (a.Equals("-EnginePath", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    enginePath = args[++i];
                }
            }
        }

        private static void LoadConfig()
        {
            try
            {
                if (!File.Exists(configFile)) return;
                string json = File.ReadAllText(configFile, Encoding.UTF8);
                Config c = new JavaScriptSerializer().Deserialize<Config>(json);
                if (c == null) return;
                if (!string.IsNullOrEmpty(c.Time)) config.Time = c.Time;
                config.Enabled = c.Enabled;
                config.AutoStart = c.AutoStart;
                if (c.Mode == "web" || c.Mode == "desktop") config.Mode = c.Mode;
                config.AutoSwitch = c.AutoSwitch;
                if (c.LastRunDate != null) config.LastRunDate = c.LastRunDate;
                if (c.LastScheduledDate != null) config.LastScheduledDate = c.LastScheduledDate;
                if (c.NextRunAt != null) config.NextRunAt = c.NextRunAt;
                if (c.LastResult != null) config.LastResult = c.LastResult;
                if (string.IsNullOrEmpty(config.NextRunAt))
                {
                    config.NextRunAt = ComputeNextRunAt(config.Time);
                }
            }
            catch { }
        }

        private static void SaveConfig()
        {
            try
            {
                string json = new JavaScriptSerializer().Serialize(config);
                File.WriteAllText(configFile, json, Encoding.UTF8);
            }
            catch { }
        }

        private static int S(int v)
        {
            return (int)Math.Round(v * dpiScale);
        }

        private static Button MakeButton(string text, Color back, Color hover, EventHandler onClick)
        {
            var b = new Button();
            b.Text = text;
            b.Font = new Font("Microsoft YaHei UI", 10.5f, FontStyle.Bold);
            b.FlatStyle = FlatStyle.Flat;
            b.FlatAppearance.BorderSize = 0;
            b.BackColor = back;
            b.FlatAppearance.MouseOverBackColor = hover;
            b.ForeColor = Color.White;
            b.Cursor = Cursors.Hand;
            b.Click += onClick;
            return b;
        }

        private static Panel MakeCard(int x, int y, int w, int h, string title)
        {
            var p = new Panel();
            p.Location = new Point(S(x), S(y));
            p.Size = new Size(S(w), S(h));
            p.BackColor = Color.White;
            p.Paint += (s, e) => ControlPaint.DrawBorder(e.Graphics, p.ClientRectangle,
                Color.FromArgb(229, 231, 235), ButtonBorderStyle.Solid);
            var t = new Label();
            t.Text = title;
            t.Font = new Font("Microsoft YaHei UI", 10.5f, FontStyle.Bold);
            t.ForeColor = Color.FromArgb(17, 24, 39);
            t.Location = new Point(S(16), S(10));
            t.Size = new Size(S(80), S(24));
            p.Controls.Add(t);
            return p;
        }

        private static void BuildUi()
        {
            form = new Form();
            form.Text = "WorkBuddy 自动签到";
            form.Icon = LoadAppIcon();
            form.AutoScaleMode = AutoScaleMode.None;
            form.ClientSize = new Size(S(400), S(420));
            form.FormBorderStyle = FormBorderStyle.FixedSingle;
            form.MaximizeBox = false;
            form.StartPosition = FormStartPosition.CenterScreen;
            form.BackColor = Color.FromArgb(243, 244, 246);
            form.Font = new Font("Microsoft YaHei UI", 9.5f);

            // 顶部深色标题栏
            var header = new Panel();
            header.Location = new Point(0, 0);
            header.Size = new Size(S(400), S(72));
            header.BackColor = Color.FromArgb(17, 24, 39);
            header.Dock = DockStyle.Top;

            var picIcon = new PictureBox();
            picIcon.Location = new Point(S(16), S(16));
            picIcon.Size = new Size(S(40), S(40));
            picIcon.SizeMode = PictureBoxSizeMode.Zoom;
            picIcon.Image = LoadAppIcon().ToBitmap();

            var lblTitle = new Label();
            lblTitle.Text = "WorkBuddy 自动签到";
            lblTitle.Font = new Font("Microsoft YaHei UI", 15f, FontStyle.Bold);
            lblTitle.ForeColor = Color.White;
            lblTitle.Location = new Point(S(70), S(12));
            lblTitle.Size = new Size(S(320), S(30));

            var lblSub = new Label();
            lblSub.Text = "workbuddy账号已登录时可正常签到";
            lblSub.Font = new Font("Microsoft YaHei UI", 9f);
            lblSub.ForeColor = Color.FromArgb(156, 163, 175);
            lblSub.Location = new Point(S(70), S(44));
            lblSub.Size = new Size(S(320), S(20));

            header.Controls.AddRange(new Control[] { picIcon, lblTitle, lblSub });
            form.Controls.Add(header);

            // 设置卡片
            var cardSettings = MakeCard(16, 84, 368, 112, "设置");
            form.Controls.Add(cardSettings);

            var lblTime = new Label();
            lblTime.Text = "签到时间";
            lblTime.ForeColor = Color.FromArgb(55, 65, 81);
            lblTime.Location = new Point(S(16), S(38));
            lblTime.Size = new Size(S(90), S(22));

            dtp = new DateTimePicker();
            dtp.Format = DateTimePickerFormat.Time;
            dtp.ShowUpDown = true;
            dtp.Location = new Point(S(114), S(34));
            dtp.Size = new Size(S(110), S(25));
            try { dtp.Value = DateTime.Parse(config.Time); }
            catch { dtp.Value = DateTime.Parse("09:05"); }

            chkEnabled = new CheckBox();
            chkEnabled.Text = "启用自动签到";
            chkEnabled.ForeColor = Color.FromArgb(55, 65, 81);
            chkEnabled.Location = new Point(S(232), S(36));
            chkEnabled.Size = new Size(S(128), S(22));
            chkEnabled.Checked = config.Enabled;

            chkAutoStart = new CheckBox();
            chkAutoStart.Text = "开机自动启动（最小化到托盘）";
            chkAutoStart.ForeColor = Color.FromArgb(55, 65, 81);
            chkAutoStart.Location = new Point(S(16), S(72));
            chkAutoStart.Size = new Size(S(336), S(22));
            chkAutoStart.Checked = config.AutoStart;

            cardSettings.Controls.AddRange(new Control[] { lblTime, dtp, chkEnabled, chkAutoStart });

            // 状态卡片
            var cardStatus = MakeCard(16, 204, 368, 128, "状态");
            form.Controls.Add(cardStatus);

            statusLabel = new Label();
            statusLabel.ForeColor = Color.FromArgb(55, 65, 81);
            statusLabel.Location = new Point(S(16), S(38));
            statusLabel.Size = new Size(S(336), S(84));
            cardStatus.Controls.Add(statusLabel);

            // 底部按钮
            var btnRunNow = MakeButton("立即签到", Color.FromArgb(37, 99, 235), Color.FromArgb(29, 78, 216), (s, e) => StartEngine());
            btnRunNow.Location = new Point(S(16), S(344));
            btnRunNow.Size = new Size(S(114), S(40));

            var btnSave = MakeButton("保存设置", Color.FromArgb(16, 185, 129), Color.FromArgb(5, 150, 105), (s, e) =>
            {
                config.Time = dtp.Value.ToString("HH:mm");
                config.LastScheduledDate = "";
                config.NextRunAt = ComputeNextRunAt(config.Time);
                SaveConfig();
                UpdateStatus();
                AppendLogLine("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "][INFO] 已重新设置定时签到：每天 " + config.Time + "（下次触发：" + GetNextRunText() + "）");
                MessageBox.Show("设置已保存，每天 " + config.Time + " 自动签到。\r\n下次触发：" + GetNextRunText(),
                    "WorkBuddy 自动签到", MessageBoxButtons.OK, MessageBoxIcon.Information);
            });
            btnSave.Location = new Point(S(143), S(344));
            btnSave.Size = new Size(S(114), S(40));

            var btnExit = MakeButton("退出", Color.FromArgb(107, 114, 128), Color.FromArgb(75, 85, 99), (s, e) => ExitApp());
            btnExit.Location = new Point(S(270), S(344));
            btnExit.Size = new Size(S(114), S(40));

            var lblFooter = new Label();
            lblFooter.Text = "到点自动签到，关闭窗口会最小化到托盘";
            lblFooter.ForeColor = Color.FromArgb(156, 163, 175);
            lblFooter.Font = new Font("Microsoft YaHei UI", 8.5f);
            lblFooter.Location = new Point(S(16), S(392));
            lblFooter.Size = new Size(S(368), S(18));
            lblFooter.TextAlign = ContentAlignment.MiddleCenter;

            form.Controls.AddRange(new Control[] { btnRunNow, btnSave, btnExit, lblFooter });

            notify = new NotifyIcon();
            notify.Icon = LoadAppIcon();
            notify.Text = "WorkBuddy 自动签到 v1.01";
            notify.Visible = true;

            var trayMenu = new ContextMenuStrip();
            trayMenu.Items.Add("打开主界面", null, (s, e) => ShowWindow());
            trayMenu.Items.Add("立即签到", null, (s, e) => StartEngine());
            trayMenu.Items.Add(new ToolStripSeparator());
            trayMenu.Items.Add("退出", null, (s, e) => ExitApp());
            notify.ContextMenuStrip = trayMenu;
            notify.DoubleClick += (s, e) => ShowWindow();

            pollTimer = new System.Windows.Forms.Timer();
            pollTimer.Interval = 2000;
            pollTimer.Tick += (s, e) => PollTick();

            scheduleTimer = new System.Windows.Forms.Timer();
            scheduleTimer.Interval = 30000;
            scheduleTimer.Tick += (s, e) => ScheduleTick();

            chkEnabled.CheckedChanged += (s, e) =>
            {
                config.Enabled = chkEnabled.Checked;
                SaveConfig();
                UpdateStatus();
            };

            chkAutoStart.CheckedChanged += (s, e) =>
            {
                config.AutoStart = chkAutoStart.Checked;
                SetAutoStart(config.AutoStart);
                SaveConfig();
            };

            form.FormClosing += (s, e) =>
            {
                if (!realExit)
                {
                    e.Cancel = true;
                    form.Hide();
                    notify.ShowBalloonTip(3000, "WorkBuddy 自动签到", "已最小化到托盘，双击图标可恢复。", ToolTipIcon.Info);
                }
            };

            form.Shown += (s, e) =>
            {
                if (startMinimized)
                {
                    form.Hide();
                    notify.ShowBalloonTip(3000, "WorkBuddy 自动签到", "已在后台运行，双击托盘图标可打开。", ToolTipIcon.Info);
                }
                UpdateStatus();
                ScheduleTick();
            };
        }

        private static void ShowWindow()
        {
            form.Show();
            form.WindowState = FormWindowState.Normal;
            form.Activate();
        }

        private static void ExitApp()
        {
            realExit = true;
            SaveConfig();
            try { notify.Visible = false; notify.Dispose(); } catch { }
            form.Close();
            Application.Exit();
        }

        private static void UpdateStatus()
        {
            string nextStr = GetNextRunText();
            string runDate = string.IsNullOrEmpty(config.LastRunDate) ? "从未" : config.LastRunDate;
            statusLabel.Text = "签到方式：桌面端\r\n下次签到：" + nextStr + "\r\n上次运行：" + runDate + "\r\n上次结果：" + config.LastResult;
        }

        private static string GetNextRunText()
        {
            if (!config.Enabled) return "（已暂停）";
            if (!string.IsNullOrEmpty(config.NextRunAt))
            {
                DateTime t;
                if (DateTime.TryParse(config.NextRunAt, out t)) return t.ToString("yyyy-MM-dd HH:mm");
            }
            return "（未设置）";
        }

        private static string ComputeNextRunAt(string time)
        {
            try
            {
                DateTime target = DateTime.Parse(time);
                DateTime todayTarget = DateTime.Today + target.TimeOfDay;
                DateTime next = DateTime.Now < todayTarget ? todayTarget : todayTarget.AddDays(1);
                return next.ToString("yyyy-MM-dd HH:mm");
            }
            catch { return ""; }
        }

        private static bool TestShouldRun()
        {
            if (!config.Enabled) return false;
            DateTime next;
            if (!DateTime.TryParse(config.NextRunAt, out next)) return false;
            if (DateTime.Now < next) return false;
            if (config.LastScheduledDate == DateTime.Now.ToString("yyyy-MM-dd")) return false;
            return true;
        }

        private static string GetEmbeddedEngine()
        {
            try
            {
                using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("WorkBuddyEngine.ps1"))
                {
                    if (s == null) return null;
                    using (var r = new StreamReader(s, Encoding.UTF8))
                        return r.ReadToEnd();
                }
            }
            catch { return null; }
        }

        private static string ResolveEnginePath()
        {
            string content = GetEmbeddedEngine();
            if (content == null)
            {
                if (File.Exists(enginePath)) return enginePath;
                return enginePath;
            }
            try
            {
                string dir = Path.GetDirectoryName(enginePath);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                File.WriteAllText(enginePath, content, new UTF8Encoding(true));
                return enginePath;
            }
            catch { }
            if (File.Exists(enginePath)) return enginePath;
            try
            {
                string tmpDir = Path.Combine(Path.GetTempPath(), "WorkBuddyAutoCheckin");
                Directory.CreateDirectory(tmpDir);
                string tmp = Path.Combine(tmpDir, "WorkBuddy-AutoCheckin.ps1");
                File.WriteAllText(tmp, content, new UTF8Encoding(true));
                return tmp;
            }
            catch { return enginePath; }
        }

        private static void StartEngine()
        {
            StartEngine(false);
        }

        private static void StartEngine(bool fromSchedule)
        {
            if (running)
            {
                statusLabel.Text = "签到正在运行中，请稍候...";
                return;
            }

            string ep = ResolveEnginePath();
            if (!File.Exists(ep))
            {
                MessageBox.Show("找不到签到脚本：\n" + ep + "\n\n请把 WorkBuddy-AutoCheckin.ps1 和本应用放在同一目录。",
                    "WorkBuddy 自动签到", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            running = true;
            scheduledRun = fromSchedule;
            statusLabel.Text = "正在签到，请勿操作鼠标...";
            try
            {
                string logPath = Path.Combine(appDir, "workbuddy-checkin.log");
                logStartPos = File.Exists(logPath) ? new FileInfo(logPath).Length : 0;
                engineProc = LaunchEngine(ep);
                pollTimer.Start();
            }
            catch (Exception ex)
            {
                running = false;
                statusLabel.Text = "启动签到失败：" + ex.Message;
            }
        }

        private static Process LaunchEngine(string ep)
        {
            string logPath = Path.Combine(appDir, "workbuddy-checkin.log");
            string cfgPath = Path.Combine(appDir, "workbuddy-config.json");
            var psi = new ProcessStartInfo("powershell.exe");
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ep +
                "\" -LogFile \"" + logPath + "\" -ConfigFile \"" + cfgPath + "\"";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            return Process.Start(psi);
        }

        private static void AppendLogLine(string message)
        {
            try { File.AppendAllText(Path.Combine(appDir, "workbuddy-checkin.log"), message + "\r\n", Encoding.UTF8); }
            catch { }
        }

        private static void PollTick()
        {
            if (!running)
            {
                pollTimer.Stop();
                return;
            }
            try { engineProc.Refresh(); } catch { }
            if (engineProc == null || engineProc.HasExited)
            {
                int code;
                try { code = engineProc.ExitCode; } catch { code = -1; }

                pollTimer.Stop();
                string today = DateTime.Now.ToString("yyyy-MM-dd");
                config.LastRunDate = today;
                if (scheduledRun)
                {
                    config.LastScheduledDate = today;
                    config.NextRunAt = ComputeNextRunAt(config.Time);
                }
                scheduledRun = false;
                running = false;
                string res = GetLastEngineResult(logStartPos);
                if (code == 0)
                {
                    config.LastResult = res;
                }
                else if (res.StartsWith("["))
                {
                    config.LastResult = res;
                }
                else
                {
                    config.LastResult = "执行失败";
                }
                SaveConfig();
                UpdateStatus();
                ToolTipIcon icon = (config.LastResult.Contains("成功") || config.LastResult.Contains("已签到"))
                    ? ToolTipIcon.Info : ToolTipIcon.Warning;
                notify.ShowBalloonTip(5000, "WorkBuddy 自动签到", config.LastResult, icon);
            }
        }

        private static string GetLastEngineResult(long startPos)
        {
            string logPath = Path.Combine(appDir, "workbuddy-checkin.log");
            if (!File.Exists(logPath)) return "无日志";
            try
            {
                using (var fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    if (startPos > fs.Length) startPos = 0;
                    fs.Seek(startPos, SeekOrigin.Begin);
                    using (var r = new StreamReader(fs, Encoding.UTF8))
                    {
                        string all = r.ReadToEnd();
                        string[] lines = all.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
                        string lastErr = null;
                        for (int i = lines.Length - 1; i >= 0; i--)
                        {
                            string l = lines[i];
                            int idx = l.IndexOf("=== 结果:");
                            if (idx >= 0)
                            {
                                string res = l.Substring(idx + "=== 结果:".Length).Trim().TrimEnd('=').Trim();
                                if (res.Length > 0) return res;
                            }
                            if (l.Contains("执行失败")) lastErr = "执行失败";
                        }
                        if (lastErr != null) return lastErr;
                    }
                }
                return "未知";
            }
            catch { return "未知"; }
        }

        private static void ScheduleTick()
        {
            if (TestShouldRun()) StartEngine(true);
        }

        private static void SetAutoStart(bool on)
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
                {
                    if (on) key.SetValue("WorkBuddyAutoCheckin", "\"" + Application.ExecutablePath + "\" -StartMinimized");
                    else key.DeleteValue("WorkBuddyAutoCheckin", false);
                }
            }
            catch { }
        }

        private static Icon LoadAppIcon()
        {
            try
            {
                using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("WorkBuddyIcon.ico"))
                {
                    if (s != null) return new Icon(s);
                }
            }
            catch { }
            return SystemIcons.Application;
        }
    }
}
