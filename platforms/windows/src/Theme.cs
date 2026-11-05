using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;

namespace Usbless
{
    /// <summary>Colors, type and drawing helpers from the Paper design.</summary>
    static class Theme
    {
        public static readonly Color Background = Color.White;
        public static readonly Color Ink = Hex("#1D1D1F");
        public static readonly Color Secondary = Hex("#6E6E73");
        public static readonly Color Tertiary = Hex("#86868B");
        public static readonly Color Quaternary = Hex("#AEAEB2");
        public static readonly Color Hairline = Hex("#D2D2D7");
        public static readonly Color Fill = Hex("#F2F2F7");
        public static readonly Color FillHover = Hex("#F5F5F7");
        public static readonly Color DriveUsed = Hex("#D2D2D7");
        public static readonly Color DriveFree = Hex("#EBEBF0");
        public static readonly Color DriveUsedText = Hex("#48484A");
        public static readonly Color Danger = Hex("#D70015");
        public static readonly Color CloseHover = Hex("#C42B1C");
        public static readonly Color PrimaryHover = Hex("#3A3A3C");

        /// <summary>Screen scale factor; 1.0 at 100 %, 1.25 at 125 %.</summary>
        public static float Scale = 1f;

        /// <summary>Converts a size from the design (at 100 %) to device pixels.</summary>
        public static int S(float value) => (int)Math.Round(value * Scale);
        public static float F(float value) => value * Scale;

        public static Color Hex(string hex) => ColorTranslator.FromHtml(hex);

        public static Color Mix(Color a, Color b, float amount) => Color.FromArgb(
            (int)(a.R + (b.R - a.R) * amount), (int)(a.G + (b.G - a.G) * amount), (int)(a.B + (b.B - a.B) * amount));

        /// <summary>Text color that reads on top of <paramref name="fill"/>.</summary>
        public static Color TextOn(Color fill)
        {
            double luminance = (0.2126 * fill.R + 0.7152 * fill.G + 0.0722 * fill.B) / 255;
            return luminance > 0.55 ? Ink : Color.White;
        }

        // --- Fonts: Instrument Sans, embedded ------------------------------------

        static readonly PrivateFontCollection fonts = new PrivateFontCollection();
        static readonly List<GCHandle> pinned = new List<GCHandle>();
        static readonly Dictionary<(bool, float), Font> cache = new Dictionary<(bool, float), Font>();
        static FontFamily regularFamily, mediumFamily;

        public static void LoadFonts()
        {
            foreach (var name in new[] { "InstrumentSans-400.ttf", "InstrumentSans-500.ttf" })
            {
                byte[] data;
                using (var stream = typeof(Theme).Assembly.GetManifestResourceStream("Usbless.Fonts." + name))
                using (var memory = new MemoryStream())
                {
                    stream.CopyTo(memory);
                    data = memory.ToArray();
                }
                // GDI+ reads the font from this memory for as long as it is used, so keep it pinned.
                var handle = GCHandle.Alloc(data, GCHandleType.Pinned);
                pinned.Add(handle);
                fonts.AddMemoryFont(handle.AddrOfPinnedObject(), data.Length);
            }
            foreach (var family in fonts.Families)
            {
                if (family.Name.EndsWith("Medium")) mediumFamily = family;
                else regularFamily = family;
            }
            regularFamily = regularFamily ?? new FontFamily("Segoe UI");
            mediumFamily = mediumFamily ?? new FontFamily("Segoe UI Semibold");
        }

        /// <summary>A font at a pixel size from the design.</summary>
        public static Font Font(float px, bool medium = false)
        {
            var key = (medium, px);
            if (!cache.TryGetValue(key, out var font))
                cache[key] = font = new Font(medium ? mediumFamily : regularFamily, F(px), FontStyle.Regular, GraphicsUnit.Pixel);
            return font;
        }

        // --- Drawing -----------------------------------------------------------------

