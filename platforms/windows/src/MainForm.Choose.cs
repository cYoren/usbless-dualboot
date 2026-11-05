using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;
using static Usbless.Theme;

namespace Usbless
{
    sealed partial class MainForm
    {
        // --- Choose -----------------------------------------------------------------------

        const int StuckWorthExplainingGB = 20;
        const int RoomRestartWaitSeconds = 60;

        const string WindowsLetter = "C";

        string roomLetter;  // Make room has run on this drive, and its settings go back on when usbless closes

        bool roomMade => roomLetter != null;

        bool RoomMadeHere => roomLetter != null && roomLetter == target.Letter;

        /// <summary>Linux's room on the chosen drive, less the download if that's going there too.</summary>
        int MaxLinuxGB => MaxLinuxGBOn(target);

        int MaxLinuxGBOn(DriveChoice drive)
        {
            var download = DownloadSpotFor(drive);
            bool downloadHere = isoPath == null && (download != null ? download.Letter == drive.Letter : drive.IsWindows);
            return drive.UsableGB - ExpectedInstallerGB - (downloadHere ? IsoDownloadGB : 0);
        }

        /// <summary>What the engine will make. A download's real size isn't known until it's here.</summary>
        int ExpectedInstallerGB
        {
            get
            {
                if (isoPath == null) return InstallerGB;
                try { return Engine.InstallerGBFor(new FileInfo(isoPath).Length); }
                catch (Exception) { return InstallerGB; }
            }
        }

        DownloadDrive DownloadSpot => DownloadSpotFor(target);

        /// <summary>
        /// The Downloads folder as ever, unless it's short of room, or filling it would leave
        /// too little for Linux. Then whichever other drive has the most free.
        /// </summary>
        DownloadDrive DownloadSpotFor(DriveChoice drive)
        {
            var drives = startup.DownloadDrives;
            if (isoPath != null || drives == null || drives.Count == 0) return null;
            var picked = drives.FirstOrDefault(d => d.Letter == pickedDownload);
            if (picked != null) return picked;

            int room = IsoDownloadGB + 1;
            var usual = drives.FirstOrDefault(d => d.IsDefault);
            var other = drives.Where(d => d.Letter != drive.Letter && d.FreeGB >= room).OrderByDescending(d => d.FreeGB).FirstOrDefault();
            bool squeezes = usual != null && usual.Letter == drive.Letter && drive.UsableGB - InstallerGB - IsoDownloadGB < MinLinuxGB;
            if (usual != null && usual.FreeGB >= room && !(squeezes && other != null)) return usual;
            return other ?? usual;
        }

        /// <summary>What usbless can fall back on if it can't list the drives: the same C: as ever.</summary>
        DriveChoice WindowsDrive => startup.Drives.FirstOrDefault(d => d.IsWindows) ?? startup.WindowsFallback;

        /// <summary>C: as ever, unless Make room is part way through elsewhere, or C: can't be used at all.</summary>
        async Task ChooseFirstTargetAsync()
        {
            target = startup.Drives.FirstOrDefault(d => !string.IsNullOrEmpty(startup.RoomLetter) && d.Letter == startup.RoomLetter) ?? WindowsDrive;
            if (target.Blocker != null)
                target = startup.Drives.FirstOrDefault(d => d.Blocker == null) ?? target;
            await MeasureTargetAsync();
        }

        string measureError;   // why Windows couldn't say how far the chosen drive shrinks

        /// <summary>
        /// Windows is only asked how far a drive really shrinks once it has been chosen, because that
        /// can take a while. Not knowing only stops installing there: it must not hide Undo.
        /// </summary>
        async Task MeasureTargetAsync()
        {
            measureError = null;
            if (!target.Estimated || target.Blocker != null) return;
            try
            {
                target = await engine.GetDriveSpaceAsync(target.Id);
                DriveChoice.Remember(startup.Drives, target);
            }
            catch (Exception ex) { measureError = Describe(ex); }
        }

