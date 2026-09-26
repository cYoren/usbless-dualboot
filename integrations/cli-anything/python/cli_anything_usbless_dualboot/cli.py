"""Agent-native front end for the usbless-dualboot bash CLI.

Design rules, enforced by the tests in this directory:

  * One-shot commands and `--json` output, mirroring the underlying CLI.
  * Delegation only: arguments are passed through to the real CLI unchanged.
  * No phase is reimplemented here, so this adapter can never diverge from the
    bash implementation's safety guards.
  * Destructive commands require an explicit confirmation flag and print their
    danger class before delegating.
  * `manifest` and `manifest validate` never call the underlying CLI at all, so
    the adapter's description of the CLI is inspectable with no side effects.

Usage:
    cli-anything-usbless-dualboot manifest --json
    cli-anything-usbless-dualboot probe --json
    cli-anything-usbless-dualboot plan --json
    cli-anything-usbless-dualboot run shrink --dry-run

Exit codes: 0 on success, 1 on failure, 2 on usage error, 3 when the underlying
CLI executable cannot be found.
"""

import argparse  # noqa: F401 - kept for API stability of this module
import os
import shutil
import subprocess
import sys
from typing import Any, Dict, List, Optional

from . import __version__
from .manifest import destructive_commands, load_manifest, root_required_commands

EXIT_OK = 0
EXIT_FAILURE = 1
EXIT_USAGE = 2
EXIT_NO_CLI = 3

DEFAULT_CLI = "usbless-dualboot"


def find_cli() -> Optional[str]:
    """Locate the wrapped CLI. Never guesses: returns None when absent."""
    override = os.environ.get("USBDB_CLI")
    if override:
        return override if os.path.isfile(override) and os.access(override, os.X_OK) else None
    return shutil.which(DEFAULT_CLI)


def danger_label(entry: Dict[str, Any]) -> str:
    return str(entry.get("danger", "unknown"))


def is_root() -> bool:
    return hasattr(os, "geteuid") and os.geteuid() == 0


def print_manifest(as_json: bool) -> int:
    manifest = load_manifest()
    if as_json:
        import json

        json.dump(manifest, sys.stdout, indent=2, sort_keys=False)
        sys.stdout.write("\n")
        return EXIT_OK

    print(f"{manifest['adapter']['name']} {manifest['adapter']['version']}")
    print(f"wraps: {manifest['adapter']['wraps']['command']} ({manifest['adapter']['wraps']['kind']})")
    print(f"distribution: {manifest['target_software']['homepage']}\n")
    print(f"{'command':<11} {'root':<5} {'json':<5} {'dry-run':<8} {'danger':<12} destructive")
    for entry in manifest.get("commands", []):
        print(
            f"{entry['name']:<11} "
            f"{'yes' if entry.get('requires_root') else 'no':<5} "
            f"{'yes' if entry.get('supports_json') else 'no':<5} "
            f"{'yes' if entry.get('supports_dry_run') else 'no':<8} "
            f"{danger_label(entry):<12} "
            f"{'YES' if entry.get('destructive') else 'no'}"
        )
    print("\nDelegating commands: probe, plan, shrink, stage, boot, windows, secureboot")
    print("Inspect-only commands: manifest, version")
    return EXIT_OK


def run_pass_through(name: str, extra: List[str], force: bool, dry_run: bool) -> int:
    """Delegate straight to the real CLI. No argument rewriting beyond flags."""
    manifest = load_manifest()
    entry: Optional[Dict[str, Any]] = next(
        (c for c in manifest.get("commands", []) if c.get("name") == name), None
    )
    if entry is None:
        print(f"error: unknown command '{name}'", file=sys.stderr)
        return EXIT_USAGE

    if entry.get("destructive") and not force:
        print(
            f"refusing to run destructive command '{name}' without --i-understand or --yes.\n"
            f"  '{name}' is DESTRUCTIVE ({danger_label(entry)}) and cannot be undone by the tool.\n"
            f"  suggested first step: usbless-dualboot {name} --dry-run",
            file=sys.stderr,
        )
        return EXIT_USAGE

    if entry.get("destructive"):
        print(
            f"warning: '{name}' is DESTRUCTIVE ({danger_label(entry)}). "
            + str(entry.get("why_dangerous", "")),
            file=sys.stderr,
        )

    cli = find_cli()
    if cli is None:
        print(
            "error: usbless-dualboot not found on PATH. Set USBDB_CLI to its path.\n"
            "       This adapter delegates to the CLI; it does not implement any phase.",
            file=sys.stderr,
        )
        return EXIT_NO_CLI

    if entry.get("requires_root") and not is_root():
        print(f"warning: '{name}' needs root; you are not root.", file=sys.stderr)

    # `--i-understand` is an adapter-only acknowledgement: the real CLI has no such
    # flag and would abort with "unknown option". It must never be forwarded.
    forwarded = [flag for flag in extra if flag != "--i-understand"]

    argv = [cli, name] + forwarded
    if dry_run and "--dry-run" not in forwarded and entry.get("supports_dry_run"):
        argv.append("--dry-run")

    try:
        return subprocess.call(argv)
    except FileNotFoundError:
        print(f"error: could not execute {cli}", file=sys.stderr)
        return EXIT_NO_CLI
    except KeyboardInterrupt:
        return EXIT_FAILURE


def usage_text() -> str:
    return (
        "usage: cli-anything-usbless-dualboot <command> [args...]\n\n"
        "Commands:\n"
        "  manifest [--json]      print the command manifest\n"
        "  manifest --validate    validate the manifest and registry entry\n"
        "  version                print the underlying CLI version\n"
        "  probe [--json]         detect the current layout (read-only)\n"
        "  plan [options]         print a reviewable plan (read-only)\n"
        "  shrink [options]       DESTRUCTIVE: shrink the Linux partition\n"
        "  stage [options]        DESTRUCTIVE: create the installer partition\n"
        "  boot [options]         firmware: register/restore a UEFI boot entry\n"
        "  windows [options]      boot-config: add/remove the Windows entry\n"
        "  secureboot [options]   firmware: sign the boot chain\n\n"
        "All arguments after the command are passed straight through to the real\n"
        "usbless-dualboot CLI. Destructive commands additionally require\n"
        "--i-understand (or --yes) before they will be delegated.\n\n"
        "Exit codes: 0 ok, 1 failure, 2 usage error, 3 CLI not found.\n"
    )


def main(argv: Optional[List[str]] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)

    if not args or args[0] in ("-h", "--help", "help"):
        print(usage_text(), end="")
        return EXIT_OK
    if args[0] in ("-V", "--version"):
        print(f"cli-anything-usbless-dualboot {__version__}")
        return EXIT_OK

    command, rest = args[0], args[1:]

    if command == "manifest":
        if "--validate" in rest:
            from .validate import main as validate_main

            return validate_main(rest)
        return print_manifest("--json" in rest)

    if command == "version":
        cli = find_cli()
        if cli is None:
            print(f"cli-anything-usbless-dualboot {__version__} (underlying CLI not found)")
            return EXIT_OK
        return subprocess.call([cli, "version"])

    known = {c["name"] for c in load_manifest()["commands"]}
    if command in known:
        # Args are forwarded verbatim: this adapter must not reinterpret the CLI's
        # own option grammar, or it would silently change what the user asked for.
        return run_pass_through(
            command,
            rest,
            force=("--i-understand" in rest),
            dry_run=("--dry-run" in rest),
        )

    print(f"error: unknown command '{command}'\n", file=sys.stderr)
    print(usage_text(), end="", file=sys.stderr)
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())