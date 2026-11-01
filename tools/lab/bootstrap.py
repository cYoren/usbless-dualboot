#!/usr/bin/env python3
"""Install signed Arch VM tools into a private prefix, without sudo or host changes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def download(url: str, path: Path):
    if not url.startswith("https://"):
        raise ValueError("Only HTTPS tool sources are allowed")
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(path.name + ".part")
    run(["curl", "--silent", "--show-error", "--fail", "--location", "--retry", "3", "--continue-at", "-", "--output", str(partial), url])
    partial.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path.home() / ".cache/usbless-dualboot/lab-tools")
    parser.add_argument("--with-tpm", action="store_true")
    parser.add_argument("--powershell", action="store_true")
    parser.add_argument("--extra-package", action="append", default=[])
    args = parser.parse_args()
    root = args.directory.resolve()
    cache, prefix = root / "packages", root / "root"
    cache.mkdir(parents=True, exist_ok=True)
    prefix.mkdir(parents=True, exist_ok=True)
    packages = ["qemu-system-x86", "qemu-img", "edk2-ovmf", "mtools"]
    for name in args.extra_package:
        if not re.fullmatch(r"[a-z0-9][a-z0-9+-]*", name):
            raise ValueError("Invalid additional tool package name")
        packages.append(name)
    if args.with_tpm:
        packages.append("swtpm")
    keyring = Path("/usr/share/pacman/keyrings/archlinux.gpg")
    if not keyring.is_file():
        raise RuntimeError("An installed Arch Linux public package keyring is required")
    if keyring.read_bytes().startswith(b"-----BEGIN PGP"):
        binary_keyring = root / "archlinux-keyring.gpg"
        run(["gpg", "--batch", "--yes", "--no-options", "--dearmor", "--output", str(binary_keyring), str(keyring)])
        keyring = binary_keyring
    output = run(["pacman", "-Sp", "--print-format", "%n %l", *packages], capture_output=True).stdout
    manifest = {"format": 1, "source": "signed Arch packages resolved by local pacman metadata", "packages": []}
    previous_manifest = root / "manifest.json"
    if previous_manifest.exists():
        previous = json.loads(previous_manifest.read_text())
        if "powershell" in previous:
            manifest["powershell"] = previous["powershell"]
    for line in output.splitlines():
        if not line.strip():
            continue
        name, url = line.split(" ", 1)
        filename = url.rsplit("/", 1)[1]
        archive = cache / filename
        signature = cache / (filename + ".sig")
        if not signature.exists():
            download(url + ".sig", signature)
        if not archive.exists():
            download(url, archive)
        # Verification precedes extraction and execution. A failed cached archive is
        # retained for diagnosis instead of silently throwing away a download.
        run(["gpgv", "--keyring", str(keyring), str(signature), str(archive)], stdout=subprocess.DEVNULL)
        digest = hashlib.file_digest(archive.open("rb"), "sha256").hexdigest()
        stamp = prefix / (".extracted-" + digest)
        if not stamp.exists():
            run(["bsdtar", "-xf", str(archive), "-C", str(prefix)])
            stamp.touch()
        manifest["packages"].append({"name": name, "url": url, "sha256": digest})
        print(f"Verified {name}", flush=True)
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    environment = dict(os.environ, LD_LIBRARY_PATH=str(prefix / "usr/lib"), QEMU_MODULE_DIR=str(prefix / "usr/lib/qemu"))
    for program in ["qemu-system-x86_64", "qemu-img"]:
        run([str(prefix / "usr/bin" / program), "--version"], env=environment)
    firmware = list((prefix / "usr/share").rglob("OVMF_CODE*.fd"))
    if not firmware:
        raise RuntimeError("No UEFI firmware was found in the verified packages")
    print("Tool prefix:", prefix)
    print("UEFI firmware:", firmware[0])
    if args.powershell:
        version = "7.6.9"
        name = f"powershell-{version}-linux-x64.tar.gz"
        source = f"https://github.com/PowerShell/PowerShell/releases/download/v{version}/"
        hashes = cache / f"powershell-{version}-hashes.sha256"
        if not hashes.exists():
            download(source + "hashes.sha256", hashes)
        expected = None
        raw_hashes = hashes.read_bytes()
        hash_text = raw_hashes.decode("utf-16" if raw_hashes.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig")
        for line in hash_text.splitlines():
            if line.strip().endswith(name):
                match = re.match(r"^([0-9A-Fa-f]{64})\s", line)
                if match:
                    expected = match.group(1).lower()
        if not expected:
            raise RuntimeError("PowerShell archive is absent from the publisher checksum file")
        archive = cache / name
        if not archive.exists():
            download(source + name, archive)
        with archive.open("rb") as handle:
            actual = hashlib.file_digest(handle, "sha256").hexdigest()
        if actual != expected:
            raise RuntimeError("PowerShell checksum mismatch; cached file retained for inspection")
        destination = root / "powershell" / version
        if not (destination / "pwsh").exists():
            destination.mkdir(parents=True, exist_ok=True)
            run(["bsdtar", "-xf", str(archive), "-C", str(destination)])
            (destination / "pwsh").chmod(0o755)
        run([str(destination / "pwsh"), "-NoLogo", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"])
        manifest["powershell"] = {"version": version, "url": source + name, "sha256": actual}
        (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