        /// <summary>Reads the PC again and keeps the same drive chosen, if it's still there.</summary>
        async Task ReloadAsync()
        {
            startup = await engine.GetStartupInfoAsync();
            target = startup.Drives.FirstOrDefault(d => d.Id == target?.Id) ?? WindowsDrive;
            await MeasureTargetAsync();
        }

        /// <summary>Another drive with room for Linux, for when this one hasn't any.</summary>
        DriveChoice BetterDrive => startup.Drives
            .Where(d => d.Id != target.Id && d.Blocker == null && MaxLinuxGBOn(d) >= MinLinuxGB && !SecondDiskStops(d))
            .OrderByDescending(d => d.UsableGB).FirstOrDefault();

        bool HasDriveChoice => FullDiskOffered || startup.Drives.Count > 1 || (isoPath == null && startup.DownloadDrives.Count(d => d.FreeGB > IsoDownloadGB) > 1);

        bool SecondDiskStops(DriveChoice drive) => selected != null && selected.WindowsDiskOnly && !drive.OnWindowsDisk;

        Run[] WhereLine(bool picker, Color brand)
        {
            if (!HasDriveChoice)
                return new[] { Run.Gray("next to Windows, with"), Run.Black(linuxGB + " GB") };
            string size = linuxGB + " GB";
            return new[]
            {
                Run.Gray("on"),
                new Run { Text = sentence.FitName(target.Kind == "disk" ? target.Title : target.InSentence, picker, "on", "with", size), Color = Ink, Picker = picker, Underline = brand },
                Run.Gray("with"),
                Run.Black(size),
            };
        }

