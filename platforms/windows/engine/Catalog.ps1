# --- Catalog ------------------------------------------------------------
# Strategy 'prepared': usbless creates the boot + root partitions, for
#   installers whose easy mode can't use free space (elementary, Pop!_OS).
# Strategy 'freespace': usbless leaves unallocated space and the
#   installer's "alongside Windows" option uses it (Ubuntu, Mint).

function New-Entry([string]$Id, [string]$Name, [string]$Note, [string]$Source, [string]$Color, [string]$Logo, [hashtable]$More) {
    $entry = [ordered]@{
        Id = $Id; Name = $Name; Version = $null; Note = $Note; Source = $Source; Color = $Color; Logo = $Logo
        Strategy = 'freespace'; SecureBootOff = $false; Kind = $null; Base = $null; Prefix = $null; Edition = $null
        Mode = $null; Alongside = $null; Manual = $null; ManualExtra = $null; Steps = $null
        Live = $null; LiveFiles = $null; UntriedFile = $null; NoBitLocker = $false; MinGB = 0; Notes = $null; BootConfigs = $null; BootEdits = $null; GrubDir = $null; EspShell = $null; EspLinuxMB = 0; FullDisk = $null; SecondDisk = $null; Refused = $null
    }
    foreach ($key in $More.Keys) { $entry[$key] = $More[$key] }
    [pscustomobject]$entry
}

# Casper, as it finds itself on a partition, adds an ext4 partition called writable after the last one on
# that disk, up to the end of the disk, for the live system's logs. On a USB stick that's spare space. Here it
# can be the space Linux is meant to go in. Nopersistent turns that off, and goes straight after the kernel's
# path, before any --- or --, because what's after those ends up in the installed system too.
# Safe to run again. See docs/ARCHITECTURE.md.
function Get-CasperBoot {
    @{
        BootConfigs = @('boot/grub/grub.cfg')
        BootEdits = [ordered]@{ '(?m)^(\s*linux(?:efi)?\s+/casper\S*)(?=\s|$)(?![^\n]*\snopersistent(?:\s|$))' = '$1 nopersistent' }
    }
}

# Ubiquity, started from the disk it's installing to, says it can't make partitions there, and shows no way to install
# alongside Windows. See docs/TESTING.md. Its steps stay in the catalog for when a route has been seen to the end.
# usbless's own partition gets round that: its manual screen can still use an existing one. So those seen to the end, by id, use
# Strategy 'prepared' and these steps. {ROOTMB} is that partition's size in the MB it shows. Its loader goes on the existing
# EFI partition by itself, and usbless's 1 GB USBLBOOT is left alone. A second disk hasn't been seen to the end, so it's refused.
$UbiquityProven = @('mint-cinnamon', 'mint-mate', 'mint-xfce', 'zorin')

function Get-UbiquityRoute([string]$Id, [string]$Name) {
    if ($Id -notin $UbiquityProven) { return @{ Refused = (Get-UbiquityRefusal $Name) } }
    @{
        Strategy = 'prepared'; Mode = 'Something else'
        Steps = @(
            'Pick your language and keyboard, then click **Continue** until **Installation type**.'
            "It says you can't create, delete or resize partitions on this disk. That's expected: usbless has already made the partition, from the {GB} GB it set aside."
            'In the list, click the {ROOTMB} MB partition, then **Change...**.'
            'Set **Use as** to **Ext4 journaling file system**, tick **Format the partition**, set **Mount point** to **/** and click **OK**.'
            'Leave **Device for boot loader installation** as it is, and click **Install Now**. It uses the existing EFI partition by itself.'
            'Check that only that partition is listed to be formatted as **ext4**, then click **Continue**.'
            "Don't format any other partition, including the 1 GB **fat32** one next to it, and don't change the **efi** one.")
        Notes = @("Afterwards this PC starts $Name first. Its menu lists **Windows Boot Manager**, and Windows stays in your PC's boot menu too. The installer also replaces the fallback loader **\EFI\Boot\bootx64.efi** on Windows' EFI partition. Windows' own files there aren't touched.")
    }
}

