using System;
using System.Drawing;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Usbless
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            bool restoring = args.Length == 1 && args[0] == RestoreArgument;
            AppDomain.CurrentDomain.ProcessExit += (s, e) => RestartCopy.RemoveOwnAfterExit();

            // From the very start, because nobody would see a problem otherwise. The safety net has no window
            // and may have nobody there, and a message waiting for an answer would keep usbless locked.
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += (s, e) => ReportCrash(e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            {
                if (restoring) LogCrash(e.ExceptionObject as Exception);
                else ReportCrash(e.ExceptionObject as Exception);
            };
            TaskScheduler.UnobservedTaskException += (s, e) => { LogCrash(e.Exception); e.SetObserved(); };

            // Two copies changing the same disk would be a disaster.
            using (var mutex = OpenInstanceLock(out bool first))
            {
                if (!first)
                {
                    // Make room's safety net, while usbless is open and still needs the settings off. It tries again later.
                    if (restoring) return;
                    MessageBox.Show("usbless is already running. If you can't see its window, it's putting settings back, so try again in a few minutes.", "usbless", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                try { StateFolder.ProtectAll(); }
                catch (Exception ex) when (ex is IOException || ex is UnauthorizedAccessException || ex is InvalidOperationException)
                {
                    if (!restoring)
                        MessageBox.Show($"usbless can't make its folder safe to use, so it hasn't changed anything.\n\nRestart this PC and open usbless again.\n\n{ex.Message}", "usbless", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }

                if (restoring)
                {
                    RestoreRoom();
                    return;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using (var g = Graphics.FromHwnd(IntPtr.Zero))
                    Theme.Scale = MainForm.ScaleToFit(g.DpiX / 96f);
                Theme.LoadFonts();
                Application.Run(new MainForm());
            }
        }

        /// <summary>The argument Make room's safety-net task runs usbless with. No window: nobody may be there to see it.</summary>
        const string RestoreArgument = "--restore-room";

        const string InstanceLock = @"Global\usbless-installer";

        /// <summary>A stuck safety net can't be allowed to keep usbless locked. Whatever it didn't finish, it tries again later.</summary>
        static readonly TimeSpan RestoreLimit = TimeSpan.FromMinutes(5);

        /// <summary>
        /// A lock has the rights of the process that made it, and by default a SYSTEM process doesn't let
        /// administrators open its. So usbless's says they can. One made by an older build's task can still refuse,
        /// which means it's in use.
        /// </summary>
        static Mutex OpenInstanceLock(out bool first)
        {
            var rights = new MutexSecurity();
            foreach (var who in new[] { WellKnownSidType.BuiltinAdministratorsSid, WellKnownSidType.LocalSystemSid })
                rights.AddAccessRule(new MutexAccessRule(new SecurityIdentifier(who, null), MutexRights.FullControl, AccessControlType.Allow));
            try { return new Mutex(true, InstanceLock, out first, rights); }
            catch (UnauthorizedAccessException)
            {
                first = false;
                return null;
            }
        }

        static void RestoreRoom()
        {
            var restore = Task.Run(() => { using (var engine = new Engine()) engine.RestoreRoomFromTask(); });
            try
            {
                if (!restore.Wait(RestoreLimit)) LogCrash(new TimeoutException($"Putting Make room's settings back took over {RestoreLimit.TotalMinutes} minutes."));
            }
            catch (AggregateException ex) { LogCrash(ex.GetBaseException()); }
        }

        static void ReportCrash(Exception ex)
        {
            string path = LogCrash(ex);
            MessageBox.Show($"usbless ran into a problem it didn't expect.\n\n{ex?.Message}\n\nDetails are in {path}", "usbless", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        static string LogCrash(Exception ex)
        {
            string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "usbless", "logs");
            string path = Path.Combine(folder, "crash.log");
            if (!StateFolder.Ready) return path;
            try
            {
                Directory.CreateDirectory(folder);
                File.AppendAllText(path, $"{DateTime.Now:s}{Environment.NewLine}{ex}{Environment.NewLine}{Environment.NewLine}");
            }
            catch { }
            return path;
        }
    }
}
