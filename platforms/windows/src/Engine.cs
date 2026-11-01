using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Text;
using System.Threading.Tasks;

namespace Usbless
{
    public sealed class Distro
    {
        public string Id;
        public string Name;
        public string Version;
        public string Note;
        public string Source;
        public string Logo;
        public bool SecureBootOff;      // can't start with Secure Boot on
        public bool FullDisk;           // shown to work replacing Windows
        public bool WindowsDiskOnly;    // its steps are only for the disk Windows is on
        public int MinGB;               // the least its installer accepts, if more than usbless's own least
        public string Refused;          // why it can't go next to Windows or on a second disk
        public System.Drawing.Color Color;
    }

    /// <summary>What replacing Windows would mean on this PC, or why it can't be done.</summary>
    public sealed class FullDiskPlan
    {
        public string Blocker;          // why not, or null
        public DriveChoice Target;      // where the installer goes: always on Windows' disk
        public string DiskName;
        public int DiskGB;
        public string[] Points;         // what the warning says
        public string[] StopsStarting;  // other systems that start from the EFI partition on this disk
    }

    /// <summary>One place Linux could go, or a drive it can't go on and why.</summary>
    public sealed class DriveChoice
    {
        public string Id;               // what the engine calls it; "" is C:
        public string Kind;             // "volume", "gap" (free space) or "disk" (a whole disk that's refused)
        public string Letter;
        public string Title;            // "Drive D:", "Free space"
        public string Blocker;          // why it can't be used, or null
        public string DiskName;
        public bool OnWindowsDisk;
        public bool Estimated;          // only from its free space; Windows hasn't been asked how far it shrinks
        public int SizeGB;
        public int UsedGB;
        public int TailFreeGB;          // unallocated space right after it
        public int UsableGB;            // how much it can give up while keeping its reserve
        public int StuckGB;             // free on it, but Windows can't release it
        public string ShrinkBlocker;    // the file in the way, as Windows names it
        public string BlockerKind;      // hibernation, paging, restore, journal, ntfs, file or unknown

        public bool IsFreeSpace => Kind == "gap";

        /// <summary>The title in the middle of a sentence: "drive C:", keeping the letter a capital.</summary>
        public string InSentence => char.ToLowerInvariant(Title[0]) + Title.Substring(1);
        public bool IsWindows => Id == "";

        /// <summary>Keeps a drive's real figures, so that it isn't suggested again on its estimate.</summary>
        public static void Remember(List<DriveChoice> drives, DriveChoice measured)
        {
            int at = drives.FindIndex(d => d.Id == measured.Id);
            if (at >= 0) drives[at] = measured;
        }
    }

    public sealed class DownloadDrive
    {
        public string Letter;
        public int FreeGB;
        public bool IsDefault;          // holds the user's Downloads folder
    }

    public sealed class StartupInfo
    {
        public DriveChoice WindowsFallback;   // C: on its own, for when the drives can't be listed
        public string RoomPhase;        // Make room: "continue" after its restart, "restore" if it stopped early
        public string OtherName;        // another Linux on this PC, such as Pond
        public int OtherGB;
        public bool OtherOnWindowsDisk;
        public string[] OtherKept;      // startup entries usbless can't tie to it, which stay
        public List<DriveChoice> Drives;
        public List<DownloadDrive> DownloadDrives;
        public string RoomLetter;       // the drive Make room is working on
        public string StateLetter;      // the drive a setup took its space from, if it took any
        public bool StateDiskMissing;   // that setup's disk isn't connected
        public string[] Leftovers;      // what Clean up would delete, in words
        public string Status;           // "ready", "leftover" (from an attempt that didn't finish) or "none"
        public string PreparedDistro;   // set when an installer is ready
        public string PreparedId;
        public bool CameBack;           // restarted for the installer, and Windows started instead
        public bool SecureBoot;
        public string BootKey;          // the key that opens this PC's boot menu
    }

    public sealed class InstallSteps
    {
        public string[] Steps;
        public string[] Notes;
        public bool Restart;            // Make room: the PC restarts
        public bool FullDisk;           // the installer is there to replace Windows
    }

    /// <summary>
    /// Decides the race between Cancel and the first change to the disk: exactly one of them
    /// wins, so a stop can never land in the middle of making partitions.
    /// </summary>
    public sealed class CancelGate
    {
        readonly object gate = new object();
        bool cancelled, diskChanging;

        public bool TryCancel()
        {
            lock (gate)
            {
                if (diskChanging) return false;
                return cancelled = true;
            }
        }

        public bool EnterDiskStage()
        {
            lock (gate)
            {
                if (cancelled) return false;
                return diskChanging = true;
            }
        }
    }