        void ShowChoose()
        {
            fullDisk = false;
            var system = Current;
            bool usable = target.Blocker == null;
            bool enoughSpace = usable && MaxLinuxGB >= MinLinuxGB;
            bool secureBootStops = selected != null && selected.SecureBootOff && startup.SecureBoot;
            bool secondDiskStops = usable && SecondDiskStops(target);
            bool unmeasured = usable && target.Estimated && measureError != null;
            bool refused = selected != null && selected.Refused != null;
            bool systemStops = refused || secureBootStops || secondDiskStops || unmeasured;
            linuxGB = enoughSpace ? Math.Max(MinLinuxGB, Math.Min(MaxLinuxGB, linuxGB)) : MinLinuxGB;

            // The drive has the room, but Windows can't release it. Deleting files wouldn't help.
            bool stuck = usable && !enoughSpace && !target.IsFreeSpace && MaxLinuxGB + target.StuckGB >= MinLinuxGB;
            var better = enoughSpace ? null : BetterDrive;
            bool otherDrive = startup.Drives.Any(d => d.Id != target.Id);

            string noteText;
            if (!usable)
                noteText = target.Blocker;
            else if (refused)
                noteText = selected.Refused;
            else if (secureBootStops)
                noteText = $"{system.Name} doesn't start with Secure Boot on. Pick another system, or turn off Secure Boot in the BIOS and open usbless again.";
            else if (secondDiskStops)
                noteText = $"usbless hasn't got {system.Name} to finish on a second disk yet. Choose a drive on the disk Windows is on, or another system.";
            else if (unmeasured)
                noteText = $"usbless couldn't work out how much room {target.InSentence} can give up. {measureError} {(otherDrive ? "Choose another drive, or open usbless again." : "Open usbless again.")}";
            else if (stuck)
                noteText = StuckNote(better);
            else if (!enoughSpace && better != null)
                noteText = $"{target.Title} doesn't have room for Linux. {better.Title} on {better.DiskName} has {(better.Estimated ? "about " : "")}{better.UsableGB} GB to spare.";
            else if (!enoughSpace && target.IsFreeSpace)
                noteText = $"This free space is about {MinLinuxGB - MaxLinuxGB} GB too small. Choose another drive.";
            else if (!enoughSpace)
                noteText = $"{target.Title} needs about {MinLinuxGB - MaxLinuxGB} GB more free space. Delete some files or empty the Recycle Bin, then open usbless again.";
            else if (isoPath != null)
                noteText = $"Your file, {Path.GetFileName(isoPath)}. Nothing on your disk changes until you click Install.";
            else
            {
                var download = DownloadSpot;
                string saved = download != null && !download.IsDefault ? $" to drive {download.Letter}:" : "";
                noteText = $"{system.Name}{(system.Version != null ? " " + system.Version : "")}, downloaded from {system.Source}{saved}. Nothing on your disk changes until you click Install.";
            }

            // Nothing has gone wrong yet if usbless can still clear the way, so it doesn't read as an error.
            bool calm = (enoughSpace || (stuck && (!RoomMadeHere || target.BlockerKind == "restore"))) && !systemStops;
            ConfigureDrive(stuck ? DriveMode.Stuck : DriveMode.Edit, system);
            Arrange(new[]
            {
                new[] { Run.Gray("Install"), new Run { Text = system.Name, Color = Ink, Logo = LogoFor(selected), Picker = true, Underline = system.Color } },
                WhereLine(true, Hairline),
            }, noteText, calm ? Secondary : Danger, usable ? drive : null, 64);

            Action install = enoughSpace && !systemStops ? () => _ = CheckThenConfirmAsync() : (Action)null;
            string primaryText = "Install";
            Action primaryAction = install;
            // Nothing else can happen until there's room, so this is what the button does.
            bool needRoom = stuck && !RoomMadeHere && !systemStops;
            if (better != null && !systemStops)
            {
                primaryText = $"Use {better.InSentence}";
                primaryAction = () => _ = UseDriveAsync(better);
            }
            else if (needRoom)
            {
                primaryText = "Make room";
                primaryAction = () => _ = ShowMakeRoomAsync();
            }

            if (startup.OtherGB > 0)
                Footer($"Remove {startup.OtherName} ({startup.OtherGB} GB)", ShowRemoveOther, primaryText, primaryAction);
            else if (!usable || secondDiskStops || unmeasured)
                Footer(otherDrive ? "Choose another drive" : null, otherDrive ? OpenDrivePicker : (Action)null, primaryText, primaryAction);
            else if (needRoom && better != null)
                Footer("Make room", () => _ = ShowMakeRoomAsync(), primaryText, primaryAction);
            else if (target.TailFreeGB > 0 && !target.IsFreeSpace)
                Footer($"Give the free {target.TailFreeGB} GB to {(target.IsWindows ? "Windows" : target.InSentence)}", () => _ = ExpandWindowsAsync(), primaryText, primaryAction);
            else if (!stuck && target.StuckGB >= StuckWorthExplainingGB && !RoomMadeHere)
                Footer("Make room", () => _ = ShowMakeRoomAsync(), primaryText, primaryAction);
            else if ((stuck || target.StuckGB >= StuckWorthExplainingGB) && target.BlockerKind == "restore")
                Footer("Delete restore points", ShowDeleteRestorePoints, primaryText, primaryAction);
            else
                Footer("Windows and your files stay.", null, primaryText, primaryAction);
        }

        string StuckNote(DriveChoice better)
        {
            int release = Math.Max(0, target.UsableGB);
            if (!RoomMadeHere)
                return better == null
                    ? $"{target.Title} has room, but Windows can't release it yet. usbless can clear what's in the way."
                    : $"{target.Title} has room, but Windows can't release it yet. Make room clears what's in the way, or use {better.InSentence}, which has {(better.Estimated ? "about " : "")}{better.UsableGB} GB to spare.";
            if (target.BlockerKind == "restore")
                return $"usbless can use {release} GB. Restore points on {target.InSentence} are stopping Windows releasing more.";
            return $"usbless made what room it could, and can use {release} GB. Windows can't move {target.ShrinkBlocker ?? "some system files"}, which limits the rest.";
        }

        // --- Choosing a drive -------------------------------------------------------------

