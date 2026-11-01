using System;
using System.Diagnostics;
using System.Linq;
using System.Management.Automation;
using System.Threading.Tasks;
using static Usbless.Theme;

namespace Usbless
{
    sealed partial class MainForm
    {
        // --- Working ------------------------------------------------------------------------

        /// <summary>
        /// Shows a long action in progress: the sentence says what is happening, a line
        /// moves underneath, the note follows the engine's status, and the buttons go away.
        /// </summary>
        void BeginWork(Run[][] lines, string firstNote)
        {
            busy = working = true;
            reading = false;
            closeRefused = null;
            engine?.ResetProgress();
            shownStatus = null;
            Arrange(lines, firstNote, Secondary, busyLine, 28);
            Footer(null, null, null, null);
            poll.Start();
        }

        void EndWork()
        {
            poll.Stop();
            busy = working = reading = false;
        }

        /// <summary>The same for work that only reads the PC, which closing usbless can simply stop.</summary>
        void BeginReading(Run[][] lines, string firstNote)
        {
            BeginWork(lines, firstNote);
            reading = true;
        }

        void ShowWorkingStatus()
        {
            string status = engine?.Status;
            if (string.IsNullOrEmpty(status) || status == shownStatus) return;
            shownStatus = status;
            note.Set(status.Replace("...", "…"), Secondary);
            busyLine.Top = note.Bottom + S(28);
        }

        // --- Preparing -------------------------------------------------------------------

        async Task InstallAsync()
        {
            var system = Current;
            engine.Log.Clear();
            engine.ResetProgress();
            log.Clear();
            busy = installing = true;
            closeRefused = null;
            cancelling = false;
            showingLog = false;
            drive.Progress = 0;
            UpdatePreparing();
            poll.Start();
            try
            {
                var download = DownloadSpot;
                await engine.InstallAsync(selected?.Id ?? "custom", isoPath, linuxGB, target.Id, download == null || download.IsDefault ? "" : download.Letter, fullDisk);
                // What usbless knows is from before the install, and Undo has to say what it changed.
                try
                {
                    startup = await engine.GetStartupInfoAsync();
                    target = startup.Drives.FirstOrDefault(d => d.Id == target.Id) ?? WindowsDrive;
                }
                catch (Exception) { }
                poll.Stop();
                busy = installing = false;
                prepared = system;
                await ShowReadyAsync();
            }
            catch (Exception ex)
            {
                poll.Stop();
                busy = installing = false;
                if (cancelling || ex is PipelineStoppedException) { ShowChoose(); return; }
                await ShowFailureAsync(Describe(ex));
            }
        }

        void UpdatePreparing()
        {
            var system = Current;
            int stage = Math.Min(engine.Stage, StageVerbs.Length - 1);
            long bytes = engine.Bytes, total = engine.TotalBytes;
            bool counting = total > 0 && (stage == 1 || stage == 4);

            var weights = isoPath == null ? DownloadWeights : IsoWeights;
            float done = 0, sum = weights.Sum();
            for (int i = 0; i < stage; i++) done += weights[i];
            if (engine.Percent >= 0) done += weights[stage] * engine.Percent / 100f;
            int overall = (int)Math.Min(99, Math.Round(100 * done / sum));

            ConfigureDrive(DriveMode.Progress, system);
            drive.Status = overall + "%";
            drive.Progress = overall / 100f;
            Arrange(new[]
            {
                new[] { Run.Gray("Preparing"), new Run { Text = system.Name, Color = Ink, Logo = LogoFor(selected) } },
                counting
                    ? new[] { Run.Gray(StageVerbs[stage] + ","), Run.Black($"{bytes / 1e9:0.0} of {total / 1e9:0.0} GB") }
                    : new[] { Run.Gray(StageVerbs[stage]) },
            }, closeRefused ?? $"Step {stage + 1} of {StageVerbs.Length}. You can keep using your PC while this runs.", closeRefused != null ? Danger : Secondary, drive, 64);

            SyncLog();

            bool canCancel = stage <= 2 && !cancelling;
            Footer(showingLog ? "Hide details" : "Show details", ToggleLog, null, null,
                canCancel ? "Cancel" : null, canCancel ? (Action)CancelInstall : null);
        }

        int logShown;

        void SyncLog()
        {
            if (log.TextLength == 0) logShown = 0;
            while (logShown < engine.Log.Count)
                log.AppendText(engine.Log[logShown++] + Environment.NewLine);
        }

        void ToggleLog()
        {
            showingLog = !showingLog;
            UpdatePreparing();
        }

        void CancelInstall()
        {
            // Too late if the disk is already changing, and the button goes on the next update.
            if (!engine.TryCancel()) return;
            cancelling = true;
            StopDownload();
            engine.Stop();
        }

        void StopDownload()
        {
            if (!(engine?.Sync["ChildPid"] is int pid)) return;
            try { Process.GetProcessById(pid).Kill(); } catch { }
        }

        async Task ShowFailureAsync(string message)
        {
            var system = Current;
            SyncLog();
            int held = HoldScreen();
            bool changed = false;
            try
            {
                await ReloadAsync();
                changed = startup.Status != "none";
            }
            catch { }
            if (!ReleaseScreen(held)) return;

            Arrange(new[]
            {
                new[] { Run.Gray("Couldn't prepare"), new Run { Text = system.Name, Color = Ink, Logo = LogoFor(selected) } },
                new[] { Run.Red("Something went wrong.") },
            }, message, Secondary, log, 40);
            // The engine undoes its own changes after a failure; if something is still left, offer to clean up.
            if (changed) Footer("Copy a bug report", () => _ = CopyReportAsync(), "Clean up", ShowLeftover);
            else Footer("Copy a bug report", () => _ = CopyReportAsync(), "Try again", ShowChoose);
        }
    }
}