    /// <summary>
    /// Runs the engine\ scripts in an in-process PowerShell runspace. Calls are
    /// serialized; progress is shared through <see cref="Sync"/>.
    /// </summary>
    public sealed class Engine : IDisposable
    {
        readonly Runspace runspace;
        readonly object gate = new object();
        volatile PowerShell running;

        public readonly Hashtable Sync = Hashtable.Synchronized(new Hashtable());
        public readonly ArrayList Log = ArrayList.Synchronized(new ArrayList());

        /// <summary>The installer partition Read-Iso makes for an ISO of this size. Files on an ISO add up to a little less than the ISO.</summary>
        public static int InstallerGBFor(long isoBytes) =>
            (int)Math.Max(4, Math.Ceiling((isoBytes + 512.0 * 1024 * 1024) / (1024.0 * 1024 * 1024)));

        public Engine()
        {
            Sync["Log"] = Log;
            Sync["Version"] = typeof(Engine).Assembly.GetName().Version.ToString(3);
            ResetProgress();

            var session = InitialSessionState.CreateDefault();
            session.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            runspace = RunspaceFactory.CreateRunspace(session);
            runspace.Open();
            runspace.SessionStateProxy.SetVariable("Sync", Sync);

            using (var ps = PowerShell.Create())
            {
                ps.Runspace = runspace;
                ps.AddScript(ReadEngineScript(), useLocalScope: false).Invoke();
            }
        }

        // Every engine\*.ps1 is embedded. Common comes first: it sets what the others use.
        static string ReadEngineScript()
        {
            var assembly = typeof(Engine).Assembly;
            var modules = assembly.GetManifestResourceNames()
                .Where(name => name.StartsWith("Usbless.Engine.") && name.EndsWith(".ps1"))
                .OrderBy(name => name == "Usbless.Engine.Common.ps1" ? 0 : 1).ThenBy(name => name, StringComparer.Ordinal);
            var script = new StringBuilder();
            foreach (var name in modules)
                using (var reader = new StreamReader(assembly.GetManifestResourceStream(name)))
                    script.AppendLine(reader.ReadToEnd());
            return script.ToString();
        }

        public void ResetProgress()
        {
            Sync["Gate"] = new CancelGate();
            Sync["ChildPid"] = null;
            Sync["Status"] = "";
            Sync["Percent"] = -1;
            Sync["Stage"] = 0;
            Sync["Bytes"] = 0L;
            Sync["TotalBytes"] = 0L;
        }

        public string Status => Sync["Status"] as string ?? "";
        public int Percent => Convert.ToInt32(Sync["Percent"]);
        public int Stage => Convert.ToInt32(Sync["Stage"]);
        public long Bytes => Convert.ToInt64(Sync["Bytes"] ?? 0L);
        public long TotalBytes => Convert.ToInt64(Sync["TotalBytes"] ?? 0L);
        public string SpaceNote => Sync["SpaceNote"] as string;   // why Undo left the space free, if it had to
        public bool RoomRestarting => Sync["RoomRestarting"] is bool restarting && restarting;

        Collection Invoke(string command, IDictionary parameters = null)
        {
            lock (gate)
            {
                using (var ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    ps.AddCommand(command);
                    if (parameters != null) ps.AddParameters(parameters);
                    running = ps;
                    try { return new Collection(ps.Invoke()); }
                    catch (Exception ex) when (!(ex is PipelineStoppedException)) { LogStop(ex); throw; }
                    finally { running = null; }
                }
            }
        }

        // The reason something stopped belongs in the bug report, not just on the screen.
        void LogStop(Exception ex)
        {
            try
            {
                using (var ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    ps.AddCommand("Write-Log").AddParameter("Message", "Stopped: " + ex.Message).Invoke();
                }
            }
            catch (Exception) { }
        }

        Task<Collection> InvokeAsync(string command, IDictionary parameters = null) =>
            Task.Run(() => Invoke(command, parameters));

        public List<Distro> GetCatalog() =>
            Invoke("Get-Catalog").Items.Select(o => new Distro
            {
                Id = Get<string>(o, "Id"),
                Name = Get<string>(o, "Name"),
                Version = Get<string>(o, "Version"),
                Note = Get<string>(o, "Note"),
                Source = Get<string>(o, "Source"),
                Logo = Get<string>(o, "Logo"),
                SecureBootOff = Get<bool>(o, "SecureBootOff"),
                Refused = Get<string>(o, "Refused"),
                FullDisk = o.Properties["FullDisk"]?.Value != null,
                WindowsDiskOnly = o.Properties["Steps"]?.Value != null && o.Properties["SecondDisk"]?.Value == null,
                MinGB = Get<int>(o, "MinGB"),
                Color =System.Drawing.ColorTranslator.FromHtml(Get<string>(o, "Color")),
            }).ToList();