        void OpenDrivePicker()
        {
            if (busy) return;
            var rows = startup.Drives;
            if (rows.Count == 0) return;
            var items = rows.Select(d => new PickerItem
            {
                Name = d.Title,
                Note = d.Blocker != null ? (d.Kind == "disk" ? "Can't be used" : $"{d.DiskName} · Can't be used")
                    : $"{d.DiskName} · {(d.Estimated ? "about " : "")}{d.UsableGB} GB to spare",
                Dimmed = d.Blocker != null,
            }).ToList();
            // After every drive, and never chosen by itself: it's on a screen of its own from here.
            if (FullDiskOffered) items.Add(new PickerItem { Name = "Replace Windows", Note = "Erases the whole disk" });
            var downloads = isoPath == null ? startup.DownloadDrives.Where(d => d.FreeGB > IsoDownloadGB).ToList() : new List<DownloadDrive>();
            var spot = DownloadSpot;
            string footer = downloads.Count > 1 && spot != null ? $"Save the download on drive {spot.Letter}:…" : null;
            var picker = new ListPicker(items, rows.FindIndex(d => d.Id == target.Id), footer, 460);
            picker.Picked += i =>
            {
                if (i < rows.Count) _ = UseDriveAsync(rows[i]);
                else _ = ReplaceWindowsAsync();
            };
            picker.FooterClicked += () => OpenDownloadPicker(downloads);
            var anchor = sentence.PickerScreenBounds(1);
            picker.Show(new Point(anchor.Left - S(13), anchor.Bottom + S(8)));
        }

        void OpenDownloadPicker(List<DownloadDrive> downloads)
        {
            var items = downloads.Select(d => new PickerItem
            {
                Name = $"Drive {d.Letter}:",
                Note = (d.IsDefault ? "Your Downloads folder · " : "") + $"{d.FreeGB} GB free",
            }).ToList();
            var picker = new ListPicker(items, downloads.FindIndex(d => d.Letter == DownloadSpot?.Letter), null, 400);
            picker.Picked += i =>
            {
                pickedDownload = downloads[i].Letter;
                ShowChoose();
            };
            var anchor = sentence.PickerScreenBounds(1);
            picker.Show(new Point(anchor.Left - S(13), anchor.Bottom + S(8)));
        }

        async Task UseDriveAsync(DriveChoice choice)
        {
            if (choice.Blocker != null || !choice.Estimated)
            {
                target = choice;
                ShowChoose();
                return;
            }
            BeginReading(new[] { new[] { Run.Gray("Checking"), Run.Black(choice.InSentence) } }, "Asking Windows how much room it can give up. This can take a minute on a big drive.");
            try
            {
                target = await engine.GetDriveSpaceAsync(choice.Id);
                DriveChoice.Remember(startup.Drives, target);
                EndWork();
                ShowChoose();
            }
            catch (Exception ex)
            {
                EndWork();
                Arrange(new[] { new[] { Run.Gray("Couldn't check"), Run.Black(choice.InSentence) } }, Describe(ex), Danger, null, 0);
                Footer("Back", ShowChoose, null, null);
            }
        }

        async Task ShowMakeRoomAsync()
        {
            int held = HoldScreen();
            InstallSteps plan;
            try { plan = await engine.GetMakeRoomStepsAsync(target.Letter); }
            catch (Exception ex)
            {
                if (ReleaseScreen(held)) ShowBlocked(Describe(ex));
                return;
            }
            if (!ReleaseScreen(held)) return;

            string title = target.InSentence;
            ConfigureDrive(DriveMode.Stuck, Current);
            steps.Set(plan.Steps, null);
            Arrange(new[] { new[] { Run.Black($"{target.StuckGB} GB"), Run.Gray($"is stuck on {title}") } },
                $"Windows can only shrink {title} as far as the last file it can't move. usbless can clear the way.", Secondary, drive, 24);
            PlaceSteps(drive.Bottom + S(24));
            steps.Visible = true;
            Footer(plan.Notes.FirstOrDefault(), null, plan.Restart ? "Make room and restart" : "Make room", () => _ = MakeRoomAsync(), "Back", ShowChoose);
        }