        // Grid fitting closes up the gaps between words at small sizes: "Movingfiles" at 100%, seen on a real Windows.
        public const TextRenderingHint TextHint = TextRenderingHint.AntiAlias;

        public static void Prepare(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.TextRenderingHint = TextHint;
        }

        public static GraphicsPath RoundedRect(RectangleF r, float radius)
        {
            var path = new GraphicsPath();
            float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
            if (d <= 0.5f)
            {
                path.AddRectangle(r);
                return path;
            }
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        public static void FillRounded(Graphics g, Color color, RectangleF r, float radius)
        {
            using (var path = RoundedRect(r, radius))
            using (var brush = new SolidBrush(color)) g.FillPath(brush, path);
        }

        public static void StrokeRounded(Graphics g, Color color, RectangleF r, float radius, float width = 1)
        {
            using (var path = RoundedRect(r, radius))
            using (var pen = new Pen(color, width)) g.DrawPath(pen, path);
        }

        /// <summary>A soft drop shadow made of a few widening, fading rounded rectangles.</summary>
        public static void Shadow(Graphics g, RectangleF r, float radius, int layers, int alpha)
        {
            for (int i = layers; i >= 1; i--)
            {
                var grown = RectangleF.Inflate(r, i, i);
                grown.Offset(0, i * 0.5f);
                FillRounded(g, Color.FromArgb(alpha / layers, 0, 0, 0), grown, radius + i);
            }
        }

        public static void DrawImageFit(Graphics g, Image image, RectangleF box)
        {
            if (image == null) return;
            float scale = Math.Min(box.Width / image.Width, box.Height / image.Height);
            float w = image.Width * scale, h = image.Height * scale;
            g.DrawImage(image, box.X + (box.Width - w) / 2, box.Y + (box.Height - h) / 2, w, h);
        }

        // --- Logos ----------------------------------------------------------------------

        static readonly Dictionary<string, Image> logos = new Dictionary<string, Image>();

        public static Image Logo(string name)
        {
            if (string.IsNullOrEmpty(name)) return IsoGlyph;
            if (logos.TryGetValue(name, out var image)) return image;
            using (var stream = typeof(Theme).Assembly.GetManifestResourceStream("Usbless.Logos." + name + ".png"))
                image = stream == null ? DistributionGlyph(name) : new Bitmap(stream);
            return logos[name] = image;
        }

        // Original letter marks avoid redistributing third-party distro artwork.
        static Image DistributionGlyph(string name)
        {
            var bitmap = new Bitmap(128, 128, PixelFormat.Format32bppArgb);
            var words = name.Split('-');
            string mark = words[0].Substring(0, 1).ToUpperInvariant();
            if (words.Length > 1 && words[1].Length > 0) mark += words[1].Substring(0, 1).ToUpperInvariant();
            using (var g = Graphics.FromImage(bitmap))
            using (var brush = new SolidBrush(Ink))
            using (var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            {
                Prepare(g);
                FillRounded(g, Fill, new RectangleF(4, 4, 120, 120), 24);
                g.DrawString(mark, Font(42, true), brush, new RectangleF(4, 4, 120, 120), format);
            }
            return bitmap;
        }

        static Image isoGlyph;

        /// <summary>A disc, for ISO files the user picked themselves.</summary>
        static Image IsoGlyph
        {
            get
            {
                if (isoGlyph != null) return isoGlyph;
                var bitmap = new Bitmap(128, 128, PixelFormat.Format32bppArgb);
                using (var g = Graphics.FromImage(bitmap))
                {
                    Prepare(g);
                    using (var pen = new Pen(Ink, 10)) g.DrawEllipse(pen, 13, 13, 102, 102);
                    using (var brush = new SolidBrush(Ink)) g.FillEllipse(brush, 50, 50, 28, 28);
                }
                return isoGlyph = bitmap;
            }
        }
    }
}
