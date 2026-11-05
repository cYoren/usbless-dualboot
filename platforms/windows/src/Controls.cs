using System;
using System.Drawing;
using System.Windows.Forms;
using static Usbless.Theme;

namespace Usbless
{
    /// <summary>Base for owner-drawn controls: double buffered on a white background.</summary>
    abstract class DrawnControl : Control
    {
        protected bool Hovered, Pressed;

        protected DrawnControl()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Background;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            Prepare(e.Graphics);
            Draw(e.Graphics);
        }

        protected abstract void Draw(Graphics g);

        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); Hovered = true; Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); Hovered = Pressed = false; Invalidate(); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button == MouseButtons.Left) { Pressed = true; Invalidate(); } }
        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); Pressed = false; Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }

        /// <summary>
        /// Holding Enter mustn't click through to the next screen's button, as it did from Install to Start.
        /// Windows says when a key was already down, including when it went down on another control.
        /// </summary>
        protected override void WndProc(ref Message m)
        {
            const int WM_KEYDOWN = 0x0100;
            const long WasDown = 1L << 30;
            bool activates = m.Msg == WM_KEYDOWN && ((int)m.WParam.ToInt64() == (int)Keys.Enter || (int)m.WParam.ToInt64() == (int)Keys.Space);
            if (activates && (m.LParam.ToInt64() & WasDown) != 0) return;
            base.WndProc(ref m);
        }

        /// <summary>Makes a control act on Enter and Space like a button.</summary>
        protected void MakeClickable()
        {
            SetStyle(ControlStyles.Selectable, true);
            TabStop = true;
            Cursor = Cursors.Hand;
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (GetStyle(ControlStyles.Selectable) && (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space))
            {
                e.Handled = true;
                OnClick(EventArgs.Empty);
            }
        }

        protected void DrawFocusRing(Graphics g, RectangleF r, float radius)
        {
            if (Focused && ShowFocusCues)
                StrokeRounded(g, Color.FromArgb(120, Ink), RectangleF.Inflate(r, -1, -1), radius, F(2));
        }
    }

    /// <summary>The design's 42 px buttons: black primary, outlined secondary.</summary>
    sealed class PillButton : DrawnControl
    {
        readonly bool primary;

        public PillButton(string text, bool primary)
        {
            MakeClickable();
            this.primary = primary;
            Text = text;
            Height = S(42);
        }

        protected override void OnTextChanged(EventArgs e)
        {
            base.OnTextChanged(e);
            Width = (int)Math.Ceiling(Text.Length == 0 ? 0 : TextKit.Width(Text, Font(15, true)) + F(52));
            Invalidate();
        }

        protected override void OnClick(EventArgs e) { if (Enabled) base.OnClick(e); }

        protected override void Draw(Graphics g)
        {
            var r = new RectangleF(0.5f, 0.5f, Width - 1, Height - 1);
            Color text;
            if (primary)
            {
                var fill = !Enabled ? Hairline : Pressed ? Color.Black : Hovered ? PrimaryHover : Ink;
                FillRounded(g, fill, r, F(10));
                text = Color.White;
            }
            else
            {
                FillRounded(g, Pressed ? Fill : Hovered && Enabled ? FillHover : Background, r, F(10));
                StrokeRounded(g, Hairline, r, F(10));
                text = Enabled ? Ink : Quaternary;
            }
            DrawFocusRing(g, r, F(10));
            var font = Font(15, true);
            float x = (Width - TextKit.Width(Text, font)) / 2;
            TextKit.Draw(g, Text, font, text, x, TextKit.BaselineIn(font, 0, Height));
        }
    }

    /// <summary>A line of footer text; clickable ones underline on hover.</summary>
    sealed class TextLink : DrawnControl
    {
        bool clickable;
        Color color = Secondary;

        public TextLink() => Height = S(24);

        public void Set(string text, bool isClickable, Color textColor, bool strong = false)
        {
            clickable = isClickable;
            color = textColor;
            Strong = strong;
            SetStyle(ControlStyles.Selectable, clickable);
            TabStop = clickable;
            Cursor = clickable ? Cursors.Hand : Cursors.Default;
            Text = text;
            Width = (int)Math.Ceiling(TextKit.Width(text, Font(14, strong))) + S(4);
            Visible = !string.IsNullOrEmpty(text);
            Invalidate();
        }

        bool Strong { get; set; }

        protected override void OnClick(EventArgs e) { if (clickable) base.OnClick(e); }

        protected override void Draw(Graphics g)
        {
            var font = Font(14, Strong);
            float baseline = TextKit.BaselineIn(font, 0, Height);
            var c = clickable && Hovered ? Ink : color;
            TextKit.Draw(g, Text, font, c, 0, baseline);
            if (clickable && (Hovered || (Focused && ShowFocusCues)))
                using (var pen = new Pen(Color.FromArgb(90, c), F(1)))
                    g.DrawLine(pen, 0, baseline + F(4), TextKit.Width(Text, font), baseline + F(4));
        }
    }

    /// <summary>Minimize and close, drawn like Windows 11's caption buttons.</summary>
    sealed class ChromeButton : DrawnControl
    {
        readonly bool close;

        public ChromeButton(bool close)
        {
            this.close = close;
            Size = new Size(S(46), S(32));
            TabStop = false;
        }

        protected override void Draw(Graphics g)
        {
            if (Hovered)
                using (var brush = new SolidBrush(close ? (Pressed ? Mix(CloseHover, Color.White, 0.15f) : CloseHover) : (Pressed ? Hairline : Fill)))
                    g.FillRectangle(brush, ClientRectangle);
            var color = close && Hovered ? Color.White : Ink;
            float cx = Width / 2f, cy = Height / 2f, h = F(5);
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;
            using (var pen = new Pen(color, Math.Max(1, F(1))))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                if (close)
                {
                    g.DrawLine(pen, cx - h, cy - h, cx + h, cy + h);
                    g.DrawLine(pen, cx + h, cy - h, cx - h, cy + h);
                }
                else
                {
                    g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;
                    g.DrawLine(pen, cx - h, cy, cx + h, cy);
                }
            }
        }
    }

    /// <summary>Wrapped body text with ** emphasis. Height follows the content.</summary>
    sealed class TextBlock : DrawnControl
    {
        string markup = "";
        float px = 15, lineHeight = 22;
        Color color = Secondary;
        Paragraph paragraph;

        public void Set(string text, Color textColor, float sizePx = 15, float lineHeightPx = 22)
        {
            markup = text ?? "";
            color = textColor;
            px = sizePx;
            lineHeight = lineHeightPx;
            Relayout();
        }

        protected override void OnSizeChanged(EventArgs e)
        {
            base.OnSizeChanged(e);
            if (paragraph == null || Math.Abs(Width - lastWidth) > 0.5f) Relayout();
        }

        float lastWidth;

        void Relayout()
        {
            lastWidth = Width;
            paragraph = markup.Length == 0 ? null : Paragraph.Layout(markup, px, lineHeight, Width);
            int height = paragraph == null ? 0 : (int)Math.Ceiling(paragraph.Height);
            if (Height != height) Height = height;
            Invalidate();
        }

        protected override void Draw(Graphics g) => paragraph?.Draw(g, 0, 0, color);
    }

    /// <summary>
    /// The numbered list: choices to make in the Linux installer, warnings, what's left behind. It's as tall
    /// as its text, up to the room the screen gives it. Past that it scrolls, by wheel, keys or its thin bar.
    /// </summary>
    sealed class StepsView : DrawnControl
    {
        const float BarGutter = 16, BarWidth = 3, MinThumb = 24, BottomFade = 36, TopFade = 20, WheelStep = 66, KeyStep = 44;

        string[] steps = new string[0];
        string[] notes = new string[0];
        Paragraph[] stepLayouts = new Paragraph[0];
        Paragraph[] noteLayouts = new Paragraph[0];
        int room = int.MaxValue;
        float contentHeight, offset, grabbed = -1;

        public void Set(string[] stepTexts, string[] noteTexts)
        {
            steps = stepTexts ?? new string[0];
            notes = noteTexts ?? new string[0];
            offset = 0;
            Relayout();
        }

        /// <summary>The most it may take up, in pixels.</summary>
        public void FitTo(int available)
        {
            room = Math.Max(S(44), available);
            Relayout();
        }

        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); Relayout(); }

        bool relayingOut;

        void Relayout()
        {
            if (relayingOut) return;
            relayingOut = true;
            contentHeight = Measure(Width);
            bool scrolls = contentHeight > room;
            if (scrolls) contentHeight = Measure(Width - F(BarGutter));   // narrower for the bar, so it can wrap to more lines
            Height = scrolls ? room : (int)Math.Ceiling(contentHeight);
            SetStyle(ControlStyles.Selectable, scrolls);
            TabStop = scrolls;
            offset = Math.Max(0, Math.Min(MaxOffset, offset));
            relayingOut = false;
            Invalidate();
        }

        float Measure(float width)
        {
            stepLayouts = Array.ConvertAll(steps, s => Paragraph.Layout(s, 15, 22, width - F(28)));
            noteLayouts = Array.ConvertAll(notes, s => Paragraph.Layout(s, 13, 18, width));
            float h = 0;
            foreach (var p in stepLayouts) h += p.Height + F(14);
            if (noteLayouts.Length > 0) h += F(10);
            foreach (var p in noteLayouts) h += p.Height + F(6);
            // The gap after the last one is only room to spare, and mustn't make a list that fits scroll.
            if (noteLayouts.Length == 0 && stepLayouts.Length > 0) h -= F(14);
            return h;
        }

        // --- Scrolling ----------------------------------------------------------------

        float MaxOffset => Math.Max(0, contentHeight - Height);

        void ScrollTo(float value)
        {
            value = Math.Max(0, Math.Min(MaxOffset, value));
            if (value == offset) return;
            offset = value;
            Invalidate();
        }

        /// <summary>Also called by the window, for a wheel turned while something else has the focus.</summary>
        public void Wheel(int delta) => ScrollTo(offset - delta / 120f * F(WheelStep));

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            Wheel(e.Delta);
            if (e is HandledMouseEventArgs handled) handled.Handled = true;
        }

        RectangleF Thumb
        {
            get
            {
                float h = Math.Min(Height, Math.Max(F(MinThumb), Height * Height / contentHeight));
                return new RectangleF(Width - F(BarWidth), MaxOffset <= 0 ? 0 : (Height - h) * offset / MaxOffset, F(BarWidth), h);
            }
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (MaxOffset <= 0) return;
            Focus();
            if (e.Button != MouseButtons.Left || e.X < Width - F(BarGutter)) return;
            var thumb = Thumb;
            grabbed = e.Y >= thumb.Top && e.Y <= thumb.Bottom ? e.Y - thumb.Top : thumb.Height / 2;
            DragTo(e.Y);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (grabbed >= 0) DragTo(e.Y);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            grabbed = -1;
            Invalidate();
        }

        void DragTo(int y)
        {
            float travel = Height - Thumb.Height;
            if (travel > 0) ScrollTo((y - grabbed) / travel * MaxOffset);
        }

        protected override bool IsInputKey(Keys keyData) =>
            (MaxOffset > 0 && (keyData == Keys.Up || keyData == Keys.Down)) || base.IsInputKey(keyData);

        protected override void OnKeyDown(KeyEventArgs e)
        {
            switch (e.KeyCode)
            {
                case Keys.Up: ScrollTo(offset - F(KeyStep)); break;
                case Keys.Down: ScrollTo(offset + F(KeyStep)); break;
                case Keys.PageUp: ScrollTo(offset - Height * 0.85f); break;
                case Keys.PageDown: ScrollTo(offset + Height * 0.85f); break;
                case Keys.Home: ScrollTo(0); break;
                case Keys.End: ScrollTo(MaxOffset); break;
                default: base.OnKeyDown(e); return;
            }
            e.Handled = true;
        }

        // --- Drawing ---------------------------------------------------------------------

        protected override void Draw(Graphics g)
        {
            float y = -offset;
            var number = Font(15, true);
            for (int i = 0; i < stepLayouts.Length; i++)
            {
                TextKit.Draw(g, (i + 1).ToString(), number, Tertiary, 0, TextKit.BaselineIn(number, y, F(22)));
                stepLayouts[i].Draw(g, F(28), y, Ink);
                y += stepLayouts[i].Height + F(14);
            }
            if (noteLayouts.Length > 0) y += F(10);
            foreach (var p in noteLayouts)
            {
                p.Draw(g, 0, y, Tertiary);
                y += p.Height + F(6);
            }
            if (MaxOffset <= 0) return;

            // The text fades out where there's more of it, and the bar is the same thin one the pickers have.
            if (offset > 0) Fade(g, 0, F(TopFade), Background, Color.FromArgb(0, Background));
            if (offset < MaxOffset) Fade(g, Height - F(BottomFade), F(BottomFade), Color.FromArgb(0, Background), Background);
            var thumb = Thumb;
            var color = Focused && ShowFocusCues ? Ink : grabbed >= 0 || Hovered ? Quaternary : Hairline;
            FillRounded(g, color, thumb, thumb.Width / 2);
        }

        void Fade(Graphics g, float top, float height, Color from, Color to)
        {
            var area = new RectangleF(0, top, Width - F(BarGutter), height);
            // A pixel over at each end: a gradient's own edge wraps round to its other color.
            using (var brush = new System.Drawing.Drawing2D.LinearGradientBrush(RectangleF.Inflate(area, 0, 1), from, to, 90f))
                g.FillRectangle(brush, area);
        }
    }

    /// <summary>A selectable row with a radio mark, used on the undo screen.</summary>
    sealed class OptionRow : DrawnControl
    {
        readonly string title, description;
        bool selected;

        public event EventHandler Chosen;

        public OptionRow(string title, string description, int width)
        {
            MakeClickable();
            this.title = title;
            this.description = description;
            Size = new Size(width, S(68));
        }

        public bool Selected
        {
            get => selected;
            set { selected = value; Invalidate(); }
        }

        protected override void OnClick(EventArgs e)
        {
            base.OnClick(e);
            if (!Enabled) return;
            Focus();
            Chosen?.Invoke(this, EventArgs.Empty);
        }

        protected override void Draw(Graphics g)
        {
            var r = new RectangleF(0.5f, 0.5f, Width - 1, Height - 1);
            FillRounded(g, selected ? Fill : Hovered && Enabled ? FillHover : Background, r, F(12));
            StrokeRounded(g, selected ? Ink : Hairline, r, F(12), selected ? F(1.5f) : 1);
            DrawFocusRing(g, r, F(12));

            float d = F(18), cx = F(20);
            var radio = new RectangleF(cx, (Height - d) / 2, d, d);
            using (var pen = new Pen(selected ? Ink : Quaternary, F(1.5f))) g.DrawEllipse(pen, radio);
            if (selected)
                using (var dot = new SolidBrush(Ink)) g.FillEllipse(dot, RectangleF.Inflate(radio, -F(4.5f), -F(4.5f)));

            float x = F(54);
            var titleFont = Font(15, true);
            var bodyFont = Font(14);
            TextKit.Draw(g, title, titleFont, Enabled ? Ink : Tertiary, x, F(28));
            TextKit.Draw(g, TextKit.Ellipsize(description, bodyFont, Width - x - F(20)), bodyFont, Secondary, x, F(49));
        }
    }

    /// <summary>A thin line with a segment gliding across it, for work without a percentage.</summary>
    sealed class BusyLine : DrawnControl
    {
        readonly Timer animation = new Timer { Interval = 16 };
        readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();

        public BusyLine()
        {
            Height = S(3);
            animation.Tick += (s, e) => Invalidate();
        }

        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            animation.Enabled = Visible;
        }

        protected override void Draw(Graphics g)
        {
            var track = new RectangleF(0, 0, Width, Height);
            FillRounded(g, Fill, track, Height / 2f);
            // One pass every 1.6 s, eased so the segment speeds up in the middle.
            double t = clock.Elapsed.TotalSeconds % 1.6 / 1.6;
            float eased = (float)(0.5 - Math.Cos(t * Math.PI) / 2);
            float segment = Width * 0.28f;
            float x = -segment + (Width + segment) * eased;
            var bar = RectangleF.Intersect(track, new RectangleF(x, 0, segment, Height));
            if (bar.Width > 0) FillRounded(g, Ink, bar, Height / 2f);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) animation.Dispose();
            base.Dispose(disposing);
        }
    }
}