        async Task MakeRoomAsync()
        {
            BeginWork(new[] { new[] { Run.Gray("Making"), Run.Black("room") } }, "Starting…");
            roomLetter = null;   // the engine puts back any earlier run before it starts
            try
            {
                // The restart is on its way, and Windows closes usbless. Only another drive gets past this.
                if (await engine.StartMakeRoomAsync(target.Letter))
                {
                    await WaitForRoomRestartAsync();
                    return;
                }
                roomLetter = target.Letter;
                await ReloadAsync();
                EndWork();
                ShowChoose();
            }
            catch (Exception ex)
            {
                EndWork();
                ShowCouldntMakeRoom(ex);
            }
        }

        /// <summary>Windows closes usbless as it restarts. If that's cancelled, usbless mustn't say "Restarting" for good.</summary>
        async Task WaitForRoomRestartAsync()
        {
            await Task.Delay(RoomRestartWaitSeconds * 1000);
            EndWork();
            ShowRoomRestartStopped(null);
        }

        void ShowRoomRestartStopped(string problem)
        {
            roomLetter = target.Letter;   // so closing usbless now puts its settings back
            Arrange(new[] { new[] { Run.Gray("This PC"), Run.Black("didn't restart.") } },
                problem ?? "Something stopped Windows restarting, so usbless hasn't finished making room. Save your work and restart, or go back and usbless puts its settings back.",
                problem == null ? Secondary : Danger, null, 0);
            Footer("Back", () => _ = CancelRoomRestartAsync(), "Restart now", () => _ = RetryRoomRestartAsync());
        }

        async Task RetryRoomRestartAsync()
        {
            BeginWork(new[] { new[] { Run.Gray("Making"), Run.Black("room") } }, "Starting…");
            try
            {
                await engine.RestartForRoomAsync();
                await WaitForRoomRestartAsync();
            }
            catch (Exception ex)
            {
                EndWork();
                ShowRoomRestartStopped(Describe(ex));
            }
        }

        Task CancelRoomRestartAsync() => WorkThenChooseAsync(new[] { new[] { Run.Gray("Putting"), Run.Black("settings back") } },
            async () =>
            {
                await engine.RestoreRoomSettingsAsync();
                roomLetter = null;
            },
            ex => ShowRoomRestartStopped(Describe(ex)));

        /// <summary>Changes something on the PC, reads it again and goes back to choosing.</summary>
        async Task WorkThenChooseAsync(Run[][] lines, Func<Task> work, Action<Exception> failed)
        {
            BeginWork(lines, "Starting…");
            try
            {
                await work();
                await ReloadAsync();
                EndWork();
                ShowChoose();
            }
            catch (Exception ex)
            {
                EndWork();
                failed(ex);
            }
        }

        void ShowCouldntMakeRoom(Exception ex)
        {
            Arrange(new[] { new[] { Run.Gray("Couldn't"), Run.Black("make room") } }, Describe(ex), Danger, null, 0);
            Footer("Back", ShowChoose, null, null);
        }

        void ShowDeleteRestorePoints()
        {
            Arrange(new[] { new[] { Run.Gray("Delete"), Run.Black("restore points?") } },
                $"They're stopping Windows releasing more of {target.InSentence}. This deletes the ones on {target.Letter}: for good, and can't be undone. Your files aren't touched, and Windows makes new ones later.",
                Secondary, null, 0);
            Footer("Back", ShowChoose, "Delete them", () => _ = DeleteRestorePointsAsync());
        }

        Task DeleteRestorePointsAsync() => WorkThenChooseAsync(new[] { new[] { Run.Gray("Making"), Run.Black("room") } },
            () => engine.ClearRestorePointsAsync(target.Letter), ShowCouldntMakeRoom);

