using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace Usbless
{
    /// <summary>
    /// The copy of usbless that Make room's scheduled tasks start, elevated and without asking. If it could be
    /// replaced from an ordinary process, those tasks would be a way around UAC, so it lives in a new
    /// folder only administrators can write to, under %ProgramData%, whose default rights would let any
    /// user create files. The folder's name can't be guessed and it's made with its rights in place, so
    /// nothing can be waiting there. Called from the engine scripts as [Usbless.RestartCopy].
    /// </summary>
    public static class RestartCopy
    {
        public const string FolderPrefix = "usbless-restart-";
        const uint QueryLimitedInformation = 0x1000;

        /// <summary>Copies the running usbless to a new folder under parent, and returns the copy's path.</summary>
        public static string Create(string parent)
        {
            string folder = Path.Combine(parent, FolderPrefix + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder, ProtectedRights());
            try
            {
                string copy = Path.Combine(folder, "usbless.exe");
                CopyRunningImage(copy);
                return copy;
            }
            catch
            {
                try { Directory.Delete(folder, true); } catch (Exception) { }
                throw;
            }
        }

        public static DirectorySecurity ProtectedRights()
        {
            var rights = new DirectorySecurity();
            rights.SetAccessRuleProtection(true, false);
            rights.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
            const InheritanceFlags all = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            rights.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), FileSystemRights.FullControl, all, PropagationFlags.None, AccessControlType.Allow));
            rights.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl, all, PropagationFlags.None, AccessControlType.Allow));
            rights.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null), FileSystemRights.ReadAndExecute, all, PropagationFlags.None, AccessControlType.Allow));
            return rights;
        }

        /// <summary>
        /// The file this process is really running from. usbless.exe may be in the user's Downloads, and a running
        /// file can be renamed there and another put in its place, so the path it was started from proves nothing.
        /// Windows keeps a running image from being written to. Opening it stops it being renamed, and asking
        /// again after that proves what's open is that image.
        /// </summary>
        static void CopyRunningImage(string destination)
        {
            string image = RunningImage();
            using (var source = new FileStream(image, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (!string.Equals(RunningImage(), image, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("usbless's file was moved while it was being copied.");
                using (var target = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    source.CopyTo(target);
            }
        }

        public static string RunningImage()
        {
            var name = new StringBuilder(32768);
            int size = name.Capacity;
            using (var process = Process.GetCurrentProcess())
                if (!QueryFullProcessImageName(process.Handle, 0, name, ref size))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            return name.ToString();
        }

        /// <summary>The folder this process is running from, if it's one of these copies.</summary>
        public static string OwnFolder()
        {
            string folder = Path.GetDirectoryName(RunningImage());
            return IsCopyFolder(folder, StateFolder.ProgramData) ? folder : null;
        }

        /// <summary>
        /// Whether a folder really is one of these copies. Anyone can name a folder this, anywhere they can
        /// write, so it takes the right place and an owner no ordinary user could have given it.
        /// </summary>
        public static bool IsCopyFolder(string folder, string parent)
        {
            if (!string.Equals(Path.GetDirectoryName(folder), parent.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) return false;
            if (!Path.GetFileName(folder).StartsWith(FolderPrefix, StringComparison.OrdinalIgnoreCase)) return false;
            try
            {
                if ((File.GetAttributes(folder) & FileAttributes.ReparsePoint) != 0) return false;
                var owner = Directory.GetAccessControl(folder, AccessControlSections.Owner).GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
                return owner != null && owner.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid);
            }
            catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException || ex is InvalidOperationException)
            {
                return false;
            }
        }

        /// <summary>
        /// A running file can't delete itself, so something has to do it once usbless has gone. The tasks still
        /// need the copy while Make room's settings are off, which is what that file saying so means.
        /// </summary>
        public static void RemoveOwnAfterExit()
        {
            try
            {
                string folder = OwnFolder();
                string state = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "usbless", "make-room.json");
                if (folder == null || File.Exists(state)) return;
                string cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
                Process.Start(new ProcessStartInfo(cmd, $"/c ping -n 6 127.0.0.1 >nul & rmdir /s /q \"{folder}\"")
                {
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    WorkingDirectory = Environment.SystemDirectory,
                });
            }
            catch (Exception) { }
        }

        /// <summary>
        /// For the copy usbless is running from, once nothing needs it: Windows deletes it as it next starts. A restart
        /// from this window, which is how Install ends, would otherwise leave it behind for good.
        /// </summary>
        public static void RemoveAtNextStart(string folder)
        {
            foreach (string file in Directory.GetFiles(folder))
                if (!MoveFileEx(file, null, DelayUntilReboot)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!MoveFileEx(folder, null, DelayUntilReboot)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        const int DelayUntilReboot = 4;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "MoveFileExW")]
        static extern bool MoveFileEx(string existing, string replacement, int flags);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "QueryFullProcessImageNameW")]
        static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);
    }
}
