using System;
using System.Drawing;
using System.Windows.Forms;
using static Usbless.Theme;

namespace Usbless
{
    enum DriveMode { Edit, Progress, Static, Stuck }

    /// <summary>
    /// The chosen drive drawn to scale: what's on it now (used and free), the installer, and
    /// the Linux part in the system's brand color. In Edit mode the boundary between the
    /// drive and Linux is dragged to choose the size. Free space has no drive to shrink, so
    /// its left part is simply what stays free. In Stuck mode there's no Linux yet: it shows
    /// what's free and the mark Windows can't shrink past.
    /// </summary>
    sealed class DriveBar : DrawnControl
    {
        const float HeaderHeight = 16, HeaderGap = 12, BarHeight = 84, LegendGap = 14, LegendHeight = 16, Gap = 3;
        const float MinLabelWidth = 48, MinCutLabelWidth = 96;

        readonly Timer animation = new Timer { Interval = 16 };
        float shownProgress, targetProgress;
        bool dragging, handleHot;

        public string DiskName = "";
        public string DriveTitle = "Drive C:";
        public string DriveLabel = "Windows";   // inside the bar: Windows on C:, or the drive's name
        public bool IsFreeSpace;
        public int WindowsGB = 1, UsedGB, InstallerGB = 8;
        public int TailFreeGB;      // free space after the drive, used before it shrinks
        public int MinLinuxGB = 25, MaxLinuxGB = 25;
        public string SystemName = "";
        public Color Brand = Ink;
        public DriveMode Mode = DriveMode.Edit;
        public string Status = "";
        public string Legend;       // in place of the usual words about the installer
        public int ReleaseGB;       // Stuck: how much usbless can use, after its reserve
        public string StuckFile;    // Stuck: the file in the way
        int linuxGB = 60;

        public event EventHandler ValueChanged;

        public DriveBar()
        {
            MakeClickable();
            Cursor = Cursors.Default;
            Height = FullHeight;
            animation.Tick += (s, e) =>
            {
                shownProgress += (targetProgress - shownProgress) * 0.12f;
                if (Math.Abs(targetProgress - shownProgress) < 0.001f) { shownProgress = targetProgress; animation.Stop(); }
                Invalidate();
            };
        }

        int FullHeight => S(HeaderHeight + HeaderGap + BarHeight + LegendGap + LegendHeight);

        /// <summary>Stuck mode has no legend, so what's below can sit right under the bar.</summary>
        public void FitToMode() => Height = Mode == DriveMode.Stuck ? S(HeaderHeight + HeaderGap + BarHeight) : FullHeight;

        public int LinuxGB
        {
            get => linuxGB;
            set
            {
                int clamped = Math.Max(MinLinuxGB, Math.Min(MaxLinuxGB, value));
                if (clamped == linuxGB) return;
                linuxGB = clamped;
                Invalidate();
                ValueChanged?.Invoke(this, EventArgs.Empty);
            }
        }

        /// <summary>0 to 1. Moves smoothly toward the new value.</summary>
        public float Progress
        {
            get => targetProgress;
            set
            {
                targetProgress = Math.Max(0, Math.Min(1, value));
                if (value <= 0) shownProgress = 0;
                animation.Start();
            }
        }

        // --- Geometry ----------------------------------------------------------------

        RectangleF Bar => new RectangleF(0, F(HeaderHeight + HeaderGap), Width, F(BarHeight));
        float PxPerGB => (Bar.Width - 2 * F(Gap)) / Math.Max(1, WindowsGB + TailFreeGB);
        float LinuxLeft => Bar.Right - linuxGB * PxPerGB;
        float InstallerLeft => LinuxLeft - F(Gap) - InstallerGB * PxPerGB;
        float WindowsRight => InstallerLeft - F(Gap);
        float HandleX => InstallerLeft - F(Gap) / 2;

        /// <summary>Size of the drive once Linux has its space: it only shrinks by what the free space can't cover.</summary>
        int WindowsAfterGB => WindowsGB - Math.Max(0, linuxGB + InstallerGB - TailFreeGB);