        public async Task<StartupInfo> GetStartupInfoAsync()
        {
            var info = (await InvokeAsync("Get-StartupInfo")).Single;
            var stateValue = info.Properties["State"]?.Value;
            var state = stateValue == null ? null : PSObject.AsPSObject(stateValue);
            var otherValue = info.Properties["Other"]?.Value;
            var other = otherValue == null ? null : PSObject.AsPSObject(otherValue);
            return new StartupInfo
            {
                WindowsFallback = ToDrive(PSObject.AsPSObject(info.Properties["WindowsFallback"].Value)),
                Status = Get<string>(info, "Status"),
                Leftovers = Get<string[]>(info, "Leftovers"),
                RoomPhase = Get<string>(info, "RoomPhase"),
                OtherName = other == null ? null : Get<string>(other, "Name"),
                OtherGB = other == null ? 0 : Get<int>(other, "SizeGB"),
                OtherOnWindowsDisk = other == null || Get<bool>(other, "OnWindowsDisk"),
                OtherKept = other == null ? null : Get<string[]>(other, "Kept"),
                Drives = ItemsOf(info, "Drives").Select(ToDrive).ToList(),
                DownloadDrives = ItemsOf(info, "DownloadDrives").Select(o => new DownloadDrive
                {
                    Letter = Get<string>(o, "Letter"),
                    FreeGB = Get<int>(o, "FreeGB"),
                    IsDefault = Get<bool>(o, "IsDefault"),
                }).ToList(),
                RoomLetter = Get<string>(info, "RoomLetter"),
                StateLetter = Get<string>(info, "StateLetter"),
                StateDiskMissing = Get<bool>(info, "StateDiskMissing"),
                PreparedDistro = state == null ? null : Get<string>(state, "Distro"),
                PreparedId = state == null ? null : Get<string>(state, "DistroId"),
                CameBack = Get<bool>(info, "CameBack"),
                SecureBoot = Get<bool>(info, "SecureBoot"),
                BootKey = Get<string>(info, "BootKey"),
            };
        }

        static DriveChoice ToDrive(PSObject o) => new DriveChoice
        {
            Id = Get<string>(o, "Id") ?? "",
            Kind = Get<string>(o, "Kind"),
            Letter = Get<string>(o, "Letter") ?? "",
            Title = Get<string>(o, "Title"),
            Blocker = Get<string>(o, "Blocker") is string blocker && blocker.Length > 0 ? blocker : null,
            DiskName = Get<string>(o, "DiskName"),
            OnWindowsDisk = Get<bool>(o, "OnWindowsDisk"),
            Estimated = Get<bool>(o, "Estimated"),
            SizeGB = Get<int>(o, "SizeGB"),
            UsedGB = Get<int>(o, "UsedGB"),
            TailFreeGB = Get<int>(o, "TailFreeGB"),
            UsableGB = Get<int>(o, "UsableGB"),
            StuckGB = Get<int>(o, "StuckGB"),
            ShrinkBlocker = Get<string>(o, "ShrinkBlocker"),
            BlockerKind = Get<string>(o, "BlockerKind"),
        };

        static IEnumerable<PSObject> ItemsOf(PSObject o, string name) =>
            o.Properties[name]?.Value is IEnumerable items
                ? items.Cast<object>().Where(i => i != null).Select(PSObject.AsPSObject)
                : Enumerable.Empty<PSObject>();

        /// <summary>The real figures for one place, which can take Windows a while to work out.</summary>
        public async Task<DriveChoice> GetDriveSpaceAsync(string target) =>
            ToDrive((await InvokeAsync("Get-DriveSpace", new Hashtable { ["Target"] = target })).Single);

        public Task InstallAsync(string distroId, string isoPath, int linuxGB, string target, string downloadDrive, bool fullDisk = false) =>
            InvokeAsync("Invoke-Install", new Hashtable
            {
                ["DistroId"] = distroId,
                ["IsoPath"] = isoPath ?? "",
                ["LinuxGB"] = linuxGB,
                ["Target"] = target ?? "",
                ["DownloadDrive"] = downloadDrive ?? "",
                ["FullDisk"] = fullDisk,
            });