        void ConfigureDrive(DriveMode mode, Distro system)
        {
            drive.Mode = mode;
            drive.FitToMode();
            drive.InstallerGB = ExpectedInstallerGB;
            drive.ReleaseGB = Math.Max(0, target.UsableGB);
            drive.StuckFile = FileNameOf(target.ShrinkBlocker);
            drive.DiskName = target.DiskName ?? "";
            drive.DriveTitle = target.Title;
            drive.DriveLabel = target.IsWindows ? "Windows" : target.Title;
            drive.IsFreeSpace = target.IsFreeSpace;
            drive.WindowsGB = target.IsFreeSpace ? 0 : Math.Max(1, target.SizeGB);
            drive.TailFreeGB = target.TailFreeGB;
            drive.UsedGB = target.UsedGB;
            drive.SystemName = system.Name;
            drive.Brand = system.Color;
            // Replacing Windows only makes the installer. Windows stays until the Linux installer erases it.
            drive.Legend = fullDisk ? $"Installer · about {InstallerGB} GB. Windows stays until the Linux installer erases it" : null;
            drive.MinLinuxGB = fullDisk ? 0 : MinLinuxGB;
            drive.MaxLinuxGB = Math.Max(drive.MinLinuxGB, MaxLinuxGB);
            drive.LinuxGB = fullDisk ? 0 : linuxGB;
            drive.Invalidate();
        }

        /// <summary>Windows names it by its whole path, which can be too long for the header.</summary>
        static string FileNameOf(string path) => string.IsNullOrEmpty(path) ? null : path.Substring(path.LastIndexOf('\\') + 1);

        void OpenPicker()
        {
            if (busy || catalog == null) return;
            var items = catalog.Select(d => new PickerItem { Name = d.Name, Note = d.Note, Logo = d.Logo }).ToList();
            var picker = new ListPicker(items, catalog.IndexOf(selected), "Use an ISO file…");
            picker.Picked += i =>
            {
                selected = catalog[i];
                isoPath = null;
                ShowChoose();
            };
            picker.FooterClicked += ChooseIso;
            var anchor = sentence.PickerScreenBounds(0);
            picker.Show(new Point(anchor.Left - S(13), anchor.Bottom + S(8)));
        }

        void ChooseIso()
        {
            using (var dialog = new OpenFileDialog { Filter = "ISO files (*.iso)|*.iso", Title = "Choose an Ubuntu-based ISO file" })
            {
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                isoPath = dialog.FileName;
                selected = null;
                ShowChoose();
            }
        }

        /// <summary>Anything worth checking comes first. Checked now, not at startup: the charger may have come out since.</summary>
        Task CheckThenConfirmAsync() => CheckThenAsync(target.Id, ShowConfirm);

        async Task CheckThenAsync(string place, Action next)
        {
            int held = HoldScreen();
            string[] warnings;
            try { warnings = await engine.GetWarningsAsync(place); }
            catch { warnings = new string[0]; }
            if (!ReleaseScreen(held)) return;
            if (warnings.Length == 0) { next(); return; }

            steps.Set(warnings, null);
            Arrange(new[] { new[] { Run.Gray("Before you"), Run.Black("start") } },
                "usbless can go ahead, but check these first.", Secondary, steps, 32);
            Footer("Back", ShowChoose, "Continue", next);
            primary.Focus();
        }

        // --- Replacing Windows ------------------------------------------------------------
        // Nothing changes on the PC until the last of these, and usbless never erases anything: it
        // makes the usual installer, and the Linux installer erases the disk if told to there.

        bool FullDiskOffered => selected != null && selected.FullDisk && isoPath == null;

        /// <summary>Checks first and says plainly why not. Only reads the PC.</summary>
        async Task ReplaceWindowsAsync()
        {
            var system = Current;
            BeginReading(new[] { new[] { Run.Gray("Checking"), Run.Black("this PC") } }, "Seeing what replacing Windows would mean here.");
            FullDiskPlan plan;
            try { plan = await engine.GetFullDiskPlanAsync(system.Id, target.Id); }
            catch (Exception ex) { EndWork(); ShowCantReplaceWindows(Describe(ex)); return; }
            EndWork();

            if (plan.Blocker != null) { ShowCantReplaceWindows(plan.Blocker); return; }
            if (plan.Target.Blocker != null) { ShowCantReplaceWindows(plan.Target.Blocker); return; }
            int short_ = -MaxLinuxGBOn(plan.Target);
            if (short_ > 0) { ShowCantReplaceWindows($"Windows can't release enough space from {plan.Target.InSentence} for the installer. It needs {short_} GB more. Delete some files, or install next to Windows if you can make room."); return; }
            await CheckThenAsync(plan.Target.Id, () => ShowReplaceWarning(plan));
        }

