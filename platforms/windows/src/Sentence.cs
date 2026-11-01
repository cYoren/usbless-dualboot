using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using static Usbless.Theme;

namespace Usbless
{
    /// <summary>One piece of the sentence: plain words, or the system with its logo.</summary>
    sealed class Run
    {
        public string Text;
        public Color Color;
        public Image Logo;
        public bool Picker;        // clickable, with a chevron and an underline in Underline
        public Color Underline;

        public static Run Gray(string text) => new Run { Text = text, Color = Tertiary };
        public static Run Black(string text) => new Run { Text = text, Color = Ink };
        public static Run Red(string text) => new Run { Text = text, Color = Danger };
    }

    /// <summary>The large two-line sentence at the top of every screen.</summary>
    sealed class Sentence : DrawnControl
    {
        const float Px = 38, LineHeight = 46, WordGap = 10, LogoSize = 32, LogoGap = 12, ChevronSize = 22;
        static float Tracking => F(-0.025f * Px);

        readonly List<Run[]> lines = new List<Run[]>();
        readonly List<RectangleF> pickerRects = new List<RectangleF>();
        int focusedPicker;

        /// <summary>Which picker in the sentence was clicked, counting from the start.</summary>
        public event Action<int> PickerClicked;

        public void Set(params Run[][] newLines)
        {
            lines.Clear();
            lines.AddRange(newLines);
            Height = S(LineHeight * lines.Count + 4);
            bool hasPicker = false;
            foreach (var line in lines) foreach (var run in line) hasPicker |= run.Picker;
            SetStyle(ControlStyles.Selectable, hasPicker);
            TabStop = hasPicker;
            if (!hasPicker) { pickerRects.Clear(); focusedPicker = 0; }
            Invalidate();
        }

        /// <summary>Cuts the name in a line so that the rest stays on screen, with its chevron if it's a picker.</summary>
        public string FitName(string name, bool picker, params string[] others)
        {
            var font = Font(Px, true);
            float room = Width - (picker ? F(6 + ChevronSize) : 0);
            foreach (string other in others) room -= TextKit.Width(other, font, Tracking) + F(WordGap);
            return TextKit.Ellipsize(name, font, room, Tracking);
        }

        /// <summary>Where a picker sits, in screen coordinates, for placing what it opens.</summary>
        public Rectangle PickerScreenBounds(int picker) => RectangleToScreen(pickerRects.Count == 0
            ? new Rectangle(0, 0, 0, Height)
            : Rectangle.Round(pickerRects[Math.Min(picker, pickerRects.Count - 1)]));

        int PickerAt(Point p) => pickerRects.FindIndex(r => RectangleF.Inflate(r, F(6), F(2)).Contains(p));

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            int over = PickerAt(e.Location);
            Cursor = over >= 0 ? Cursors.Hand : Cursors.Default;
            if (over != pickerHot) { pickerHot = over; Invalidate(); }
        }

        int pickerHot = -1;

        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); pickerHot = -1; }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            int over = PickerAt(e.Location);
            if (e.Button == MouseButtons.Left && over >= 0) PickerClicked?.Invoke(over);
        }

        protected override void OnClick(EventArgs e)
        {
            // Mouse clicks are handled in OnMouseUp; this is the keyboard path from DrawnControl.
            if (pickerRects.Count > 0 && !(e is MouseEventArgs)) PickerClicked?.Invoke(Math.Min(focusedPicker, pickerRects.Count - 1));
        }

        protected override bool IsInputKey(Keys keyData) =>
            (pickerRects.Count > 1 && (keyData == Keys.Left || keyData == Keys.Right)) || base.IsInputKey(keyData);

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (pickerRects.Count > 1 && (e.KeyCode == Keys.Left || e.KeyCode == Keys.Right))
            {
                focusedPicker = e.KeyCode == Keys.Right ? Math.Min(pickerRects.Count - 1, focusedPicker + 1) : Math.Max(0, focusedPicker - 1);
                e.Handled = true;
                Invalidate();
                return;
            }
            base.OnKeyDown(e);
        }

        protected override void Draw(Graphics g)
        {
            var font = Font(Px, true);
            float lineHeight = F(LineHeight);

            // Lay out first so the hover background can go behind the picker.
            var placed = new List<(Run run, float x, float top, float width)>();
            pickerRects.Clear();
            for (int i = 0; i < lines.Count; i++)
            {
                float x = 0, top = i * lineHeight;
                foreach (var run in lines[i])
                {
                    float start = x;
                    if (run.Logo != null) x += F(LogoSize + LogoGap);
                    x += TextKit.Width(run.Text, font, Tracking);
                    if (run.Picker) x += F(6 + ChevronSize);
                    placed.Add((run, start, top, x - start));
                    if (run.Picker) pickerRects.Add(new RectangleF(start, top, x - start, lineHeight + F(3)));
                    x += F(WordGap);
                }
            }

            if (pickerHot >= 0 && pickerHot < pickerRects.Count)
                FillRounded(g, FillHover, RectangleF.Inflate(pickerRects[pickerHot], F(8), F(2)), F(10));
            if (Focused && ShowFocusCues && focusedPicker < pickerRects.Count)
                StrokeRounded(g, Color.FromArgb(120, Ink), RectangleF.Inflate(pickerRects[focusedPicker], F(8), F(2)), F(10), F(2));

            foreach (var (run, x, top, width) in placed)
            {
                float textX = x;
                if (run.Logo != null)
                {
                    DrawImageFit(g, run.Logo, new RectangleF(x, top + (lineHeight - F(LogoSize)) / 2, F(LogoSize), F(LogoSize)));
                    textX += F(LogoSize + LogoGap);
                }
                float baseline = TextKit.BaselineIn(font, top, lineHeight);
                TextKit.Draw(g, run.Text, font, run.Color, textX, baseline, Tracking);
                if (!run.Picker) continue;

                float cx = x + width - F(ChevronSize) / 2, cy = top + lineHeight / 2 + F(3);
                using (var pen = new Pen(Ink, F(2.2f)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
                    g.DrawLines(pen, new[] { new PointF(cx - F(5), cy - F(2.5f)), new PointF(cx, cy + F(2.5f)), new PointF(cx + F(5), cy - F(2.5f)) });
                using (var brush = new SolidBrush(run.Underline))
                    g.FillRectangle(brush, x, top + lineHeight + F(1), width, F(2));
            }
        }
    }
}
