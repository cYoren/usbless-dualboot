using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Usbless
{
    /// <summary>
    /// UEFI boot entries (the Boot#### and BootNext variables), written directly the way
    /// efibootmgr does on Linux. bcdedit can't do this: a copy of {bootmgr} is a Windows
    /// Boot Manager object, which bcdedit refuses as a one-time boot target.
    /// Called from the engine scripts as [Usbless.Firmware].
    /// </summary>
    public sealed class BootEntry
    {
        public int Number { get; set; }
        public string Description { get; set; } = "";
        public string PartitionGuid { get; set; }   // "{...}", when the entry starts a file on a GPT partition
        public string Path { get; set; }            // e.g. \EFI\ubuntu\shimx64.efi
    }

    public static class Firmware
    {
        const string GlobalVariables = "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}";
        const int ErrorEnvVarNotFound = 203;
        const uint LoadOptionActive = 1;
        const uint FirmwareTypeUefi = 2;

        /// <summary>True when Windows started through UEFI rather than Legacy BIOS.</summary>
        public static bool IsUefi() => GetFirmwareType(out uint type) && type == FirmwareTypeUefi;

        /// <summary>The entry set to start once, or null. Firmware clears this as it starts up, so one still set was never acted on.</summary>
        public static int? BootNext() => ReadNumber("BootNext");

        /// <summary>The entry this start used, or null.</summary>
        public static int? BootCurrent() => ReadNumber("BootCurrent");

        public static int[] BootOrderNumbers()
        {
            EnablePrivilege();
            return Array.ConvertAll(BootOrder(), number => (int)number);
        }

        static int? ReadNumber(string name)
        {
            EnablePrivilege();
            var data = TryRead(name);
            return data != null && data.Length >= 2 ? BitConverter.ToUInt16(data, 0) : (int?)null;
        }

        /// <summary>
        /// Fails if usbless couldn't add a startup entry, using the same read and write that needs.
        /// Writing BootOrder back unchanged is the one write that leaves the startup menu as it was.
        /// </summary>
        public static void CheckAccess()
        {
            EnablePrivilege();
            var order = Read("BootOrder");
            if (order != null) Write("BootOrder", order);
        }

        /// <summary>Adds an entry that starts <paramref name="path"/> on a GPT partition. Returns its number.</summary>
        public static int CreateBootEntry(string description, int partitionNumber, long startLba, long sizeLba,
            string partitionGuid, string path)
        {
            EnablePrivilege();
            int number = FreeNumber();
            Write(EntryName(number), LoadOption(description, partitionNumber, startLba, sizeLba, new Guid(partitionGuid), path));

            // Listing it in BootOrder too makes it show up in the firmware's boot menu (F11 on MSI).
            var order = new List<ushort>(BootOrder());
            if (!order.Contains((ushort)number))
            {
                order.Add((ushort)number);
                WriteBootOrder(order);
            }
            return number;
        }

        /// <summary>Starts the entry once, on the next restart only.</summary>
        public static void SetBootNext(int number)
        {
            EnablePrivilege();
            if (Read(EntryName(number)) == null) throw new InvalidOperationException($"The startup entry Boot{number:X4} no longer exists.");
            Write("BootNext", BitConverter.GetBytes((ushort)number));
        }

        /// <summary>Forgets the one-time start, for when the restart it was for didn't happen.</summary>
        public static void ClearBootNext()
        {
            EnablePrivilege();
            Write("BootNext", null);
        }

        public static void DeleteBootEntry(int number)
        {
            EnablePrivilege();
            if (Read(EntryName(number)) != null) Write(EntryName(number), null);
            var order = new List<ushort>(BootOrder());
            if (order.Remove((ushort)number)) WriteBootOrder(order);
            var next = Read("BootNext");
            if (next != null && next.Length >= 2 && BitConverter.ToUInt16(next, 0) == number) Write("BootNext", null);
        }

        /// <summary>Numbers of the entries whose description contains <paramref name="text"/>.</summary>
        public static int[] FindEntries(string text)
        {
            EnablePrivilege();
            var found = new List<int>();
            for (int number = 0; number <= 0xFF; number++)
            {
                var data = TryRead(EntryName(number));
                if (data != null && Description(data).Contains(text)) found.Add(number);
            }
            return found.ToArray();
        }

        /// <summary>Every Boot#### entry, with the partition and file it starts when it has one.</summary>
        public static BootEntry[] ListEntries()
        {
            EnablePrivilege();
            var entries = new List<BootEntry>();
            for (int number = 0; number <= 0xFF; number++)
            {
                var data = TryRead(EntryName(number));
                if (data == null || data.Length < 8) continue;
                var entry = new BootEntry { Number = number, Description = Description(data) };
                int pathLength = BitConverter.ToUInt16(data, 4);
                int node = 6 + (entry.Description.Length + 1) * 2;
                int end = Math.Min(data.Length, node + pathLength);
                while (node + 4 <= end)
                {
                    byte type = data[node], subtype = data[node + 1];
                    int length = BitConverter.ToUInt16(data, node + 2);
                    if (length < 4 || node + length > end || type == 0x7F) break;
                    if (type == 0x04 && subtype == 0x01 && length >= 42 && data[node + 41] == 0x02)
                    {
                        var guid = new byte[16];
                        Array.Copy(data, node + 24, guid, 0, 16);
                        entry.PartitionGuid = new Guid(guid).ToString("B");
                    }
                    else if (type == 0x04 && subtype == 0x04)
                    {
                        entry.Path = Encoding.Unicode.GetString(data, node + 4, length - 4).TrimEnd('\0');
                    }
                    node += length;
                }
                entries.Add(entry);
            }
            return entries.ToArray();
        }

        static string EntryName(int number) => $"Boot{number:X4}";

        static int FreeNumber()
        {
            for (int number = 0; number <= 0xFFFF; number++)
                if (Read(EntryName(number)) == null) return number;
            throw new InvalidOperationException("The firmware has no free startup entries.");
        }

        static ushort[] BootOrder()
        {
            var data = Read("BootOrder") ?? new byte[0];
            var order = new ushort[data.Length / 2];
            for (int i = 0; i < order.Length; i++) order[i] = BitConverter.ToUInt16(data, i * 2);
            return order;
        }

        static void WriteBootOrder(List<ushort> order)
        {
            var data = new byte[order.Count * 2];
            for (int i = 0; i < order.Count; i++) BitConverter.GetBytes(order[i]).CopyTo(data, i * 2);
            Write("BootOrder", data);
        }

        // EFI_LOAD_OPTION: attributes, device path length, description, device path.
        public static byte[] LoadOption(string description, int partitionNumber, long startLba, long sizeLba, Guid partition, string path)
        {
            byte[] devicePath = Concat(HardDriveNode(partitionNumber, startLba, sizeLba, partition), FilePathNode(path), new byte[] { 0x7F, 0xFF, 0x04, 0x00 });
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream))
            {
                writer.Write(LoadOptionActive);
                writer.Write((ushort)devicePath.Length);
                writer.Write(Encoding.Unicode.GetBytes(description + "\0"));
                writer.Write(devicePath);
                return stream.ToArray();
            }
        }

        // Media device path, hard drive: a GPT partition identified by its GUID.
        static byte[] HardDriveNode(int partitionNumber, long startLba, long sizeLba, Guid partition)
        {
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream))
            {
                writer.Write((byte)0x04);
                writer.Write((byte)0x01);
                writer.Write((ushort)42);
                writer.Write((uint)partitionNumber);
                writer.Write((ulong)startLba);
                writer.Write((ulong)sizeLba);
                writer.Write(partition.ToByteArray());   // same byte layout as EFI_GUID
                writer.Write((byte)0x02);                // partition format: GPT
                writer.Write((byte)0x02);                // signature type: GUID
                return stream.ToArray();
            }
        }

        // Media device path, file path.
        static byte[] FilePathNode(string path)
        {
            byte[] name = Encoding.Unicode.GetBytes(path + "\0");
            var node = new byte[4 + name.Length];
            node[0] = 0x04;
            node[1] = 0x04;
            BitConverter.GetBytes((ushort)node.Length).CopyTo(node, 2);
            name.CopyTo(node, 4);
            return node;
        }

        static string Description(byte[] option)
        {
            if (option.Length < 8) return "";
            int end = 6;
            while (end + 1 < option.Length && (option[end] != 0 || option[end + 1] != 0)) end += 2;
            return Encoding.Unicode.GetString(option, 6, end - 6);
        }

        static byte[] Concat(params byte[][] parts)
        {
            using (var stream = new MemoryStream())
            {
                foreach (var part in parts) stream.Write(part, 0, part.Length);
                return stream.ToArray();
            }
        }

        static byte[] Read(string name)
        {
            var buffer = new byte[8192];
            uint length = GetFirmwareEnvironmentVariable(name, GlobalVariables, buffer, (uint)buffer.Length);
            if (length == 0)
            {
                int error = Marshal.GetLastWin32Error();
                if (error == ErrorEnvVarNotFound) return null;
                throw new Win32Exception(error, $"Could not read the firmware variable {name}. {WindowsError(error)}");
            }
            var data = new byte[length];
            Array.Copy(buffer, data, length);
            return data;
        }

        // For listing: one variable the firmware won't hand over shouldn't hide the others.
        static byte[] TryRead(string name)
        {
            try { return Read(name); }
            catch (Win32Exception) { return null; }
        }

        /// <summary>Writes a variable; null deletes it.</summary>
        static void Write(string name, byte[] data)
        {
            if (!SetFirmwareEnvironmentVariable(name, GlobalVariables, data, (uint)(data?.Length ?? 0)))
            {
                int error = Marshal.GetLastWin32Error();
                if (data == null && error == ErrorEnvVarNotFound) return;
                throw new Win32Exception(error, $"Could not write the firmware variable {name}. {WindowsError(error)}");
            }
        }

        static string WindowsError(int error) => $"Windows error {error}: {new Win32Exception(error).Message}";

        // Every time, not once: other code in this process can turn the privilege back off.
        static void EnablePrivilege()
        {
            const uint TokenAdjustPrivileges = 0x20, TokenQuery = 0x8, PrivilegeEnabled = 0x2;
            if (!OpenProcessToken(GetCurrentProcess(), TokenAdjustPrivileges | TokenQuery, out var token))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                if (!LookupPrivilegeValue(null, "SeSystemEnvironmentPrivilege", out var luid))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                var privileges = new TokenPrivileges { Count = 1, Luid = luid, Attributes = PrivilegeEnabled };
                if (!AdjustTokenPrivileges(token, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero) || Marshal.GetLastWin32Error() != 0)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows did not allow changing startup entries.");
            }
            finally
            {
                CloseHandle(token);
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        struct Luid
        {
            public uint Low;
            public int High;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        struct TokenPrivileges
        {
            public uint Count;
            public Luid Luid;
            public uint Attributes;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFirmwareType(out uint type);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "GetFirmwareEnvironmentVariableW")]
        static extern uint GetFirmwareEnvironmentVariable(string name, string guid, byte[] buffer, uint size);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "SetFirmwareEnvironmentVariableW")]
        static extern bool SetFirmwareEnvironmentVariable(string name, string guid, byte[] value, uint size);

        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, uint length, IntPtr previous, IntPtr returnLength);
    }
}
