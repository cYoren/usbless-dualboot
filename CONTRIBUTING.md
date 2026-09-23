# Contributing

Thanks for helping make dual-boot setup safe and USB-free. This project touches partition
tables, encryption headers, and boot chains, so the bar is **correct and safe over clever**.

## Ways to contribute

- Pick up a [`good first issue`](https://github.com/cYoren/usbless-dualboot/labels/good%20first%20issue).
- Add a [case study](docs/case-studies/TEMPLATE.md) from a real machine (great first PR).
- Broaden `add-linux` distro support (see issue #2).
- Improve docs, or file a clear bug with your `lsblk` and bootloader details.

Agents are welcome as contributors. If you are an agent, read `AGENTS.md` and `SKILL.md` first;
the same rules below apply.

## Development setup

Requirements: Linux, UEFI/GPT, `bash`, `git`, `jq`. For the full test surface: `shellcheck`.

```bash
git clone https://github.com/cYoren/usbless-dualboot
cd usbless-dualboot
make lint          # bash -n every script
make shellcheck    # advisory (if installed)
make test          # smoke test, no root
make probe         # read-only, on your own machine
```

Mutating phases (`shrink`, `stage`, `boot`, `windows`, `secureboot`) need root. Test them only
on a machine or **loopback image** you can lose. Never run them against your daily driver to
"try it".

## Safety rules for boot/partition code

These are non-negotiable in review:

1. **Resolve devices, never hardcode.** Read from `probe`/`common.sh`; refuse if the disk
   identity (size, partition start/size, UUIDs) differs from the plan.
2. **Back up first.** GPT (primary + secondary) and the LUKS header before any change.
3. **Shrink order is filesystem -> LUKS -> partition.** Growing reverses it. Never shrink a
   partition below its filesystem.
4. **Fail closed.** Abort on any inconsistency or health-check error; write a `*-failed` marker.
5. **Idempotent phases.** Re-running must resume, not repeat. Write a completion marker.
6. **Power.** Refuse destructive operations on battery; require AC.
7. **Secure Boot.** Keep Microsoft's keys so Windows still boots; never write `dbx`. Warn about
   BitLocker recovery keys before changing keys or state.
8. **Recovery path.** Every destructive feature must document how to undo it (usually: disable
   Secure Boot in firmware, or restore the GPT/LUKS backup).

## Style

- Bash, `set -Eeuo pipefail`, `shellcheck`-clean where practical.
- Source `lib/common.sh` for helpers; keep scripts small and single-purpose.
- Support `--help` and `--dry-run` on mutating commands; prefer `--json` for new discovery output.
- Portable package installs go through `pkg_install` (pacman/apt/dnf/zypper).
- No comments that restate the code; comment the *why*, especially around safety.

## Commits and pull requests

- Small, focused commits with a clear subject line in the imperative mood.
- Describe **what changed and why**, plus how you tested it (host, or loopback image).
- Update docs (`README`, `llms.txt`, `SKILL.md`, `docs/`) when behavior changes.
- If you change a phase, add or update a case study or a test.
- PRs run CI: syntax lint, advisory ShellCheck, and the smoke test. Keep it green.

## Adding a case study

Copy `docs/case-studies/TEMPLATE.md`, fill it in, and link it from
`docs/case-studies/README.md`. Include the starting and ending `lsblk`, the exact commands, and
the quirks you hit.

## License

By contributing you agree your work is licensed under the [MIT License](LICENSE).
