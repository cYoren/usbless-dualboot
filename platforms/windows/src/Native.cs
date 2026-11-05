using System;
using System.Runtime.InteropServices;

namespace Usbless
{
    static class Native
    {
        const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
        const int DWMWCP_ROUND = 2, DWMWCP_ROUNDSMALL = 3;
        const int WM_NCLBUTTONDOWN = 0xA1, HTCAPTION = 2;

        public const int CS_DROPSHADOW = 0x20000;
        public const int WS_MINIMIZEBOX = 0x20000, WS_SYSMENU = 0x80000;

        /// <summary>Windows 11 rounded corners. Does nothing on Windows 10.</summary>
        public static void RoundCorners(IntPtr hwnd, bool small = false)
        {
            if (!IsWindows11) return;
            int preference = small ? DWMWCP_ROUNDSMALL : DWMWCP_ROUND;
            try { DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref preference, sizeof(int)); } catch { }
        }

        public static bool IsWindows11 => Environment.OSVersion.Version.Build >= 22000;

        /// <summary>Lets a mouse press on a custom title area move the window.</summary>
        public static void BeginWindowDrag(IntPtr hwnd)
        {
            ReleaseCapture();
            SendMessage(hwnd, WM_NCLBUTTONDOWN, (IntPtr)HTCAPTION, IntPtr.Zero);
        }

        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        [DllImport("user32.dll")]
        static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
    }
}
