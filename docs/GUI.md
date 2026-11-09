# Graphical app

Status: current

The native Qt Quick app wraps the same Bash engine. It runs on Linux and has five screens:
PC checks, ISO selection, exact plan review, installer preparation, and finishing/recovery.
This interface runs on Linux. The separate Windows-native app has its own validation matrix.

## Run from the checkout

```bash
./bin/build-ui
./build/usbless
```

For a safe preview with sample storage and disk operations disabled:

```bash
./build/usbless --demo
```

Build requirements: a C++17 compiler, `qmake6`, `make`, Qt 6 base/declarative/Quick Controls
and D-Bus. Runtime: the full Bash engine, jq, util-linux, a graphical session and a supported
terminal (kitty, ghostty, foot, alacritty or xterm). The native file picker uses the desktop
portal. If unavailable, paste the ISO path into the field.

On Arch/Omarchy, `./bin/install-ui` builds and installs the package through makepkg. This
uses the normal visible sudo prompt. The launcher entry is **USBless Dualboot**; both
`usbless` (GUI) and `usbless-dualboot` (CLI) are installed.

## Privilege and state

PC detection and ISO verification run without sudo. Planning and privileged actions open
a visible terminal. Arguments are passed as a list, never interpolated into `bash -c`.
The app does not receive or store passwords and does not automatically reboot.

The GUI keeps one state directory under the user's local application data. Its plan stays
root-owned and private. The terminal helper exports only a status summary for the app,
plus a private log of engine output; LUKS headers and signing keys are never exported.
The original plan log is preserved separately from later action logs.

Actions are restricted by saved phase state. Disk and boot changes require an explicit
review dialog; the engine independently enforces its safety checks. Interrupted phases
stop the workflow. Returning to Linux does not automatically mark an OS installation as
successful. The user must complete the OS installer and firmware steps.

The GUI's state directory is separate from a pre-existing CLI plan. Do not start a second
plan in the GUI while a CLI installation is in progress. Use one workflow for each disk.

## Language, theme and keyboard

English and Portuguese are bundled. Missing translations fall back to English. Language
selection follows Omarchy's language file and system locale; the app reads desktop settings
without changing them. The desktop accent and corner rounding follow Omarchy live.
Other desktops use the documented fallback accent and square corners.

| Shortcut | Action |
|---|---|
| Space | Continue from the first screen |
| Alt + Left | Previous screen |
| Ctrl + R | Refresh read-only detection |
| ? | Shortcut help |
| Q | Quit when not entering an ISO path or running an action |

## Visual direction and checks

Slate `#19262f` is the workspace, deep blue `#14212a` the step rail, `#22333f` the storage
panel, `#eff5f5` the primary text, `#a8bdc7` supporting text and `#a3d8bf` the status color.
The main action uses the live desktop accent. Adwaita Sans keeps dense system information
legible with a simple 40/23/15/12 type scale. The raccoon is the main decorative element.

The layout uses a persistent step rail on wide windows and a compact step bar below 960px.
Content scrolls independently of the bottom action row. Buttons have visible focus states.
Native screenshots are checked at 1440x900, 820x1180 and 390x844, including Portuguese.
An early pass had cramped small step targets and lost the mascot at narrow widths; larger
targets and a small header mascot address those problems.

`bin/test-ui` compiles Qt Test cases and drives the actual QML offscreen. Tests cover preview
safety, shell-free argument passing, saved/interrupted state, theme/translation changes and
primary-button navigation. Run `make test` for the engine's non-destructive regressions too.
Disposable-VM installation testing remains necessary before claiming unattended installation.
