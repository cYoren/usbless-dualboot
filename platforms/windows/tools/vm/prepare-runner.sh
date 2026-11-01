#!/bin/sh
# Gets a GitHub Actions Ubuntu runner ready to run the VM: the packages, /dev/kvm, and room on /mnt.
set -e
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools genisoimage >/dev/null
# Ubuntu's profile only lets swtpm keep its state in a few places.
sudo apparmor_parser -R /etc/apparmor.d/usr.bin.swtpm 2>/dev/null || true
sudo chmod 666 /dev/kvm
sudo mkdir -p /mnt/hopvm/files /mnt/hopvm/out
sudo chown -R "$(id -u):$(id -g)" /mnt/hopvm
sudo chmod 755 /mnt
cp "$(dirname "$0")/agent.ps1" "$(dirname "$0")/live-report.sh" /mnt/hopvm/files/
ls -la /dev/kvm
df -h / /mnt
nproc
free -g
qemu-system-x86_64 --version | head -1
ls /usr/share/OVMF/