function Get-UbiquityRefusal([string]$Name) {
    "usbless can't install $Name next to Windows or on a second disk yet. Its installer won't make a partition on the disk it starts from, and usbless hasn't got it to finish another way."
}

# Official Ubuntu flavours of 26.04 LTS, all published with SHA256SUMS on ubuntu.com.
function New-UbuntuFlavor([string]$Id, [string]$Name, [string]$Note, [string]$Color, [hashtable]$More = @{}) {
    $base = if ($Id -eq 'ubuntu') { 'https://releases.ubuntu.com/26.04/' } else { "https://cdimage.ubuntu.com/$Id/releases/26.04/release/" }
    $settings = @{ Kind = 'ubuntu'; Version = '26.04 LTS'; Base = $base; Prefix = $Id; Alongside = "Install $Name alongside Windows"; Manual = 'Manual installation' }
    $settings += Get-CasperBoot
    foreach ($key in $More.Keys) { $settings[$key] = $More[$key] }
    New-Entry $Id $Name $Note ([uri]$base).Host $Color $Id $settings
}

function New-MintEdition([string]$Edition, [string]$Name, [string]$Note) {
    New-Entry "mint-$Edition" $Name $Note 'the Linux Mint mirror at kernel.org' '#69B53F' 'mint' ((Get-CasperBoot) + (Get-UbiquityRoute "mint-$Edition" $Name) + @{
        Kind = 'mint'; Edition = $Edition; Alongside = 'Install Linux Mint alongside Windows Boot Manager'; Manual = 'Something else' })
}

# How live systems that don't search every partition, as casper does, find the installer.
# Dracut needs the name in root=live:. Its GRUB also runs a media check by default, which is for discs.
# Anaconda protects the whole disk behind /run/initramfs/live, and refuses to install on it. So systemd
# takes that mount point away as it starts, using only kernel arguments, which Secure Boot doesn't check.
# systemd.run on its own would replace the desktop and power off, which the other four arguments prevent.
function Get-DracutBoot([string]$GrubDir) {
    $release = '"systemd.run=/usr/bin/umount -l /run/initramfs/live" systemd.run_success_action=none systemd.run_failure_action=none systemd.unit=graphical.target systemd.wants=kernel-command-line.service'
    @{
        Live = 'LiveOS/squashfs.img'; GrubDir = $GrubDir; BootConfigs = @("$GrubDir/grub.cfg"); EspLinuxMB = 25
        BootEdits = [ordered]@{
            'root=live:CDLABEL=\S+' = "root=live:LABEL=$InstallerLabel $release"
            '\s+rd\.live\.check' = ''
            '(?m)^[ \t]*search\s.*$' = "search --no-floppy --label --set=root $InstallerLabel"
        }
    }
}

# Archiso needs the name in archisolabel=, instead of the date stamp it looks for on a disc.
function Get-ArchisoBoot([string[]]$Configs) {
    @{
        Live = 'arch/x86_64/airootfs.sfs'; BootConfigs = $Configs
        BootEdits = [ordered]@{ 'archisosearchuuid=\S+' = "archisolabel=$InstallerLabel" }
    }
}

# Omarchy's live image is over 4 GB, so it goes on a second partition, as exFAT, which its initramfs can read. The
# boot loader and kernel stay on the FAT32 one, and archisolabel= names the second. Its installer hides the disk behind
# /run/archiso/bootmnt, so systemd takes that mount point away as it starts, as for Fedora. It all goes in one edit, because
# Register-Installer runs them again. The image is still read from the partition, so 8 GB of memory is enough.
function Get-OmarchyBoot {
    $release = '"systemd.run=umount -l /run/archiso/bootmnt" systemd.run_success_action=none systemd.run_failure_action=none systemd.unit=multi-user.target systemd.wants=kernel-command-line.service'
    @{
        Live = 'arch/x86_64/airootfs.sfs'; LiveFiles = 'arch\x86_64\airootfs.*'; GrubDir = 'boot/grub'; BootConfigs = @('boot/grub/grub.cfg')
        BootEdits = [ordered]@{ 'archisosearchuuid=\S+' = "archisolabel=$LiveLabel $release" }
    }
}

