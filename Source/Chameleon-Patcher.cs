using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

// Version metadata. csc.exe folds these into the PE's Win32 version resource, so the number shows
// up in Explorer's Details tab and in Get-Item ....VersionInfo without a separate .rc file. That
// matters more than usual here: a patched driver package carries no trace of which build of this
// tool produced it, so a bug report is only actionable if the log says. ReportVersion below puts
// the same number in every log header, and it reads it back out of the assembly rather than
// repeating the literal, so the two can never drift apart.
//
// AssemblyVersion is the binding identity and stays at x.y.0.0 across patch releases; the file
// and informational versions carry the precise one. Keep all three in step on a release.
[assembly: AssemblyTitle("Chameleon Patcher")]
[assembly: AssemblyProduct("Project Chameleon")]
[assembly: AssemblyDescription("NVIDIA driver GPU-unlock patcher")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.3.0")]
[assembly: AssemblyInformationalVersion("1.0.3")]

namespace ChameleonPatcherGui
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    public class MainForm : Form
    {
        // Height of the live log panel shown by "Show details". Every vertical position, and the
        // window height, is computed by LayoutForm from the controls actually visible.
        private const int DetailsPanelHeight = 218;

        private TextBox txtDriverPath;
        private CheckBox chkUsePfx;
        private GroupBox grpCert;
        private TextBox txtCertPath;
        private TextBox txtPassword;
        private CheckBox chkAddInstallerOption;
        private CheckBox chkOverwrite;
        private CheckBox chkPruneInfs;
        private Button btnStart;
        private Button btnToggleDetails;
        private ProgressBar progressBar;
        private Label lblStep;
        private Label lblStatus;
        private TextBox txtLog;
        private Panel detailsPanel;
        private Button btnOpenLog;

        private readonly string scriptsDir;
        private bool running;

        // The pipeline's powershell.exe while a run is in progress. Held so that closing the
        // window can actually stop it: the child runs with no window of its own, so a child left
        // behind keeps unpacking, patching and signing invisibly.
        private Process pipelineProcess;

        // Set once the window is going down mid-run, so late callbacks from the child's output
        // streams and the run's own continuation stop touching a form that no longer exists.
        private bool closing;

        private const string PreparingText = "Checking...";

        // Set from the child's output callbacks (threadpool threads) when the pipeline stops
        // because the signing key is not on this PC and a .pfx password is needed. The failure
        // dialog then points at the hidden .pfx fields instead of leaving the user to find them.
        private volatile bool pfxPasswordWasRequired;

        // Logging state. The writer is touched from the two redirected-stream callbacks, which run
        // on separate threadpool threads, so every write goes through logLock.
        private string logPath;
        private StreamWriter logWriter;
        private readonly object logLock = new object();
        private Stopwatch runClock;

        public MainForm()
        {
            // This exe lives at the project root; the pipeline scripts live in .\Scripts.
            scriptsDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Scripts");
            BuildUi();
        }

        private void BuildUi()
        {
            // Version in the title bar, from the same assembly attribute the log header uses, so
            // a screenshot of the window is enough to tell which build someone is running.
            Text = "Chameleon Patcher " + ReportVersion();

            // Reuse the icon already embedded in this executable by csc's /win32icon, so the
            // window and taskbar match the file icon without shipping a separate .ico alongside
            // the .exe. Purely cosmetic, so a failure here must never stop the app starting.
            try
            {
                Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            }
            catch
            {
            }

            ClientSize = new System.Drawing.Size(560, 458);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;

            var grpDriver = new GroupBox { Text = "Driver package", Left = 15, Top = 15, Width = 530, Height = 100 };
            // Explicit height: a Label defaults to 23 px, which would reach down to y=45 and, being
            // added first (so on top), clip the top edge of the "Select .exe..." button at y=43.
            var lblDriverHint = new Label
            {
                Text = "Downloaded driver installer (.exe), or an already-unpacked folder:",
                Left = 10,
                Top = 22,
                Width = 500,
                Height = 18
            };
            txtDriverPath = new TextBox { Name = "txtDriverPath", Left = 10, Top = 45, Width = 400 };
            var btnBrowseExe = new Button { Text = "Select .exe...", Left = 415, Top = 43, Width = 100 };
            btnBrowseExe.Click += (s, e) => BrowseFile(txtDriverPath, "NVIDIA driver installer (*.exe)|*.exe");
            var btnBrowseFolder = new Button { Text = "Or select an unpacked folder...", Left = 10, Top = 70, Width = 505 };
            btnBrowseFolder.Click += (s, e) => BrowseFolder(txtDriverPath);
            grpDriver.Controls.AddRange(new Control[] { lblDriverHint, txtDriverPath, btnBrowseExe, btnBrowseFolder });

            // The .pfx fields are hidden unless asked for. The normal case needs neither: the
            // pipeline signs with the key already in Cert:\CurrentUser\My, finds it there even if
            // the Certificates folder is gone, and mints one on a PC that has none - all with no
            // password. A .pfx only matters for signing with an EXISTING certificate exported from
            // another PC (e.g. one the target machines already trust) instead of the one here or a
            // new one. The label says that rather than "for a PC without the key": a PC without a
            // key needs nothing ticked, since the pipeline mints a certificate for it.
            // An always-visible password box suggested a password was needed when it almost never is.
            chkUsePfx = new CheckBox
            {
                Text = "Sign with an existing certificate from a .pfx file",
                Left = 20,
                Top = 123,
                Width = 525
            };
            chkUsePfx.CheckedChanged += (s, e) =>
            {
                // Unticking discards the password rather than keeping it out of sight. The path
                // can stay - it is ignored while the box is unticked and harmless to keep.
                if (!chkUsePfx.Checked) txtPassword.Clear();
                LayoutForm();
            };

            grpCert = new GroupBox { Text = "Signing certificate (.pfx)", Left = 15, Width = 530, Height = 116, Visible = false };
            var lblCertHintTicked = new Label
            {
                Text = "Ticked: the certificate in the .pfx file below is used - its password is needed.",
                Left = 10,
                Top = 18,
                Width = 505,
                Height = 18
            };
            var lblCertHintUnticked = new Label
            {
                Text = "Unticked: the key on this PC is used, or a new certificate is created.",
                Left = 10,
                Top = 36,
                Width = 505,
                Height = 18
            };
            txtCertPath = new TextBox { Name = "txtCertPath", Left = 10, Top = 58, Width = 400 };
            var btnBrowseCert = new Button { Text = "Browse...", Left = 415, Top = 56, Width = 100 };
            btnBrowseCert.Click += (s, e) => BrowseFile(txtCertPath, "PFX certificate (*.pfx)|*.pfx");
            var lblPassword = new Label { Text = "Password:", Left = 10, Top = 89, Width = 120, Height = 18 };
            txtPassword = new TextBox { Name = "txtPassword", Left = 135, Top = 86, Width = 280, PasswordChar = '*' };
            grpCert.Controls.AddRange(new Control[] { lblCertHintTicked, lblCertHintUnticked, txtCertPath, btnBrowseCert, lblPassword, txtPassword });

            chkAddInstallerOption = new CheckBox
            {
                Text = "Add a certificate-trust checkbox to the installer, ticked by default (recommended)",
                Left = 20,
                Width = 525,
                Checked = true
            };
            // Off by default, matching the pipeline's own default. Ticking it makes the run about
            // seven times faster by dropping the ~41 OEM display INFs that cannot match this PC,
            // at the cost of a package that only installs here.
            chkPruneInfs = new CheckBox
            {
                Text = "Build for this PC only - much faster, but not portable to other machines",
                Left = 20,
                Width = 525
            };
            chkOverwrite = new CheckBox
            {
                Text = "Delete the output folder first if it already exists",
                Left = 20,
                Width = 525
            };

            btnStart = new Button
            {
                Name = "btnStart",
                Text = "Start Patching",
                Left = 20,
                Width = 525,
                Height = 34,
                Font = new System.Drawing.Font(Font, System.Drawing.FontStyle.Bold)
            };
            btnStart.Click += BtnStart_Click;

            progressBar = new ProgressBar { Left = 20, Width = 525, Height = 20, Minimum = 0, Maximum = 100 };
            lblStep = new Label { Text = "Ready.", Left = 20, Width = 525, Height = 18 };

            btnToggleDetails = new Button { Text = "▼ Show details", Left = 20, Width = 150, FlatStyle = FlatStyle.Flat };
            btnToggleDetails.FlatAppearance.BorderSize = 0;
            btnToggleDetails.Click += (s, e) => ToggleDetails();

            btnOpenLog = new Button
            {
                Text = "Open log folder",
                Left = 175,
                Width = 150,
                FlatStyle = FlatStyle.Flat,
                Enabled = false
            };
            btnOpenLog.FlatAppearance.BorderSize = 0;
            btnOpenLog.Click += (s, e) => OpenLogLocation();

            detailsPanel = new Panel { Left = 20, Width = 525, Height = DetailsPanelHeight, Visible = false };
            txtLog = new TextBox
            {
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Vertical,
                Dock = DockStyle.Fill,
                Font = new System.Drawing.Font("Consolas", 8f),
                BackColor = System.Drawing.Color.Black,
                ForeColor = System.Drawing.Color.LightGray
            };
            detailsPanel.Controls.Add(txtLog);

            // Its own status row BELOW the "Show details" / "Open log folder" buttons, placed by
            // LayoutForm. Not anchored to ClientSize.Height: the window grows when details expand,
            // and a bottom-anchored label would then land inside the log panel.
            lblStatus = new Label
            {
                Text = "",
                Left = 20,
                Width = 525,
                Height = 20,
                ForeColor = System.Drawing.Color.DarkRed
            };

            Controls.AddRange(new Control[]
            {
                grpDriver, chkUsePfx, grpCert, chkAddInstallerOption, chkPruneInfs, chkOverwrite,
                btnStart, progressBar, lblStep, btnToggleDetails, btnOpenLog, detailsPanel, lblStatus
            });

            LayoutForm();
            FormClosing += MainForm_FormClosing;
        }

        /// <summary>
        /// Places everything below the .pfx checkbox in one top-to-bottom pass and sizes the
        /// window to fit, so showing or hiding the .pfx fields or the log panel moves the rest
        /// instead of leaving a gap or overlapping it. Each row starts where the previous one
        /// ends, which also rules out the kind of overlap that clipped the "Select .exe..." button.
        /// </summary>
        private void LayoutForm()
        {
            SuspendLayout();

            int y = chkUsePfx.Bottom;
            grpCert.Visible = chkUsePfx.Checked;
            if (grpCert.Visible)
            {
                grpCert.Top = y + 3;
                y = grpCert.Bottom + 8;
            }

            chkAddInstallerOption.Top = y;
            chkPruneInfs.Top = chkAddInstallerOption.Bottom;
            chkOverwrite.Top = chkPruneInfs.Bottom;

            btnStart.Top = chkOverwrite.Bottom + 8;
            progressBar.Top = btnStart.Bottom + 10;
            lblStep.Top = progressBar.Bottom + 4;
            btnToggleDetails.Top = lblStep.Bottom + 4;
            btnOpenLog.Top = btnToggleDetails.Top;
            lblStatus.Top = btnToggleDetails.Bottom + 3;

            detailsPanel.Top = lblStatus.Bottom + 4;
            int height = detailsPanel.Visible ? detailsPanel.Bottom + 26 : lblStatus.Bottom;
            ClientSize = new System.Drawing.Size(ClientSize.Width, height);

            ResumeLayout();
        }

        private void ToggleDetails()
        {
            detailsPanel.Visible = !detailsPanel.Visible;
            btnToggleDetails.Text = detailsPanel.Visible ? "▲ Hide details" : "▼ Show details";
            LayoutForm();
        }

        private void BrowseFile(TextBox target, string filter)
        {
            using (var dlg = new OpenFileDialog { Filter = filter })
            {
                if (dlg.ShowDialog(this) == DialogResult.OK)
                {
                    target.Text = dlg.FileName;
                }
            }
        }

        private void BrowseFolder(TextBox target)
        {
            using (var dlg = new FolderBrowserDialog())
            {
                if (dlg.ShowDialog(this) == DialogResult.OK)
                {
                    target.Text = dlg.SelectedPath;
                }
            }
        }

        private void MainForm_FormClosing(object sender, FormClosingEventArgs e)
        {
            if (running)
            {
                var result = MessageBox.Show(
                    this,
                    "Patching is still running. Closing now will abort it partway through. Close anyway?",
                    "Patching in progress",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning);
                if (result != DialogResult.Yes)
                {
                    e.Cancel = true;
                    return;
                }

                // Going down mid-run. Stop the whole child tree - powershell.exe and whatever it
                // started (7z, Inf2Cat, signtool) - then record that explicitly, so the log ends
                // with a reason instead of just stopping and looking like a hang or a crash.
                closing = true;
                LogLine("[abort]", "window closed by the user while the patch was still running - stopping the pipeline");
                bool stopped = KillProcessTree(pipelineProcess);
                LogLine("[abort]", stopped ? "pipeline process tree stopped" : "could not confirm the pipeline process tree stopped");
                FinishLog(-1, "ABORTED - window closed mid-run; the output folder is incomplete");
            }
        }

        /// <summary>
        /// Stops a process and every process it started. Process.Kill() on .NET Framework stops
        /// only the one process, which here would leave 7z, Inf2Cat or signtool running on with
        /// nothing to report to. taskkill /T walks the tree. Returns true once the process is gone.
        /// </summary>
        private static bool KillProcessTree(Process p)
        {
            if (p == null) return true;
            try
            {
                if (p.HasExited) return true;
            }
            catch
            {
                return true;
            }

            try
            {
                var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "taskkill.exe"), "/PID " + p.Id + " /T /F")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using (var killer = Process.Start(psi))
                {
                    if (killer != null) killer.WaitForExit(10000);
                }
            }
            catch
            {
            }

            try
            {
                if (!p.HasExited) p.Kill();
                return p.WaitForExit(5000);
            }
            catch
            {
                return false;
            }
        }

        /// <summary>
        /// Quotes one argument for the Windows command-line convention powershell.exe parses
        /// with. Backslashes are literal except directly before a quote, so a path ending in "\"
        /// - a drive root such as D:\ - must have its trailing backslashes doubled; otherwise the
        /// closing quote reads as an escaped literal quote and swallows the arguments after it.
        /// </summary>
        private static string Quote(string s)
        {
            var sb = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char c in s)
            {
                if (c == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (c == '"')
                {
                    sb.Append('\\', backslashes * 2 + 1).Append('"');
                }
                else
                {
                    sb.Append('\\', backslashes).Append(c);
                }
                backslashes = 0;
            }
            sb.Append('\\', backslashes * 2).Append('"');
            return sb.ToString();
        }

        /// <summary>
        /// Runs an action on the UI thread unless the window is already going down. The child's
        /// output callbacks arrive on threadpool threads and can outlive the form by a moment.
        /// </summary>
        private void PostToUi(Action action)
        {
            if (closing || IsDisposed || !IsHandleCreated) return;
            try
            {
                BeginInvoke((MethodInvoker)delegate
                {
                    if (!closing && !IsDisposed) action();
                });
            }
            catch (InvalidOperationException)
            {
                // Includes ObjectDisposedException: the handle went away between the check and the post.
            }
        }

        /// <summary>
        /// Runs the pipeline in one of its ask-and-stop modes (-ShowOutputPath,
        /// -CheckLocalGpuSupport) and returns its stdout, or null if the question could not be
        /// answered. Those modes touch nothing on disk, so this is safe to call before a run.
        /// </summary>
        private string QueryPipeline(string queryArgs, string driverPath, bool isExe, bool prune)
        {
            string pipelineScript = Path.Combine(scriptsDir, "Invoke-DriverPatchPipeline.ps1");
            if (!File.Exists(pipelineScript)) return null;

            try
            {
                var args = new StringBuilder();
                args.Append("-NoProfile -ExecutionPolicy Bypass -File ").Append(Quote(pipelineScript));
                if (driverPath != null)
                {
                    args.Append(isExe ? " -SourceExePath " : " -SourcePackagePath ").Append(Quote(driverPath));
                }
                if (prune) args.Append(" -PruneForeignOemInfs");
                args.Append(' ').Append(queryArgs);

                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = args.ToString(),
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8
                };

                using (var proc = Process.Start(psi))
                {
                    // Drain BOTH streams while the child runs. The pipeline's Write-Host banners
                    // land on stderr in a redirected, non-interactive context; if stderr were
                    // never read, a child that filled the stderr buffer would block on write and
                    // never exit, and the stdout read below would hang the GUI with no reason.
                    // Waiting with a timeout BEFORE consuming the streams is also what makes the
                    // 20 s bound real - reading to the end first only returns once the child has
                    // already exited, so a timeout checked afterwards can never fire.
                    var stdoutTask = proc.StandardOutput.ReadToEndAsync();
                    var stderrTask = proc.StandardError.ReadToEndAsync();
                    if (!proc.WaitForExit(20000))
                    {
                        KillProcessTree(proc);
                        return null;
                    }
                    stdoutTask.Wait();
                    stderrTask.Wait();
                    if (proc.ExitCode != 0) return null;
                    return stdoutTask.Result;
                }
            }
            catch
            {
                return null;
            }
        }

        /// <summary>
        /// Asks the pipeline where it would put its output. The naming rule, including the GPU tag
        /// a pruned build gets, lives only in the pipeline; this keeps the GUI in step with it
        /// rather than maintaining a second copy that drifts.
        ///
        /// Falls back to the plain "_Patched" name if the query fails for any reason. Getting a
        /// slightly less descriptive folder is a far better failure than refusing to patch.
        /// </summary>
        private async Task<string> ResolveOutputPathAsync(string driverPath, bool isExe, bool prune)
        {
            string fallback = isExe
                ? Path.Combine(Path.GetDirectoryName(driverPath), Path.GetFileNameWithoutExtension(driverPath) + "_Patched")
                : driverPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + "_Patched";

            // Off the UI thread: the query starts powershell.exe and reads WMI, which can take
            // several seconds, and the window would show "Not responding" for all of it.
            string stdout = await Task.Run(() => QueryPipeline("-ShowOutputPath", driverPath, isExe, prune));
            if (stdout == null) return fallback;

            // The path is the last non-empty line; anything else on stdout is noise.
            string[] lines = stdout.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            for (int i = lines.Length - 1; i >= 0; i--)
            {
                string candidate = lines[i].Trim();
                if (candidate.Length > 0 && Path.IsPathRooted(candidate)) return candidate;
            }
            return fallback;
        }

        /// <summary>
        /// "Build for this PC only" strips out every display INF that cannot match this machine.
        /// If none of this machine's GPUs is one whitelist.json unlocks, that build has nothing
        /// left to unlock: it would spend the whole run re-signing a driver the GPU here already
        /// runs. The pipeline refuses such a run in its preflight; this asks the same question
        /// first, so the answer arrives as a choice rather than as a failed run.
        ///
        /// A universal build is never questioned. Building one on a machine whose GPU needs no
        /// unlock is the ordinary case - the package is for the machine that does.
        ///
        /// Returns false only if the user wants to stop. "Yes" switches the checkbox off and
        /// carries on, so the header, the arguments and the output folder all follow the choice
        /// that was actually made.
        /// </summary>
        private async Task<bool> ConfirmPrunedBuildIsWorthItAsync()
        {
            if (!chkPruneInfs.Checked) return true;

            string stdout = await Task.Run(() => QueryPipeline("-CheckLocalGpuSupport", null, false, false));
            if (closing || IsDisposed) return false;
            if (stdout == null) return true;   // Unanswerable: leave the decision to the pipeline.

            string[] lines = stdout.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            if (lines.Length == 0) return true;
            string verdict = lines[0].Trim();
            if (verdict != "UNSUPPORTED") return true;   // SUPPORTED, or nothing detectable to judge.

            var detail = new StringBuilder();
            for (int i = 1; i < lines.Length; i++) detail.AppendLine(lines[i].TrimEnd());

            var answer = MessageBox.Show(
                this,
                "No GPU in this PC is one this patcher unlocks:\n\n" +
                detail.ToString() +
                "\n\"Build for this PC only\" cuts the package down to what can match THIS machine, " +
                "so it would produce NVIDIA's own driver for a GPU that already works, re-signed " +
                "with a certificate Windows does not trust yet - a long run for no unlock.\n\n" +
                "Build the portable package instead? It keeps every whitelist entry and installs " +
                "on the machine that has the locked GPU.\n\n" +
                "Yes - build the portable package (recommended)\n" +
                "No - stop, change nothing\n\n" +
                "(To force the for-this-PC-only build anyway, run Invoke-DriverPatchPipeline.ps1 " +
                "with -AllowUnsupportedGpu.)",
                "Nothing to unlock on this PC",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning);

            if (answer != DialogResult.Yes) return false;

            chkPruneInfs.Checked = false;
            return true;
        }

        private void AppendLog(string line)
        {
            if (line == null) return;
            txtLog.AppendText(line + Environment.NewLine);
        }

        // ---------------------------------------------------------------------------------------
        // Event log
        //
        // The on-screen details panel is lost the moment the window closes, which is exactly when
        // a failed patch needs looking at. Everything the child process emits is therefore also
        // written to a timestamped file, incrementally and with AutoFlush on, so the log survives
        // a crash, a kill, or a hang partway through - not just a clean failure.
        //
        // Nothing secret goes in here. The password never appears on the child's command line (it
        // travels in an environment variable, see RunPipelineAsync), so logging the full argument
        // string is safe; the header records only WHETHER one was supplied.
        // ---------------------------------------------------------------------------------------

        private const int LogsToKeep = 20;

        private static string[] CandidateLogDirs()
        {
            // Portable-tool first: a Logs folder beside the .exe is where someone will look. Fall
            // back to per-user locations for the case where the app sits somewhere unwritable.
            return new string[]
            {
                Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Logs"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Chameleon Patcher", "Logs"),
                Path.Combine(Path.GetTempPath(), "Chameleon Patcher Logs")
            };
        }

        private void StartLog(string driverPath, string outputPath, string certPath, string arguments, bool passwordSupplied)
        {
            runClock = Stopwatch.StartNew();
            logPath = null;
            logWriter = null;

            string name = "patch-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log";
            foreach (string dir in CandidateLogDirs())
            {
                try
                {
                    Directory.CreateDirectory(dir);
                    string candidate = Path.Combine(dir, name);
                    var writer = new StreamWriter(candidate, false, new UTF8Encoding(false));
                    writer.AutoFlush = true;
                    logWriter = writer;
                    logPath = candidate;
                    break;
                }
                catch
                {
                    // Try the next location.
                }
            }

            if (logWriter == null)
            {
                AppendLog("[warn] Could not open a log file in any of the candidate locations; this run is not being logged to disk.");
                return;
            }

            bool elevated = false;
            try
            {
                var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
                elevated = new System.Security.Principal.WindowsPrincipal(identity)
                    .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
            catch
            {
            }

            WriteRaw("=== Chameleon Patcher - patch log ===");
            WriteRaw("started        : " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss zzz"));
            WriteRaw("version        : " + ReportVersion());
            WriteRaw("executable     : " + Application.ExecutablePath);
            WriteRaw("scripts folder : " + scriptsDir);
            WriteRaw("log file       : " + logPath);
            WriteRaw("machine / user : " + Environment.MachineName + " / " + Environment.UserName);
            WriteRaw("os             : " + DescribeOs());
            WriteRaw("clr            : " + Environment.Version);
            WriteRaw("elevated       : " + elevated);
            WriteRaw("");
            WriteRaw("driver input   : " + driverPath);
            WriteRaw("output folder  : " + outputPath);
            WriteRaw("installer opt  : " + (chkAddInstallerOption.Checked ? "add cert-trust checkbox" : "skipped"));
            WriteRaw("overwrite      : " + chkOverwrite.Checked);
            WriteRaw("prune OEM INFs : " + (chkPruneInfs.Checked ? "yes - package will be specific to this PC" : "no - all INFs kept, portable"));
            WriteRaw("cert file      : " + (certPath.Length == 0 ? "(none - sign from the certificate store)" : certPath));
            WriteRaw("password given : " + (passwordSupplied ? "yes (value never logged)" : "no"));
            WriteRaw("");
            WriteRaw("child command  : powershell.exe " + arguments);
            WriteRaw("");
            WriteRaw("Elapsed times below are from the start of the child process. The pipeline's own");
            WriteRaw("'=== N/M: ... ===' banners mark each step, so the gap between two banners is how");
            WriteRaw("long that step took - useful because the catalog rebuild normally dominates.");
            WriteRaw("");
            WriteRaw("--------------------------------------------------------------------------------");
        }

        private static string ReportVersion()
        {
            // Read back from the assembly rather than hardcoding, so bumping the attributes above
            // is the only edit a release needs. Informational version is preferred because it
            // carries the plain "x.y.z" rather than the four-part file version.
            try
            {
                Assembly asm = Assembly.GetExecutingAssembly();
                var info = (AssemblyInformationalVersionAttribute[])asm.GetCustomAttributes(
                    typeof(AssemblyInformationalVersionAttribute), false);
                if (info.Length > 0 && !string.IsNullOrEmpty(info[0].InformationalVersion))
                {
                    return info[0].InformationalVersion;
                }
                return asm.GetName().Version.ToString();
            }
            catch
            {
                return "(unknown)";
            }
        }

        private static string DescribeOs()
        {
            // Environment.OSVersion is useless here: without an application compatibility
            // manifest Windows reports 6.2.9200 (Windows 8) to every process, so a log from
            // Windows 11 would claim to be Windows 8. For a driver-signing tool the real build is
            // one of the first things you want to know, since Test Signing behaviour and driver
            // signature policy vary by build, so read it from the registry instead.
            string arch = Environment.Is64BitOperatingSystem ? "64-bit" : "32-bit";
            try
            {
                using (var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                    @"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                {
                    if (key != null)
                    {
                        string product = key.GetValue("ProductName") as string;
                        string display = key.GetValue("DisplayVersion") as string;
                        string build = key.GetValue("CurrentBuild") as string;
                        object ubr = key.GetValue("UBR");

                        // Windows 11 still reports ProductName "Windows 10 ..."; build 22000+ is
                        // the real dividing line.
                        int buildNum;
                        if (product != null && build != null &&
                            int.TryParse(build, out buildNum) && buildNum >= 22000 &&
                            product.IndexOf("Windows 10", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            product = product.Replace("Windows 10", "Windows 11");
                        }

                        var sb = new StringBuilder();
                        sb.Append(product ?? "Windows");
                        if (!string.IsNullOrEmpty(display)) sb.Append(" ").Append(display);
                        if (!string.IsNullOrEmpty(build))
                        {
                            sb.Append(" (build ").Append(build);
                            if (ubr != null) sb.Append(".").Append(ubr);
                            sb.Append(")");
                        }
                        sb.Append(" ").Append(arch);
                        return sb.ToString();
                    }
                }
            }
            catch
            {
            }
            return Environment.OSVersion.VersionString + " " + arch + " (registry unavailable; this figure is unreliable)";
        }

        private void WriteRaw(string text)
        {
            lock (logLock)
            {
                if (logWriter == null) return;
                try
                {
                    logWriter.WriteLine(text);
                }
                catch
                {
                    // A logging failure must never take the run down with it.
                }
            }
        }

        private void LogLine(string tag, string text)
        {
            if (text == null) return;
            TimeSpan t = runClock == null ? TimeSpan.Zero : runClock.Elapsed;
            WriteRaw(string.Format("[{0:00}:{1:00}:{2:00}.{3:000}] {4} {5}",
                (int)t.TotalHours, t.Minutes, t.Seconds, t.Milliseconds, tag, text));
        }

        private void FinishLog(int exitCode, string outcome)
        {
            TimeSpan t = runClock == null ? TimeSpan.Zero : runClock.Elapsed;
            WriteRaw("--------------------------------------------------------------------------------");
            WriteRaw("");
            WriteRaw("finished  : " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss zzz"));
            WriteRaw("duration  : " + string.Format("{0:00}:{1:00}:{2:00}", (int)t.TotalHours, t.Minutes, t.Seconds));
            WriteRaw("exit code : " + exitCode);
            WriteRaw("outcome   : " + outcome);
            if (exitCode != 0)
            {
                WriteRaw("");
                WriteRaw("To diagnose: find the last '=== N/M: ... ===' banner above - that is the step that");
                WriteRaw("failed - then read forward for the first [stderr] line or thrown message. A failure");
                WriteRaw("at the verification step means the patch did not apply and signing was refused on");
                WriteRaw("purpose; see 'The verification gate' in README.md.");
            }

            lock (logLock)
            {
                if (logWriter != null)
                {
                    try
                    {
                        logWriter.Flush();
                        logWriter.Dispose();
                    }
                    catch
                    {
                    }
                    logWriter = null;
                }
            }

            PruneOldLogs();
        }

        private void PruneOldLogs()
        {
            // Keep the log folder from growing without bound. Only files this app names are
            // considered, so nothing else in the folder is ever touched.
            if (logPath == null) return;
            try
            {
                var dir = new DirectoryInfo(Path.GetDirectoryName(logPath));
                FileInfo[] logs = dir.GetFiles("patch-*.log");
                if (logs.Length <= LogsToKeep) return;
                Array.Sort(logs, (a, b) => b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc));
                for (int i = LogsToKeep; i < logs.Length; i++)
                {
                    try
                    {
                        logs[i].Delete();
                    }
                    catch
                    {
                    }
                }
            }
            catch
            {
            }
        }

        private void OpenLogLocation()
        {
            if (logPath == null || !File.Exists(logPath))
            {
                MessageBox.Show(this, "No log file from this session yet - run a patch first.",
                    "No log", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            try
            {
                // Open Explorer with the log already selected, rather than just the folder.
                Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + logPath + "\"") { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Couldn't open the log folder:\n" + ex.Message + "\n\nThe log is at:\n" + logPath,
                    "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void OpenLogFile()
        {
            if (logPath == null || !File.Exists(logPath)) return;
            try
            {
                Process.Start(new ProcessStartInfo(logPath) { UseShellExecute = true });
            }
            catch
            {
                OpenLogLocation();
            }
        }

        private static readonly Regex StepRegex = new Regex(@"^===\s*(\d+)/(\d+):\s*(.+?)\s*===\s*$", RegexOptions.Compiled);

        private async void BtnStart_Click(object sender, EventArgs e)
        {
            // Inputs stay locked while the pre-run checks run in the background, so a second click
            // or an edited path cannot slip in between a check and the run it was made for.
            SetInputsEnabled(false);
            lblStep.Text = PreparingText;
            try
            {
                await StartPatchingAsync();
            }
            finally
            {
                if (!closing && !IsDisposed && !running)
                {
                    SetInputsEnabled(true);
                    if (lblStep.Text == PreparingText) lblStep.Text = "Ready.";
                }
            }
        }

        private async Task StartPatchingAsync()
        {
            string driverPath = txtDriverPath.Text.Trim();
            // The .pfx fields count only while their checkbox is ticked. Whatever is left in them
            // otherwise is ignored, so an untick really does mean "sign from the store".
            bool usePfx = chkUsePfx.Checked;
            string certPath = usePfx ? txtCertPath.Text.Trim() : "";
            string password = usePfx ? txtPassword.Text : "";

            if (string.IsNullOrEmpty(driverPath) || !(File.Exists(driverPath) || Directory.Exists(driverPath)))
            {
                MessageBox.Show(this, "Select a valid driver .exe or unpacked folder first.", "Missing input", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            // A typed folder path may end in a separator. Drop it (except on a drive root, where
            // it is part of the path) so the derived "<folder>_Patched" name comes out right.
            if (Directory.Exists(driverPath))
            {
                string root = Path.GetPathRoot(driverPath);
                if (!string.Equals(driverPath, root, StringComparison.OrdinalIgnoreCase))
                {
                    driverPath = driverPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                }
            }
            bool isExe = File.Exists(driverPath) && driverPath.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);
            if (!isExe && !Directory.Exists(driverPath))
            {
                MessageBox.Show(this, "The driver path must be either a .exe file or a folder.", "Invalid input", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            // Ticked but incomplete: stop before anything runs, and offer the two ways out - fill
            // the fields in, or untick and sign the normal way. Without this an empty password
            // only surfaces once the pipeline fails on it.
            if (usePfx && (certPath.Length == 0 || password.Length == 0))
            {
                string missing =
                    certPath.Length == 0 && password.Length == 0 ? "No .pfx file is selected and no password is entered." :
                    certPath.Length == 0 ? "No .pfx file is selected." :
                    "No password is entered for the .pfx file.";
                var choice = MessageBox.Show(
                    this,
                    missing + "\n\n" +
                    "\"Sign with an existing certificate from a .pfx file\" is ticked, so the .pfx file " +
                    "and its password are both needed.\n\n" +
                    "Yes - untick it and sign with the key on this PC (or have a new certificate created)\n" +
                    "No - go back and fill them in",
                    "Certificate details missing",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning);
                if (choice != DialogResult.Yes) return;

                chkUsePfx.Checked = false;   // also clears the password and hides the fields
                usePfx = false;
                certPath = "";
                password = "";
            }
            if (!string.IsNullOrEmpty(certPath) && !File.Exists(certPath))
            {
                MessageBox.Show(this, "The selected certificate file doesn't exist.", "Invalid input", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            // No password check here on purpose. The normal case needs no password at all: the
            // pipeline signs with the private key already in Cert:\CurrentUser\My. It is passed
            // -NonInteractive below, so if a password genuinely IS required (a .pfx whose key
            // isn't in this machine's store, or a first-ever cert that needs a .pfx backup) it
            // fails with an explanatory message instead of blocking on a prompt this GUI cannot
            // answer.

            // Ask about a for-this-PC-only build BEFORE the output path is resolved: answering
            // "build the portable one" unticks the checkbox, and that changes the folder name.
            if (!await ConfirmPrunedBuildIsWorthItAsync()) return;

            // A pruned build lands in "<source>_Patched_<GPU>" rather than "<source>_Patched", so
            // the folder itself says which machine it was cut for. Ask the pipeline for the name
            // instead of reproducing the rule here: it owns the GPU detection, and two copies of
            // that logic would eventually disagree.
            string outputPath = await ResolveOutputPathAsync(driverPath, isExe, chkPruneInfs.Checked);
            if (closing || IsDisposed) return;

            if (Directory.Exists(outputPath))
            {
                if (!chkOverwrite.Checked)
                {
                    MessageBox.Show(
                        this,
                        "Output folder already exists:\n" + outputPath +
                        "\n\nCheck \"Delete the output folder first\" to replace it, or remove it manually first.",
                        "Output already exists",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                    return;
                }
                var confirm = MessageBox.Show(
                    this,
                    "This will permanently delete:\n" + outputPath + "\n\nContinue?",
                    "Confirm delete",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning);
                if (confirm != DialogResult.Yes) return;
                try
                {
                    Directory.Delete(outputPath, true);
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, "Couldn't delete the existing output folder:\n" + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }
            }

            string pipelineScript = Path.Combine(scriptsDir, "Invoke-DriverPatchPipeline.ps1");
            if (!File.Exists(pipelineScript))
            {
                MessageBox.Show(this, "Could not find Invoke-DriverPatchPipeline.ps1 in the Scripts folder next to this program:\n" + pipelineScript, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            var argsBuilder = new StringBuilder();
            argsBuilder.Append("-NoProfile -ExecutionPolicy Bypass -File ").Append(Quote(pipelineScript));
            argsBuilder.Append(isExe ? " -SourceExePath " : " -SourcePackagePath ").Append(Quote(driverPath));
            argsBuilder.Append(" -OutputPath ").Append(Quote(outputPath));
            if (!string.IsNullOrEmpty(certPath))
            {
                argsBuilder.Append(" -PfxPath ").Append(Quote(certPath));
            }
            if (!chkAddInstallerOption.Checked)
            {
                argsBuilder.Append(" -SkipSetupCertOption");
            }
            // Opt-in, because it makes the output specific to this machine. The payoff is large:
            // dropping the OEM display INFs that cannot match this PC took a 616.86 run from about
            // 57 minutes to 7.6, almost all of it in the catalog rebuild.
            if (chkPruneInfs.Checked)
            {
                argsBuilder.Append(" -PruneForeignOemInfs");
            }
            // Never prompt in the child. There is no console attached to it, so a Read-Host
            // prompt would hang forever with the GUI showing no reason why; -NonInteractive
            // turns any such case into a clear error we surface in the log instead.
            argsBuilder.Append(" -NonInteractive");
            // -PfxPassword is deliberately never passed on the command line, where any process
            // listing or event log could read it. When a password is actually needed it travels
            // in an environment variable set only on the child process (see RunPipelineAsync).
            // In the normal, store-signing case there is no password involved at all and nothing
            // is set.

            SetRunning(true);
            txtLog.Clear();
            progressBar.Value = 0;
            lblStep.Text = "Starting...";
            lblStatus.Text = "";
            lblStatus.ForeColor = System.Drawing.Color.DarkRed;

            pfxPasswordWasRequired = false;
            StartLog(driverPath, outputPath, certPath, argsBuilder.ToString(), !string.IsNullOrEmpty(password));
            if (logPath != null)
            {
                AppendLog("Logging this run to: " + logPath);
                AppendLog(new string('-', 78));
                btnOpenLog.Enabled = true;
            }

            int exitCode = await RunPipelineAsync(argsBuilder.ToString(), password);
            pipelineProcess = null;

            // The window was closed mid-run: FormClosing has already stopped the child and
            // finished the log, and the controls below no longer exist.
            if (closing || IsDisposed) return;

            SetRunning(false);
            FinishLog(exitCode, exitCode == 0 ? "success" : "FAILED");
            // The password has already travelled to the child (environment variable) and is
            // recorded as supplied-or-not in the log header; don't leave it sitting in the box
            // afterwards. Retyping it for a retry is the price of not keeping a signing
            // password on screen.
            txtPassword.Clear();

            if (exitCode == 0)
            {
                progressBar.Value = 100;
                lblStep.Text = "Done.";
                lblStatus.ForeColor = System.Drawing.Color.DarkGreen;
                lblStatus.Text = "Patching completed successfully.";

                var launch = MessageBox.Show(
                    this,
                    "Patching completed successfully.\n\nDo you want to launch the driver installer (setup.exe) now?",
                    "Patching complete",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question);
                if (launch == DialogResult.Yes)
                {
                    string setupExe = Path.Combine(outputPath, "setup.exe");
                    if (File.Exists(setupExe))
                    {
                        try
                        {
                            Process.Start(new ProcessStartInfo(setupExe) { UseShellExecute = true, WorkingDirectory = outputPath });
                        }
                        catch (Exception ex)
                        {
                            MessageBox.Show(this, "Couldn't launch setup.exe:\n" + ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                    }
                    else
                    {
                        MessageBox.Show(this, "setup.exe not found at:\n" + setupExe, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
            else
            {
                // Read the step label BEFORE overwriting it, so the dialog can name the step that
                // actually failed rather than the word "Failed".
                string failedAt = lblStep.Text;
                lblStep.Text = "Failed.";
                lblStatus.Text = "Patching failed (exit code " + exitCode + ") - see details below.";
                if (!detailsPanel.Visible) ToggleDetails();

                // The one failure a user can fix right here: the signing key is not on this PC,
                // so the .pfx password is needed. Open the hidden .pfx fields, fill in the .pfx
                // the pipeline would have used if it is the project's default one, and say so.
                string pfxHint = "";
                if (pfxPasswordWasRequired)
                {
                    if (!chkUsePfx.Checked) chkUsePfx.Checked = true;
                    string defaultPfx = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Certificates", "DriverPatchSigning.pfx");
                    if (txtCertPath.Text.Trim().Length == 0 && File.Exists(defaultPfx)) txtCertPath.Text = defaultPfx;
                    pfxHint = "The signing key is not on this PC, so the .pfx password is needed. " +
                              "The .pfx fields are now shown above - enter the password and start again.\n\n";
                }

                if (logPath != null)
                {
                    var open = MessageBox.Show(
                        this,
                        "Patching failed at: " + failedAt + "\n\n" +
                        pfxHint +
                        "The full log of this run was saved to:\n" + logPath + "\n\n" +
                        "Open it now?",
                        "Patching failed",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Error);
                    if (open == DialogResult.Yes) OpenLogFile();
                }
                else
                {
                    MessageBox.Show(this, pfxHint + "Patching failed. See the details panel for the full log.", "Patching failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        /// <summary>
        /// Recognises the pipeline's "the .pfx password is required, but none was supplied and
        /// prompting is disabled" error, which both Invoke-DriverPatchPipeline.ps1 and
        /// Sign-DriverPackage.ps1 raise when the signing key is not on this PC. Keep the phrase in
        /// step with those two messages.
        /// </summary>
        private void NotePfxPasswordRequired(string line)
        {
            if (line.IndexOf("none was supplied and prompting is disabled", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                pfxPasswordWasRequired = true;
            }
        }

        private void SetRunning(bool value)
        {
            running = value;
            SetInputsEnabled(!value);
        }

        private void SetInputsEnabled(bool enabled)
        {
            btnStart.Enabled = enabled;
            txtDriverPath.Enabled = enabled;
            chkUsePfx.Enabled = enabled;
            txtCertPath.Enabled = enabled;
            txtPassword.Enabled = enabled;
            chkAddInstallerOption.Enabled = enabled;
            chkPruneInfs.Enabled = enabled;
            chkOverwrite.Enabled = enabled;
        }

        private Task<int> RunPipelineAsync(string arguments, string password)
        {
            var tcs = new TaskCompletionSource<int>();

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = arguments,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            // An environment variable on the child process, NOT stdin: Read-Host -AsSecureString
            // does not reliably read from a redirected stdin pipe when there's no real attached
            // console (confirmed: it just hangs). The pipeline reads this variable before
            // prompting, so a password reaches it without ever appearing on a command line or in
            // a log line. Only set when the user actually supplied one - the normal store-signing
            // path needs no password, and an empty variable would be pointless noise.
            if (!string.IsNullOrEmpty(password))
            {
                psi.EnvironmentVariables["DRIVER_PATCH_PFX_PASSWORD"] = password;
            }

            var process = new Process { StartInfo = psi, EnableRaisingEvents = true };

            process.OutputDataReceived += (s, e) =>
            {
                if (e.Data == null) return;
                NotePfxPasswordRequired(e.Data);
                // Write to the file from THIS thread, before marshalling to the UI. If the UI
                // thread is busy or wedged, or the app is killed mid-run, the log still has
                // everything the child emitted up to that moment - which is the whole point of
                // having a log rather than just the details panel.
                LogLine("     ", e.Data);
                PostToUi(() =>
                {
                    AppendLog(e.Data);
                    var m = StepRegex.Match(e.Data);
                    if (m.Success)
                    {
                        int current = int.Parse(m.Groups[1].Value);
                        int total = int.Parse(m.Groups[2].Value);
                        progressBar.Value = Math.Min(100, (int)(100.0 * current / total));
                        lblStep.Text = "Step " + current + "/" + total + ": " + m.Groups[3].Value;
                    }
                });
            };
            process.ErrorDataReceived += (s, e) =>
            {
                if (e.Data == null) return;
                NotePfxPasswordRequired(e.Data);
                LogLine("[err]", e.Data);
                PostToUi(() => AppendLog("[stderr] " + e.Data));
            };
            process.Exited += (s, e) =>
            {
                LogLine("[exit]", "child process exited with code " + process.ExitCode);
                tcs.TrySetResult(process.ExitCode);
            };

            try
            {
                process.Start();
            }
            catch (Exception ex)
            {
                // powershell.exe missing or blocked. Previously this threw out of an async void
                // handler and took the app down with no explanation; now it lands in the log and
                // is reported as an ordinary failure.
                LogLine("[err]", "could not start powershell.exe: " + ex.Message);
                PostToUi(() => AppendLog("[stderr] Could not start powershell.exe: " + ex.Message));
                tcs.TrySetResult(-1);
                return tcs.Task;
            }

            pipelineProcess = process;
            LogLine("[proc]", "powershell.exe started, pid " + process.Id);
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            return tcs.Task;
        }
    }
}
