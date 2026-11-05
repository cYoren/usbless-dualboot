using System;
using System.Collections.Generic;
using System.Drawing;

namespace Usbless
{
    /// <summary>
    /// Text measured and drawn by baseline with GDI+, so the embedded font, letter
    /// spacing and line heights match the design.
    /// </summary>
    static class TextKit
    {
        static readonly StringFormat Format = CreateFormat();
        // Measured as it's drawn: see Theme.Prepare. Widths differ between hints, and words are placed by them.
        static readonly Graphics Measurer = CreateMeasurer();

        static Graphics CreateMeasurer()
        {
            var g = Graphics.FromImage(new Bitmap(1, 1));
            g.TextRenderingHint = Theme.TextHint;
            return g;
        }

        static StringFormat CreateFormat()
        {
            var format = (StringFormat)StringFormat.GenericTypographic.Clone();
            format.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces | StringFormatFlags.NoWrap;
            return format;
        }

        public static float Ascent(Font font) =>
            font.Size * font.FontFamily.GetCellAscent(font.Style) / font.FontFamily.GetEmHeight(font.Style);

        public static float Descent(Font font) =>
            font.Size * font.FontFamily.GetCellDescent(font.Style) / font.FontFamily.GetEmHeight(font.Style);

        /// <summary>Baseline that centers the font's glyphs in a line box of the given height.</summary>
        public static float BaselineIn(Font font, float lineTop, float lineHeight) =>
            lineTop + (lineHeight - Ascent(font) - Descent(font)) / 2 + Ascent(font);

        public static float Width(string text, Font font, float tracking = 0)
        {
            if (string.IsNullOrEmpty(text)) return 0;
            lock (Measurer)
                return Measurer.MeasureString(text, font, PointF.Empty, Format).Width + tracking * text.Length;
        }

        public static void Draw(Graphics g, string text, Font font, Color color, float x, float baseline, float tracking = 0)
        {
            if (string.IsNullOrEmpty(text)) return;
            float top = baseline - Ascent(font);
            using (var brush = new SolidBrush(color))
            {
                if (tracking == 0)
                {
                    g.DrawString(text, font, brush, x, top, Format);
                    return;
                }
                // GDI+ has no letter spacing: place each character where the untracked
                // prefix ends, shifted by the accumulated tracking. This keeps kerning.
                for (int i = 0; i < text.Length; i++)
                {
                    if (char.IsWhiteSpace(text[i])) continue;
                    float offset = i == 0 ? 0 : Width(text.Substring(0, i), font);
                    g.DrawString(text[i].ToString(), font, brush, x + offset + tracking * i, top, Format);
                }
            }
        }

        public static string Ellipsize(string text, Font font, float maxWidth, float tracking = 0)
        {
            if (Width(text, font, tracking) <= maxWidth) return text;
            for (int length = text.Length - 1; length > 0; length--)
            {
                string candidate = text.Substring(0, length).TrimEnd() + "…";
                if (Width(candidate, font, tracking) <= maxWidth) return candidate;
            }
            return "…";
        }
    }

    /// <summary>A wrapped paragraph where text between ** is set in the medium weight.</summary>
    sealed class Paragraph
    {
        public struct Word
        {
            public string Text;
            public Font Font;
            public float X, Baseline;
        }

        public readonly List<Word> Words = new List<Word>();
        public float Height;

        public static Paragraph Layout(string markup, float px, float lineHeight, float width)
        {
            var paragraph = new Paragraph();
            var regular = Theme.Font(px);
            var medium = Theme.Font(px, true);
            float line = Theme.F(lineHeight);
            float x = 0, top = 0;
            bool strong = false, lineHasWords = false;

            foreach (var piece in markup.Split(new[] { "**" }, StringSplitOptions.None))
            {
                var font = strong ? medium : regular;
                // Split into words that keep their trailing space, so spacing survives wrapping.
                int start = 0;
                while (start < piece.Length)
                {
                    int end = piece.IndexOf(' ', start);
                    end = end < 0 ? piece.Length : end + 1;
                    string word = piece.Substring(start, end - start);
                    start = end;

                    float w = TextKit.Width(word.TrimEnd(), font);
                    if (lineHasWords && x + w > width)
                    {
                        x = 0;
                        top += line;
                        lineHasWords = false;
                        word = word.TrimStart();
                        if (word.Length == 0) continue;
                    }
                    paragraph.Words.Add(new Word { Text = word, Font = font, X = x, Baseline = TextKit.BaselineIn(font, top, line) });
                    x += TextKit.Width(word, font);
                    lineHasWords = true;
                }
                strong = !strong;
            }
            paragraph.Height = top + line;
            return paragraph;
        }

        public void Draw(Graphics g, float x, float y, Color color)
        {
            foreach (var word in Words)
                TextKit.Draw(g, word.Text, word.Font, color, x + word.X, y + word.Baseline);
        }
    }
}