# What makes a live system copy itself to memory and let go of the disk it started from, so that
# its installer can erase that disk. Each goes before anything like casper's --- in the kernel's
# line, because what's after that ends up in the installed system too. Word is what must be there
# afterwards. Whether a system gets this at all is up to its catalog entry: see FullDisk below.
# IsoGB and Steps come from the entry.
function Get-FullDiskBoot([string]$Family) {
    switch ($Family) {
        'casper' { @{ Word = 'toram'; Configs = @('boot/grub/grub.cfg'); Edits = [ordered]@{ '(?m)^(\s*linux\s+/casper[^/\s]*/\S+)' = '$1 toram' } } }
        'liveboot' { @{ Word = 'toram'; Configs = @('boot/grub/grub.cfg'); Edits = [ordered]@{ '(?m)^(\s*linux\s+/live/\S+)' = '$1 toram' } } }
        'dracut' { @{ Word = 'rd.live.ram=1'; Configs = @(); Edits = [ordered]@{ 'root=live:LABEL=(\S+)' = 'root=live:LABEL=$1 rd.live.ram=1' } } }
        'archiso' { @{ Word = 'copytoram'; Configs = @(); Edits = [ordered]@{ '(archisobasedir=\S+)' = '$1 copytoram' } } }
    }
}

