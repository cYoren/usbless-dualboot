using System;
using System.Linq;
using System.Threading.Tasks;
using static Usbless.Theme;

namespace Usbless
{
    sealed partial class MainForm
    {
        // --- Another Linux (Pond) ----------------------------------------------------------

        /// <summary>The startup entries left alone, because they may be how another system starts.</summary>
        static string KeptNote(string[] kept) => kept != null && kept.Length > 0
            ? $" usbless can't tell whether {string.Join(", ", kept)} in the startup menu belongs to this Linux, so that stays. If it's left over, it may stop at a prompt when chosen."
            : "";

        void ShowRemoveOther()
        {
            string name = startup.OtherName;
            Arrange(new[]
            {
                new[] { Run.Gray("Remove"), Run.Black(name) },
                new[] { Run.Gray("and free"), Run.Black(startup.OtherGB + " GB") },
            }, $"This deletes {name} and everything stored in it, and takes it out of the startup menu. Windows and your files stay.{KeptNote(startup.OtherKept)}",
                Secondary, null, 0);
            Footer("Back", ShowChoose, "Remove " + name, () => _ = RemoveOtherAsync());
        }

        async Task RemoveOtherAsync()
        {
            string name = startup.OtherName;
            int freed = startup.OtherGB;
            bool onWindowsDisk = startup.OtherOnWindowsDisk;
            string kept = KeptNote(startup.OtherKept);
            BeginWork(new[] { new[] { Run.Gray("Removing"), Run.Black(name) } }, "Starting…");
            try
            {
                await engine.RemoveOtherSystemAsync();
                await ReloadAsync();
                EndWork();
                if (onWindowsDisk)
                {
                    Arrange(new[] { new[] { Run.Black(name), Run.Gray("is gone.") } },
                        $"{freed} GB is free now. Use it for Linux, or give it back to Windows.{kept}", Secondary, null, 0);
                    target = startup.Drives.FirstOrDefault(d => d.IsWindows) ?? target;
                    Footer(null, null, "Use it for Linux", ShowChoose, "Give it to Windows", () => _ = ExpandWindowsAsync());
                }
                else
                {
                    Arrange(new[] { new[] { Run.Black(name), Run.Gray("is gone.") } }, $"{freed} GB is free now on that drive.{kept}", Secondary, null, 0);
                    Footer(null, null, "Done", ShowChoose);
                }
            }
            catch (Exception ex)
            {
                EndWork();
                try { startup = await engine.GetStartupInfoAsync(); } catch { }
                Arrange(new[] { new[] { Run.Gray("Couldn't remove"), Run.Black(name) } }, Describe(ex), Danger, null, 0);
                Footer("Back", ShowChoose, "Try again", startup.OtherGB > 0 ? () => _ = RemoveOtherAsync() : (Action)null);
            }
        }

        async Task ExpandWindowsAsync()
        {
            string owner = target.IsWindows ? "Windows" : target.InSentence;
            BeginWork(new[] { new[] { Run.Gray("Giving the space to"), Run.Black(owner) } }, "Starting…");
            try
            {
                await engine.ExpandWindowsAsync(target.Id);
                await ReloadAsync();
                EndWork();
                Arrange(new[] { new[] { Run.Black(target.IsWindows ? "Windows" : target.Title), Run.Gray("has the space back.") } },
                    $"{target.Title} is {target.SizeGB} GB now.", Secondary, null, 0);
                Footer("Start over", ShowChoose, "Close", Close);
            }
            catch (Exception ex)
            {
                EndWork();
                Arrange(new[] { new[] { Run.Gray("Couldn't give the space to"), Run.Black(owner) } }, Describe(ex), Danger, null, 0);
                Footer(null, null, "Use it for Linux", ShowChoose, "Try again", () => _ = ExpandWindowsAsync());
            }
        }
    }
}