        int ValueAt(float x) => (int)Math.Round((Bar.Right - x) / PxPerGB) - InstallerGB;

        // --- Input ------------------------------------------------------------------------

        bool InBar(Point p) => Bar.Contains(p);
        bool NearHandle(Point p) => Mode == DriveMode.Edit && InBar(p) && Math.Abs(p.X - HandleX) <= F(14);

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (Mode != DriveMode.Edit || e.Button != MouseButtons.Left || !InBar(e.Location)) return;
            Focus();
            dragging = true;
            if (!NearHandle(e.Location)) LinuxGB = ValueAt(e.X);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (dragging) LinuxGB = ValueAt(e.X);
            bool hot = dragging || NearHandle(e.Location);
            if (hot != handleHot) { handleHot = hot; Invalidate(); }
            Cursor = Mode == DriveMode.Edit && InBar(e.Location) ? Cursors.SizeWE : Cursors.Default;
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            dragging = false;
            handleHot = NearHandle(e.Location);
            Invalidate();
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (!dragging) handleHot = false;
        }

        protected override bool IsInputKey(Keys keyData) =>
            keyData == Keys.Left || keyData == Keys.Right || base.IsInputKey(keyData);

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (Mode != DriveMode.Edit) return;
            switch (e.KeyCode)
            {
                case Keys.Left: LinuxGB += 1; break;      // the handle moves left, Linux grows
                case Keys.Right: LinuxGB -= 1; break;
                case Keys.PageUp: LinuxGB += 10; break;
                case Keys.PageDown: LinuxGB -= 10; break;
                case Keys.Home: LinuxGB = MaxLinuxGB; break;
                case Keys.End: LinuxGB = MinLinuxGB; break;
                default: return;
            }
            e.Handled = true;
        }

        // --- Drawing ---------------------------------------------------------------------

        protected override void Draw(Graphics g)
        {
            var small = Font(13);
            var smallStrong = Font(13, true);
            float headerBaseline = TextKit.BaselineIn(small, 0, F(HeaderHeight));
            string size = IsFreeSpace ? $"Free space {TailFreeGB} GB"
                : TailFreeGB > 0 ? $"{DriveTitle} {WindowsGB} GB + {TailFreeGB} GB free" : $"{DriveTitle} {WindowsGB} GB";
            string header = DiskName.Length > 0 ? $"{DiskName} · {size}" : size;
            string right = Mode == DriveMode.Edit ? (MinLinuxGB < MaxLinuxGB ? "Drag to resize" : "") : Mode == DriveMode.Stuck ? StuckFile ?? "" : Status;
            var rightFont = Mode == DriveMode.Edit ? small : smallStrong;
            // The header says which drive, so it comes first: the right side has what it leaves, and at least some.
            float gap = F(16), headerWidth = TextKit.Width(header, smallStrong);
            right = TextKit.Ellipsize(right, rightFont, Math.Max(Width * 0.4f, Width - headerWidth - gap));
            float rightWidth = TextKit.Width(right, rightFont);
            header = TextKit.Ellipsize(header, smallStrong, Width - (rightWidth > 0 ? rightWidth + gap : 0));
            TextKit.Draw(g, header, smallStrong, Ink, 0, headerBaseline);
            TextKit.Draw(g, right, rightFont, Mode == DriveMode.Edit ? Tertiary : Ink, Width - rightWidth, headerBaseline);

            var bar = Bar;
            var saved = g.Clip;
            using (var clip = RoundedRect(bar, F(12))) g.SetClip(clip);

            if (Mode == DriveMode.Stuck)
            {
                DrawStuck(g, bar);
                g.Clip = saved;
                return;
            }

            float usedRight = bar.X + Math.Min(UsedGB, WindowsGB) * PxPerGB;
            using (var used = new SolidBrush(DriveUsed)) g.FillRectangle(used, bar.X, bar.Y, Math.Max(0, Math.Min(usedRight, WindowsRight) - bar.X), bar.Height);
            if (WindowsRight > usedRight)
                using (var free = new SolidBrush(DriveFree)) g.FillRectangle(free, usedRight, bar.Y, WindowsRight - usedRight, bar.Height);

            var linux = new RectangleF(LinuxLeft, bar.Y, bar.Right - LinuxLeft, bar.Height);
            bool preparing = Mode == DriveMode.Progress;
            var linuxFill = preparing ? Mix(Color.White, Brand, 0.18f) : Brand;
            using (var brush = new SolidBrush(linuxFill)) g.FillRectangle(brush, linux);
            using (var brush = new SolidBrush(Mix(Color.White, Brand, 0.42f)))
                g.FillRectangle(brush, InstallerLeft, bar.Y, LinuxLeft - F(Gap) - InstallerLeft, bar.Height);

            // Labels sit on the bottom edge; in progress mode they make room for the progress line.
            float labelBottom = bar.Bottom - F(preparing ? 26 : 14);
            DrawLabels(g, new RectangleF(bar.X + F(16), bar.Y, WindowsRight - bar.X - F(32), bar.Height), labelBottom,
                IsFreeSpace ? "Free space" : DriveLabel,
                IsFreeSpace ? $"{Math.Max(0, TailFreeGB - linuxGB - InstallerGB)} GB stays free" : $"{UsedGB} GB used · {Math.Max(0, WindowsAfterGB - UsedGB)} GB free",
                Ink, DriveUsedText, IsFreeSpace ? null : $"{UsedGB} GB used");

            var onLinux = preparing ? Mix(Brand, Color.Black, 0.45f) : TextOn(Brand);
            var onLinuxSoft = preparing ? Mix(Brand, Color.Black, 0.2f) : Color.FromArgb(210, onLinux);
            // Linux can want more than the bar has, on a space smaller than its least.
            float linuxLabel = Math.Max(linux.X, bar.X);
            DrawLabels(g, new RectangleF(linuxLabel + F(18), bar.Y, bar.Right - linuxLabel - F(34), bar.Height), labelBottom,
                SystemName, $"{linuxGB} GB", onLinux, onLinuxSoft);

            if (preparing && linux.Width > F(60))
            {
                var track = new RectangleF(linux.X + F(18), bar.Bottom - F(18), linux.Width - F(34), F(4));
                FillRounded(g, Mix(Color.White, Brand, 0.35f), track, F(2));
                if (shownProgress > 0)
                    FillRounded(g, Brand, new RectangleF(track.X, track.Y, Math.Max(track.Height, track.Width * shownProgress), track.Height), F(2));
            }
            g.Clip = saved;

            if (Mode == DriveMode.Edit) DrawHandle(g, bar);

            // Legend for the installer strip.
            float legendTop = bar.Bottom + F(LegendGap);
            string legend = Legend ?? $"Installer · {InstallerGB} GB, removable once Linux is set up";
            float legendWidth = TextKit.Width(legend, small);
            float lx = Width - legendWidth;
            FillRounded(g, Mix(Color.White, Brand, 0.42f), new RectangleF(lx - F(16), legendTop + F(4), F(8), F(8)), F(2));
            TextKit.Draw(g, legend, small, Tertiary, lx, TextKit.BaselineIn(small, legendTop, F(LegendHeight)));
        }

        void DrawStuck(Graphics g, RectangleF bar)
        {
            float usedRight = bar.X + Math.Min(UsedGB, WindowsGB) * PxPerGB;
            using (var free = new SolidBrush(DriveFree)) g.FillRectangle(free, bar);
            using (var used = new SolidBrush(DriveUsed)) g.FillRectangle(used, bar.X, bar.Y, usedRight - bar.X, bar.Height);

            // Windows can't shrink past this. It can't be drawn right on the edge, where nothing would show it.
            // ReleaseGB counts the free space after the drive too, which takes nothing off the drive.
            float mark = bar.X + (WindowsGB - Math.Max(0, ReleaseGB - TailFreeGB)) * PxPerGB;
            mark = Math.Max(usedRight, Math.Min(bar.Right - F(14), mark));

            // The used label takes the width it needs, even if the used part is thinner, and the free one starts after it.
            float bottom = bar.Bottom - F(14);
            string usedDetail = $"{UsedGB} GB used";
            float usedLabel = (float)Math.Ceiling(Math.Max(TextKit.Width(DriveLabel, Font(14, true)), TextKit.Width(usedDetail, Font(13))));
            var usedArea = new RectangleF(bar.X + F(16), bar.Y, usedLabel, bar.Height);
            DrawLabels(g, usedArea, bottom, DriveLabel, usedDetail, Ink, DriveUsedText);

            float freeLeft = Math.Max(usedRight, usedArea.Right) + F(16);
            float beforeMark = mark - F(8) - freeLeft, afterMark = bar.Right - F(16) - (mark + F(4) + F(12));
            // After the mark only if there's no room before it, because the free part mostly is before it.
            var freeArea = beforeMark >= F(MinLabelWidth) || afterMark <= beforeMark
                ? new RectangleF(freeLeft, bar.Y, beforeMark, bar.Height)
                : new RectangleF(mark + F(4) + F(12), bar.Y, afterMark, bar.Height);
            DrawLabels(g, freeArea, bottom, $"{Math.Max(0, WindowsGB - UsedGB)} GB free", $"usbless can use {ReleaseGB} GB of it", Ink, DriveUsedText, $"{ReleaseGB} GB usable");

            using (var brush = new SolidBrush(Ink)) g.FillRectangle(brush, mark, bar.Y, F(4), bar.Height);
        }

        /// <summary>A shorter detail stands in if there's room for that, and what doesn't fit isn't drawn: "Wind…" says nothing.</summary>
        void DrawLabels(Graphics g, RectangleF area, float bottom, string title, string detail, Color titleColor, Color detailColor, string shortDetail = null)
        {
            if (area.Width < F(MinLabelWidth)) return;
            var titleFont = Font(14, true);
            var detailFont = Font(13);
            string t = FitLabel(title, titleFont, area.Width);
            string d = TextKit.Width(detail, detailFont) <= area.Width || shortDetail == null ? FitLabel(detail, detailFont, area.Width)
                : TextKit.Width(shortDetail, detailFont) <= area.Width ? shortDetail : null;
            float detailBaseline = bottom - TextKit.Descent(detailFont);
            TextKit.Draw(g, t, titleFont, titleColor, area.X, detailBaseline - F(18));
            TextKit.Draw(g, d, detailFont, detailColor, area.X, detailBaseline);
        }

        /// <summary>Long names can lose their end where there's room for most of them. Otherwise they go.</summary>
        string FitLabel(string text, Font font, float width) =>
            TextKit.Width(text, font) <= width ? text : width >= F(MinCutLabelWidth) ? TextKit.Ellipsize(text, font, width) : null;

        void DrawHandle(Graphics g, RectangleF bar)
        {
            float w = F(handleHot ? 16 : 14), h = F(handleHot ? 50 : 44);
            var handle = new RectangleF(HandleX - w / 2, bar.Y + (bar.Height - h) / 2, w, h);
            Shadow(g, handle, w / 2, 4, 60);
            FillRounded(g, Color.White, handle, w / 2);
            if (Focused && ShowFocusCues)
                StrokeRounded(g, Brand, RectangleF.Inflate(handle, F(2.5f), F(2.5f)), w / 2 + F(2.5f), F(2));
            using (var grip = new SolidBrush(Quaternary))
            {
                float gh = F(14), gy = handle.Y + (h - gh) / 2;
                g.FillRectangle(grip, HandleX - F(2.25f), gy, F(1.5f), gh);
                g.FillRectangle(grip, HandleX + F(0.75f), gy, F(1.5f), gh);
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) animation.Dispose();
            base.Dispose(disposing);
        }
    }
}