# Color is the project's brand color, used for its part of the drive in the app.
# Logo names an embedded image (assets/logos/<Logo>.png).
# SecureBootOff: its boot loader or kernel isn't signed, as in Pop!_OS 24.04's ISO, so it can't start with Secure Boot on.
# Live: a file its ISO must have, for systems that aren't Ubuntu-style. Empty means casper, which Read-Iso checks for.
# LiveFiles: what goes on a second, exFAT partition because it's too big for FAT32, as a path pattern on the ISO.
# UntriedFile: a file that means this ISO installs in a way usbless hasn't tried. See Read-Iso.
# NoBitLocker: its installer refuses a disk with BitLocker on it, even paused. See Assert-NoBitLocker.
# MinGB: the least its installer accepts, if that's more than $MinLinuxGB.
# Notes: anything more to say under its Steps.
# BootConfigs and BootEdits: which copied boot files to change, and how (regex = replacement). The first
#   edit is the one usbless can't do without. See Update-BootConfig.
# GrubDir: where its menu is, when GRUB should find the installer partition by label and not /.disk/info.
# EspShell: the ISO's EFI Shell, for a boot loader that can't leave its own partition. See Get-EspShellScript.
# EspLinuxMB: what its installer adds to the EFI partition, if it doesn't notice running out. Anaconda uses 21 MB, and archinstall's GRUB 16 MB.
# Steps: the words to show when the usual choices don't fit its installer. {GB} is the size usbless set aside.
# SecondDisk: its Steps and Notes for a disk Windows isn't on, which replace the usual ones. Only for a system really seen
#   installing on a second disk and then starting from it: see docs/TESTING.md. {DISK} names the disk. Without this, a system
#   with its own Steps is refused there. EspLinuxMB here replaces the usual one, for a system that makes its own EFI partition there.
# Refused: why it can't go next to Windows or on a second disk, in plain words. Replacing Windows is separate.
# FullDisk: offers replacing Windows. Only for a system really seen erasing the disk it started from and then
#   starting from that disk: see docs/TESTING.md. IsoGB is its ISO's size, for refusing before the download
#   when memory's short. Steps is what to click, and {DISK} names the disk.
# Kubuntu is missing on purpose: its ISO has a file over 4 GB, which FAT32 cannot hold.
function Get-Catalog {
    # The same installer as Ubuntu's, whose first choice ends in each flavour's own name.
    $UbuntuErase = @(
        'Pick your language and keyboard, then start the installer.'
        'When asked how to install, choose the one that starts **Erase disk and install**.'
        'Under **Select drive**, choose **{DISK}**. Leave any other drive alone.'
        'On **Ready to install**, check that only **{DISK}** is listed under **Erased**, then click **Install**.')
    $AnacondaErase = @(
        'On the welcome screen, choose **Not Now**.'
        'Open the install app from the dock, then pick your language.'
        'Select **{DISK}** and choose **Use entire disk**. Leave any other drive alone.'
        'On the last screen, check it names only **{DISK}**, then click **Erase data and install**.')
    $EspExtra = 'Also click the existing **EFI System Partition**, choose Edit, set the mount point to **/boot/efi** and keep it unformatted.'
    $CalamaresSteps = @(
        'When asked about partitions, choose **Manual partitioning**. If it lists several drives, pick the one with the {GB} GB of free space.'
        'Click the {GB} GB of **Free Space**, click **Create** and make an **ext4** partition mounted at **/**.'
        'Click the existing **EFI System Partition**, click **Edit**, set the mount point to **/boot/efi** and keep its contents. If the installer then says this partition is small, click **OK**: there is room.'
        "Don't choose **Erase disk**. The installer is running from this drive.")
    $AnacondaSteps = @(
        'On the welcome screen, choose **Not Now**.'
        'Open the install app from the dock, then pick your language.'
        "Select the drive with the {GB} GB usbless set aside and choose **Share disk with other operating systems**."
        'If it warns that **/boot/efi** is smaller than recommended, carry on: usbless has checked there is room.'
        "Don't choose **Use entire disk**. The installer is running from this drive.")
    # With only that drive chosen, Anaconda makes a new EFI partition and /boot there, and fills that drive's largest free space.
    $AnacondaSecondDisk = @(
        'On the welcome screen, choose **Not Now**.'
        'Open the install app from the dock, then pick your language.'
        "Select only **{DISK}**, not the disk Windows is on, and choose **Share disk with other operating systems**."
        'It makes its own EFI partition on that drive and uses its largest free space, which can be more than the {GB} GB usbless set aside.'
        "Don't choose **Use entire disk**. The installer is running from this drive.")
    @(
        New-Entry 'elementary' 'elementary OS' 'Mac-like' 'elementary.io' '#3689E6' 'elementary' ((Get-CasperBoot) + @{
            Kind = 'elementary'; Strategy = 'prepared'; Mode = 'Custom Install (Advanced)'
            FullDisk = (Get-FullDiskBoot 'casper') + @{ IsoGB = 4; Steps = @(
                'Pick your language and keyboard.'
                'At **Try or Install**, choose **Erase Disk and Install**, then click **Next**.'
                'At **Select a Drive**, choose **{DISK}**. Leave any other drive alone. Then click **Next**.'
                "Choose **Don't Encrypt**, or **Enable Drive Encryption** and set a password. The install starts straight after that.") } })
        New-UbuntuFlavor 'ubuntu' 'Ubuntu' 'Most popular' '#E95420' @{ FullDisk = (Get-FullDiskBoot 'casper') + @{ IsoGB = 6; Steps = @(
                'Pick your language and keyboard, then start the installer.'
                'When asked how to install, choose **Erase disk and install Ubuntu**.'
                'Under **Select drive**, choose **{DISK}**. Leave any other drive alone.'
                'On **Ready to install**, check that only **{DISK}** is listed under **Erased**, then click **Install**.') } }
        New-MintEdition 'cinnamon' 'Linux Mint' 'Windows-like'
        New-Entry 'pop' 'Pop!_OS' 'Gaming' 'pop-os.org' '#48B9C7' 'pop' ((Get-CasperBoot) + @{
            Kind = 'pop'; Version = '24.04'; Strategy = 'prepared'; Mode = 'Custom (Advanced)'; SecureBootOff = $true })
        New-Entry 'zorin' 'Zorin OS' 'Windows-like' 'the Zorin OS mirror at kernel.org' '#15A6F0' 'zorin' ((Get-CasperBoot) + (Get-UbiquityRoute 'zorin' 'Zorin OS') + @{
            Kind = 'zorin'; Alongside = 'Install Zorin OS alongside Windows Boot Manager'; Manual = 'Something else'
            FullDisk = (Get-FullDiskBoot 'casper') + @{ IsoGB = 3; Steps = @(
                'Pick your language and keyboard, then start the installer.'
                'When asked how to install, choose **Erase disk and install Zorin OS**.'
                'If it lists more than one drive, choose **{DISK}**. Leave any other drive alone.'
                'Click **Install Now**, check that only **{DISK}** is in the list of changes, then click **Continue**.') } })
        New-Entry 'fedora' 'Fedora Workstation' 'Up to date' 'fedoraproject.org' '#51A2DA' 'fedora' ((Get-DracutBoot 'boot/grub2') + @{
            Kind = 'fedora'; Manual = 'Manual disk configuration'; Steps = $AnacondaSteps
            FullDisk = (Get-FullDiskBoot 'dracut') + @{ IsoGB = 3; Steps = $AnacondaErase }
            SecondDisk = @{ EspLinuxMB = 0; Steps = $AnacondaSecondDisk; Notes = @("Afterwards this PC starts Fedora, from that disk. Its menu lists Windows too.") } })
        New-Entry 'debian' 'Debian' 'Rock solid' 'cdimage.debian.org' '#A80030' 'debian' @{
            Kind = 'debian'; Live = 'live/filesystem.squashfs'; Manual = 'Manual partitioning'; ManualExtra = $EspExtra
            FullDisk = (Get-FullDiskBoot 'liveboot') + @{ IsoGB = 3; Steps = @(
                'At the menu that appears after restarting, press Enter on **Live system**. It waits until you do, then takes a few minutes to copy itself to memory.'
                'On the desktop, open **Install Debian**, then pick your language and keyboard.'
                'At **Partitions**, choose **{DISK}** under **Select storage device**, then choose **Erase disk**.'
                'Fill in your name and password. Check the **Summary** names only that drive, then click **Install**.') }
            Steps = @(
                'At the menu that appears after restarting, press Enter on **Live system**. It waits until you do.'
                'On the desktop, open **Install Debian**, then pick your language and keyboard.') + $CalamaresSteps }
        New-Entry 'cachyos' 'CachyOS' 'Fast, for gaming' 'cachyos.org' '#008066' 'cachyos' ((Get-ArchisoBoot @('boot/grub/grub.cfg')) + @{
            Kind = 'cachyos'; SecureBootOff = $true; GrubDir = 'boot/grub'; Manual = 'Manual partitioning'; ManualExtra = $EspExtra
            # Its other boot loaders keep kernels on the EFI partition, which Windows made too small for them.
            Steps = @('In the CachyOS Hello window, click **Launch installer**, then pick your language and keyboard.', 'On the **Bootloader** screen, choose **GRUB**.') + $CalamaresSteps })
        New-Entry 'arch' 'Arch Linux' 'Do it yourself' 'geo.mirror.pkgbuild.com' '#1793D1' 'arch' ((Get-ArchisoBoot @('loader/entries/*.conf')) + @{
            Kind = 'arch'; SecureBootOff = $true; EspShell = 'shellx64.efi'; EspLinuxMB = 20; Manual = 'Manual Partitioning'; ManualExtra = $EspExtra
            FullDisk = (Get-FullDiskBoot 'archiso') + @{ IsoGB = 2; Steps = @(
                "Arch has no graphical installer. It starts at a text prompt, and it needs the internet: plug in a network cable, or connect to Wi-Fi with **iwctl**."
                'Type **archinstall** and press Enter.'
                'Open **Disk configuration**, then **Partitioning**. Choose **Use a best-effort default partition layout**, select **{DISK}** and choose **ext4**. This wipes that drive.'
                'Under **Bootloader**, choose **Grub**. Set up the rest of the menu as you like, including a Profile if you want a desktop, then choose **Install**.') }
            Steps = @(
                "Arch has no graphical installer. It starts at a text prompt, and it needs the internet: plug in a network cable, or connect to Wi-Fi with **iwctl**."
                'Type **archinstall** and press Enter.'
                "Open **Disk configuration**, then **Partitioning**. Choose **Manual Partitioning** and select the drive with the free space."
                'Select the {GB} GB of free space and make an **ext4** partition with the mountpoint **/**.'
                'Select the existing **fat32** EFI partition, choose **Assign mountpoint** and type **/boot/efi**. Keep it unformatted.'
                'Under **Bootloader**, choose **Grub**. Set up the rest of the menu as you like, including a Profile if you want a desktop, then choose **Install**.'
                "Don't change any other partition. The installer is running from this drive.")
            # GRUB goes on Windows' EFI partition, the one this firmware is known to start, so both disks are chosen.
            SecondDisk = @{
                Steps = @(
                    "Arch has no graphical installer. It starts at a text prompt, and it needs the internet: plug in a network cable, or connect to Wi-Fi with **iwctl**."
                    'Type **archinstall** and press Enter.'
                    'Open **Disk configuration**, then **Partitioning**. Choose **Manual Partitioning**.'
                    'Under **Select disks for the installation**, press Space on **{DISK}** and on the disk Windows is on, so both have an **X**, then press Enter.'
                    'On **{DISK}**, select the {GB} GB of free space and make an **ext4** partition with the mountpoint **/**.'
                    'On the disk Windows is on, select the existing **fat32** EFI partition, choose **Assign mountpoint** and type **/boot/efi**. Keep it unformatted.'
                    'Under **Bootloader**, choose **Grub**. Set up the rest of the menu as you like, including a Profile if you want a desktop, then choose **Install**.'
                    "Don't change any other partition. The installer is running from {DISK}, and Windows needs the rest of its disk.")
                Notes = @("Afterwards this PC starts Arch's GRUB from Windows' EFI partition, and Arch itself from {DISK}. Windows stays in your PC's boot menu.")
            } })
        New-Entry 'omarchy' 'Omarchy' 'Hyprland, ready to go' 'omarchy.org' '#9ECE6A' 'omarchy' ((Get-OmarchyBoot) + @{
            Kind = 'omarchy'; Manual = 'Free space install'; SecureBootOff = $true; NoBitLocker = $true; MinGB = 33; UntriedFile = 'arch\x86_64\omarchy-root.img.zst'; Steps = @(
                'Press **Return** to start, then choose your keyboard.'
                'Make your account. Your password also unlocks the disk if Omarchy encrypts it. Name, email and hostname can be left empty.'
                'Under **Select install disk**, choose the disk Windows is on.'
                "Under **Select installation mode**, press Down to reach **Free space install (alongside existing data)**, then Return. **Don't choose Full disk install**, where the cursor starts: it erases Windows."
                'It should say **Install Omarchy in the {GB} GB of free space**, or close to that. Choose **Yes, install**. To install without encryption, press **Ctrl+C** first.'
                'When it has finished, choose **Reboot Now**.')
            Notes = @("Afterwards this PC starts Omarchy, and its menu doesn't list Windows. To get to Windows, use your PC's boot menu, or run **limine-scan** in Omarchy to add it to the menu.")
            FullDisk = (Get-FullDiskBoot 'archiso') + @{ IsoGB = 7; Steps = @(
                'Press **Return** to start, then choose your keyboard.'
                'Make your account. Your password also unlocks the disk if Omarchy encrypts it. Name, email and hostname can be left empty.'
                'Under **Select install disk**, choose **{DISK}**. Leave any other drive alone.'
                'Under **Select installation mode**, choose **Full disk install**, where the cursor starts.'
                'At **Confirm overwriting**, choose **Yes, install**. To install without encryption, press **Ctrl+C** first.'
                'When it has finished, choose **Reboot Now**.') }
            # It always makes its own EFI partition, in the largest free space on the disk it's given, which isn't always usbless's.
            SecondDisk = @{
                Steps = @(
                    'Press **Return** to start, then choose your keyboard.'
                    'Make your account. Your password also unlocks the disk if Omarchy encrypts it. Name, email and hostname can be left empty.'
                    'Under **Select install disk**, press Down to reach **{DISK}**, then Return. **Don''t choose the disk Windows is on.**'
                    "Under **Select installation mode**, press Down to reach **Free space install (alongside existing data)**, then Return. **Don't choose Full disk install**, where the cursor starts: it erases that disk."
                    'It should say **Install Omarchy in the** and at least {GB} GB **of free space**. It uses the largest free space on the disk, which can be more than usbless set aside. Check it says **Confirm installing on** that disk, then choose **Yes, install**. To install without encryption, press **Ctrl+C** first.'
                    'When it has finished, choose **Reboot Now**.')
                Notes = @("Afterwards this PC starts Omarchy, from that disk. To get to Windows, use your PC's boot menu.")
            } })
        New-Entry 'ultramarine' 'Ultramarine' 'Fedora made easy' 'images.fyralabs.com' '#00078F' 'ultramarine' ((Get-DracutBoot 'boot/grub') + @{
            Kind = 'ultramarine'; Edition = 'gnome'; Manual = 'Manual disk configuration'; Steps = $AnacondaSteps
            FullDisk = (Get-FullDiskBoot 'dracut') + @{ IsoGB = 4; Steps = $AnacondaErase }
            SecondDisk = @{ EspLinuxMB = 0; Steps = $AnacondaSecondDisk; Notes = @("Afterwards this PC starts Ultramarine, from that disk, and its first start opens its own setup, beginning with **Language**.") } })
        New-UbuntuFlavor 'ubuntu-budgie' 'Ubuntu Budgie' 'Dock at the bottom' '#404552' @{ FullDisk = (Get-FullDiskBoot 'casper') + @{ IsoGB = 4; Steps = $UbuntuErase } }
        New-UbuntuFlavor 'xubuntu' 'Xubuntu' 'Lightweight' '#0044AA' @{ FullDisk = (Get-FullDiskBoot 'casper') + @{ IsoGB = 5; Steps = $UbuntuErase } }
        New-UbuntuFlavor 'lubuntu' 'Lubuntu' 'Lightest' '#0068C8' @{
            Alongside = $null; Manual = 'Manual partitioning'; ManualExtra = $EspExtra }
        New-UbuntuFlavor 'ubuntucinnamon' 'Ubuntu Cinnamon' 'Windows-like layout' '#DD682A' @{ FullDisk = (Get-FullDiskBoot 'casper') + @{ IsoGB = 6; Steps = $UbuntuErase } }
        New-UbuntuFlavor 'ubuntu-unity' 'Ubuntu Unity' 'Classic Ubuntu' '#5A06C3'
        New-MintEdition 'xfce' 'Linux Mint Xfce' 'Lighter Mint'
        New-MintEdition 'mate' 'Linux Mint MATE' 'Traditional'
        New-UbuntuFlavor 'edubuntu' 'Edubuntu' 'For students' '#A30B00' @{ FullDisk = (Get-FullDiskBoot 'casper') + @{ IsoGB = 8; Steps = $UbuntuErase } }
        New-UbuntuFlavor 'ubuntustudio' 'Ubuntu Studio' 'For creators' '#009BF9' @{ FullDisk = (Get-FullDiskBoot 'casper') + @{ IsoGB = 7; Steps = $UbuntuErase } }
    )
}

function Get-Distro([string]$Id, [string]$IsoPath) {
    if ($Id -eq 'custom') {
        return New-Entry 'custom' ([IO.Path]::GetFileNameWithoutExtension($IsoPath)) '' '' '#1D1D1F' '' ((Get-CasperBoot) + @{
            Alongside = 'Install ... alongside Windows'; Manual = 'Manual installation' })
    }
    Get-Catalog | Where-Object Id -eq $Id
}