        /// <summary>Only reads the PC. Telling Windows how far a drive shrinks can take a while.</summary>
        public async Task<FullDiskPlan> GetFullDiskPlanAsync(string distroId, string target)
        {
            var plan = (await InvokeAsync("Get-FullDiskPlan", new Hashtable { ["DistroId"] = distroId, ["Target"] = target ?? "" })).Single;
            var drive = plan.Properties["Target"]?.Value;
            return new FullDiskPlan
            {
                Blocker = Get<string>(plan, "Blocker") is string blocker && blocker.Length > 0 ? blocker : null,
                Target = drive == null ? null : ToDrive(PSObject.AsPSObject(drive)),
                DiskName = Get<string>(plan, "DiskName"),
                DiskGB = Get<int>(plan, "DiskGB"),
                Points = Get<string[]>(plan, "Points"),
                StopsStarting = Get<string[]>(plan, "StopsStarting"),
            };
        }

        public Task CleanupAsync(bool installerOnly) =>
            InvokeAsync("Invoke-Cleanup", new Hashtable { ["InstallerOnly"] = installerOnly });

        public Task<InstallSteps> GetStepsAsync() => GetStepsFromAsync("Get-StateSteps");

        public Task<InstallSteps> GetReturnedHelpAsync() => GetStepsFromAsync("Get-ReturnedHelp");

        public Task<InstallSteps> GetMakeRoomStepsAsync(string letter) =>
            GetStepsFromAsync("Get-MakeRoomSteps", new Hashtable { ["Drive"] = letter ?? "" });

        /// <summary>True when the PC is restarting; another drive may not need that.</summary>
        public async Task<bool> StartMakeRoomAsync(string letter) =>
            (await InvokeAsync("Start-MakeRoom", new Hashtable { ["Drive"] = letter ?? "" })).Single.ToString() == "restarting";

        public Task RestartForRoomAsync() => InvokeAsync("Request-RoomRestart");

        /// <summary>False when it couldn't finish, and has put the settings back.</summary>
        public async Task<bool> CompleteMakeRoomAsync() =>
            (await InvokeAsync("Complete-MakeRoom")).Single.ToString() == "done";

        public Task ClearRestorePointsAsync(string letter) =>
            InvokeAsync("Clear-RestorePoints", new Hashtable { ["Drive"] = letter ?? "" });

        public Task RestoreRoomSettingsAsync() => InvokeAsync("Restore-RoomSettings");

        public void RestoreRoomSettings() => Invoke("Restore-RoomSettings");

        public void RestoreRoomFromTask() => Invoke("Restore-RoomFromTask");

        async Task<InstallSteps> GetStepsFromAsync(string command, IDictionary parameters = null)
        {
            var steps = (await InvokeAsync(command, parameters)).Single;
            return new InstallSteps
            {
                Steps = Get<string[]>(steps, "Steps"),
                Notes = Get<string[]>(steps, "Notes"),
                Restart = Get<bool>(steps, "Restart"),
                FullDisk = Get<bool>(steps, "FullDisk"),
            };
        }

        public async Task<string[]> GetWarningsAsync(string target) =>
            (await InvokeAsync("Get-Warnings", new Hashtable { ["Target"] = target ?? "" })).Items.Select(o => o.ToString()).ToArray();

        public async Task<string> GetReportAsync() => (await InvokeAsync("Get-Report")).Single.ToString();

        public Task RestartIntoInstallerAsync() => InvokeAsync("Restart-IntoInstaller");

        public Task RestartIntoFirmwareAsync() => InvokeAsync("Restart-IntoFirmware");

        public Task RemoveOtherSystemAsync() => InvokeAsync("Remove-OtherSystem");

        public Task ExpandWindowsAsync(string target) =>
            InvokeAsync("Expand-Windows", new Hashtable { ["Target"] = target ?? "" });

        /// <summary>False once the install has started changing the disk.</summary>
        public bool TryCancel() => ((CancelGate)Sync["Gate"]).TryCancel();

        /// <summary>Stops the running command; its task then fails with PipelineStoppedException.</summary>
        public void Stop() => running?.BeginStop(null, null);

        /// <summary>The same, and returns once it has stopped, so that the engine can be used again.</summary>
        public void StopAndWait() => running?.Stop();

        // PowerShell converts null to "" for a string, which would read as a real value in the sentences.
        static T Get<T>(PSObject o, string name)
        {
            var value = o.Properties[name]?.Value;
            return value == null ? default(T) : LanguagePrimitives.ConvertTo<T>(value);
        }

        public void Dispose() => runspace.Dispose();

        sealed class Collection
        {
            public readonly List<PSObject> Items;
            public Collection(IEnumerable<PSObject> items) => Items = items.Where(i => i != null).ToList();
            public PSObject Single => Items.Last();
        }
    }
}