        void ShowCantReplaceWindows(string reason)
        {
            Arrange(new[] { new[] { Run.Gray("Can't replace"), Run.Black("Windows") } }, reason, Secondary, null, 0);
            Footer("Back", ShowChoose, null, null);
        }

        string DiskOf(FullDiskPlan plan) => $"{plan.DiskName} ({plan.DiskGB} GB)";

        string StopsNote(FullDiskPlan plan) => plan.StopsStarting != null && plan.StopsStarting.Length > 0
            ? $" {string.Join(", ", plan.StopsStarting)} will stop starting too." : "";

        void ShowReplaceWarning(FullDiskPlan plan)
        {
            var system = Current;
            steps.Set(plan.Points, null);
            Arrange(new[]
            {
                new[] { Run.Gray("Replace"), Run.Black("Windows"), Run.Gray("with"), new Run { Text = system.Name, Color = Ink, Logo = LogoFor(selected) } },
            }, $"Windows and every file on {DiskOf(plan)} will be erased. They can't be recovered.{StopsNote(plan)}", Danger, steps, 24);
            Footer("Back", ShowChoose, "Continue", () => ShowReplaceConfirm(plan));
        }

        /// <summary>Typing the word is the one thing that can't happen by accident, so nothing else starts this.</summary>
        void ShowReplaceConfirm(FullDiskPlan plan)
        {
            const string word = "ERASE";
            var system = Current;
            Arrange(new[] { new[] { Run.Gray("Type"), Run.Black(word), Run.Gray("to confirm") } },
                $"usbless will set up {system.Name} to erase Windows and every file on {DiskOf(plan)}. They can't be recovered.{StopsNote(plan)}", Danger, eraseWord, 28);
            eraseWord.Font = Theme.Font(15);
            eraseWord.Text = "";
            onEraseWord = () => primary.Enabled = eraseWord.Text == word;
            Footer("Back", () => ShowReplaceWarning(plan), "Prepare the installer", () =>
            {
                if (eraseWord.Text != word) return;
                fullDisk = true;
                target = plan.Target;
                _ = InstallAsync();
            }, "Cancel", ShowChoose);
            primary.Enabled = false;
            eraseWord.Focus();
        }

        /// <summary>Install asks once more, in place, before touching the disk.</summary>
        void ShowConfirm()
        {
            var system = Current;
            ConfigureDrive(DriveMode.Static, system);
            Arrange(new[]
            {
                new[] { Run.Gray("Install"), new Run { Text = system.Name, Color = Ink, Logo = LogoFor(selected) } },
                WhereLine(false, Background),
            }, ConfirmNote(), Ink, drive, 64);
            Footer("Back", ShowChoose, "Start", () => _ = InstallAsync());
            primary.Focus();
        }

        string ConfirmNote()
        {
            int installer = ExpectedInstallerGB;
            int shrink = Math.Max(0, linuxGB + installer - target.TailFreeGB);
            string title = target.InSentence;
            string keeps = target.IsFreeSpace ? "nothing on this drive shrinks" : target.IsWindows ? "Windows keeps its size" : $"{title} keeps its size";
            // Free space can't shrink anything, and the engine stops if it's too small. A download could still need more than this.
            string unless = isoPath == null && !target.IsFreeSpace ? $", unless the installer turns out bigger than {InstallerGB} GB" : "";
            string room = shrink == 0
                ? $"usbless will use about {linuxGB + installer} GB of free space, so {keeps}{unless}. It copies the installer there"
                : target.TailFreeGB > 0
                    ? $"usbless will use {target.TailFreeGB} GB of free space and shrink {title} by about {shrink} GB, copy the installer there"
                    : $"usbless will shrink {title} by about {shrink} GB, copy the installer there";
            return room + " and add it to the startup menu. Keep the charger connected until it finishes.";
        }
    }
}
