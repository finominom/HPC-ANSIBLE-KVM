#!/usr/bin/env bash
# Run on the KVM host as root. Creates the /data disk image and attaches it to
# the master VM as a virtio disk. Safe to run twice: it keeps an existing image
# and does nothing if the disk is already attached.
#   usage: attach-data-disk.sh [vm] [size] [image-dir] [target]
set -euo pipefail
VM=${1:-alma98}
SIZE=${2:-80G}
DIR=${3:-/home/libvirt/images}
TARGET=${4:-vdb}
IMG="$DIR/$VM-data.qcow2"
export LIBVIRT_DEFAULT_URI=qemu:///system

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
virsh dominfo "$VM" >/dev/null

if virsh domblklist "$VM" --details | awk '{print $3}' | grep -qx "$TARGET"; then
  echo "$VM already has a disk named $TARGET; nothing to do."
  exit 0
fi

[ -e "$IMG" ] || qemu-img create -f qcow2 "$IMG" "$SIZE"
restorecon -v "$IMG" 2>/dev/null || true
virsh attach-disk "$VM" "$IMG" "$TARGET" \
  --driver qemu --subdriver qcow2 --targetbus virtio --persistent
echo "Attached $IMG as $TARGET. In the VM, check: lsblk"
