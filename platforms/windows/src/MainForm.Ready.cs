using System;
using System.Drawing;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;
using static Usbless.Theme;

namespace Usbless
{
    sealed partial class MainForm
    {
        // --- Ready ---------------------------------------------------------------------------

        async Task ShowReadyAsync()
        {
            if (startup.CameBack) { await ShowCameBackAsync(); return; }

            int held = HoldScreen();
            InstallSteps installSteps;
            try { installSteps = await engine.GetStepsAsync(); }
            catch (Exception ex)
            {
                if (ReleaseScreen(held)) ShowBlocked(Describe(ex));
                return;
            }
            if (!ReleaseScreen(held)) return;

            steps.Set(installSteps.Steps, installSteps.Notes);
            Arrange(new[]
            {
                new[] { new Run { Text = prepared.Name, Color = Ink, Logo = Logo(prepared.Logo) }, Run.Gray("is ready.") },
            }, installSteps.FullDisk
                ? "Nothing has been erased yet. Restart to open its installer, which erases the disk when you choose that. Until then, Undo changes puts everything back."
                : "Restart to open its installer. These are the choices to make there.", Secondary, steps, installSteps.Notes.Length > 1 ? 24 : 40);
            Footer("Undo changes", () => ShowUndo(() => _ = ShowReadyAsync()), "Restart now", () => _ = RestartIntoInstallerAsync(),
                "Later", Close, Secondary);
        }

        /// <summary>usbless restarted the PC for the installer, and here is Windows again.</summary>
        async Task ShowCameBackAsync()
        {
            int held = HoldScreen();
            InstallSteps help;
            try { help = await engine.GetReturnedHelpAsync(); }
            catch (Exception ex)
            {
                if (ReleaseScreen(held)) ShowBlocked(Describe(ex));
                return;
            }
            if (!ReleaseScreen(held)) return;

            steps.Set(help.Steps, help.Notes);
            Arrange(new[]
            {
                new[] { new Run { Text = prepared.Name, Color = Ink, Logo = Logo(prepared.Logo) }, Run.Gray("isn't installed yet.") },
            }, "The PC is back in Windows, and your setup is still here. If the installer opened and you left it, click Try again. If it didn't open:", Secondary, steps, 32);
            Footer("Undo changes", () => ShowUndo(() => _ = ShowReadyAsync()), "Try again", () => _ = RestartIntoInstallerAsync(),
                "Open BIOS", () => _ = RestartIntoBiosAsync(), Secondary);
        }

        Task RestartIntoInstallerAsync() => RestartAsync(engine.RestartIntoInstallerAsync,
            $"You can also restart yourself and tap {startup.BootKey} while the PC starts, then choose the installer.");

        Task RestartIntoBiosAsync() => RestartAsync(engine.RestartIntoFirmwareAsync, "Restart yourself and tap Delete, F2 or F10 while the PC starts.");

        /// <summary>Windows closes usbless as it restarts. If that's cancelled, the buttons have to come back.</summary>
        async Task RestartAsync(Func<Task> restart, string doItYourself)
        {
            int shown = screen;
            primary.Enabled = secondary.Enabled = footerLink.Enabled = false;
            string problem;
            try
            {
                await restart();
                await Task.Delay(RoomRestartWaitSeconds * 1000);
                problem = "This PC didn't restart. Something stopped Windows restarting. Save your work and try again.";
            }
            catch (Exception ex) { problem = Describe(ex); }
            if (shown != screen) return;
            SayAboveSteps(problem + " " + doItYourself, Danger);
            primary.Enabled = secondary.Enabled = footerLink.Enabled = true;
        }

        /// <summary>A longer note than the screen started with mustn't run into the list under it.</summary>
        void SayAboveSteps(string text, Color color)
        {
            note.Set(text, color);
            if (steps.Visible) PlaceSteps(Math.Max(steps.Top, note.Bottom + S(12)));
        }

        // --- Installed -------------------------------------------------------------------------

        /// <summary>Linux went in from the installer, which is now only taking up space.</summary>
        void ShowInstalled()
        {
            Arrange(new[]
            {
                new[] { new Run { Text = prepared.Name, Color = Ink, Logo = Logo(prepared.Logo) }, Run.Gray("is installed.") },
            }, "The installer is still on this drive and isn't needed any more. Remove it to free the space. Linux stays.", Secondary, null, 0);
            Footer(null, null, "Remove the installer", () => RemoveChanges(true), "Later", Close);
        }

        // --- Undo ----------------------------------------------------------------------------

        void ShowUndo(Action goBack)
        {
            removeAll.Selected = removeInstaller.Selected = false;
            removeAll.Enabled = removeInstaller.Enabled = true;
            Arrange(new[] { new[] { Run.Gray("Remove"), Run.Black("usbless's changes") } },
                "Choose what's true for this PC.", Secondary, removeAll, 32);
            Footer("Back", goBack, "Remove", null);
        }

        void PickUndo(OptionRow row)
        {
            removeAll.Selected = row == removeAll;
            removeInstaller.Selected = row == removeInstaller;
            bool installerOnly = row == removeInstaller;
            primary.Enabled = true;
            onPrimary = () => RemoveChanges(installerOnly);
        }

        /// <summary>Remembers the size of the drive the space came from, because usbless forgets which one it was.</summary>
        void RemoveChanges(bool installerOnly)
        {
            string letter = startup.StateLetter;
            int before = SizeOfDrive(letter);
            _ = CleanupAsync(installerOnly, () => ShowRemoved(installerOnly, letter, before));
        }

        int SizeOfDrive(string letter) => startup.Drives.FirstOrDefault(d => d.Letter == letter)?.SizeGB ?? 0;

        /// <summary>Says what actually happened: the drive may have grown, or the space may just be free.</summary>
        void ShowRemoved(bool installerOnly, string letter, int sizeBefore)
        {
            int grew = SizeOfDrive(letter) - sizeBefore;
            string result = grew > 0 ? $"Drive {letter}: is {grew} GB bigger."
                : engine.SpaceNote != null ? engine.SpaceNote
                : installerOnly ? "The space it used is free, but Windows can't reach it from here."
                : "The space is free on this drive.";
            Arrange(new[] { new[] { Run.Black("Changes removed.") } }, result, Secondary, null, 0);
            Footer("Start over", ShowChoose, "Close", Close);
        }

        void ShowBlocked(string message)
        {
            Arrange(new[] { new[] { Run.Black("usbless can't continue.") } }, message, Secondary, null, 0);
            if (engine != null) Footer("Copy a bug report", () => _ = CopyReportAsync(), "Close", Close);
            else Footer(null, null, "Close", Close);
        }

        /// <summary>The PC, the disk layout, the startup menu and the log, ready to paste into an issue.</summary>
        async Task CopyReportAsync()
        {
            int shown = screen;
            footerLink.Set("Copying…", false, Tertiary, false);
            onLink = null;
            string report;
            try { report = await engine.GetReportAsync(); }
            catch (Exception ex) { report = Describe(ex); }
            try
            {
                Clipboard.SetText(report);
                if (shown == screen) footerLink.Set("Copied. Paste it into a GitHub issue.", false, Tertiary, false);
            }
            catch
            {
                if (shown == screen) footerLink.Set("Couldn't reach the clipboard.", false, Tertiary, false);
            }
        }
    }
}
