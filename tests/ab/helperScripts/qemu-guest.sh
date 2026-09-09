#!/bin/bash
# Launch one isolated guest with a copy-on-write root and a fresh backup disk.
#
# Synopsis:
#   Usage: qemu-guest.sh start OUTPUT_DIR BASE_IMAGE KERNEL INITRAMFS DISK_GB SSH_PORT MACHINE MEMORY_MB CPUS [QEMU_ARGS...]
#   Expects a prepared base image, kernel, initramfs, guest sizing/network values,
#   and optional arguments to forward to qemu-system-aarch64.
#   Creates guest-root.qcow2, guest-backup.img, and qemu-console.log in OUTPUT_DIR,
#   then runs QEMU in the foreground and returns QEMU's exit status.
set -euo pipefail

[ "${1:-}" = "start" ] || { echo "Usage: $0 start OUTPUT_DIR BASE_IMAGE KERNEL INITRAMFS DISK_GB SSH_PORT MACHINE MEMORY_MB CPUS [QEMU_ARGS...]" >&2; exit 2; }
OUTPUT_DIR="$2"
BASE_IMAGE="$3"
KERNEL_IMAGE="$4"
INITRAMFS_IMAGE="$5"
DISK_GB="$6"
SSH_PORT="$7"
MACHINE="$8"
MEMORY_MB="$9"
CPUS="${10}"
shift 10

# The first ten arguments configure the guest; any remaining arguments are forwarded to QEMU.
ROOT_OVERLAY="${OUTPUT_DIR}/guest-root.qcow2"
BACKUP_DISK="${OUTPUT_DIR}/guest-backup.img"
CONSOLE_LOG="${OUTPUT_DIR}/qemu-console.log"
qemu-img create -f qcow2 -F raw -b "${BASE_IMAGE}" "${ROOT_OVERLAY}" >/dev/null
qemu-img create -f raw "${BACKUP_DISK}" "${DISK_GB}G" >/dev/null

# Process substitution keeps QEMU as the tracked child while tee records the raw
# console output. Strip CSI controls only from the live display so cursor queries
# cannot leave terminal responses in the shell input after QEMU exits.
exec qemu-system-aarch64 \
  -M "${MACHINE}" -cpu max,pauth=off -m "${MEMORY_MB}" -smp "${CPUS}" \
  -kernel "${KERNEL_IMAGE}" -initrd "${INITRAMFS_IMAGE}" -append 'root=/dev/vda2 rw rootwait console=ttyAMA0' \
  -drive "if=none,file=${ROOT_OVERLAY},format=qcow2,id=rootdisk" -device virtio-blk-pci,drive=rootdisk \
  -drive "if=none,file=${BACKUP_DISK},format=raw,id=backupdisk" -device virtio-blk-pci,drive=backupdisk \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0 \
  -nographic "$@" > >(tee "${CONSOLE_LOG}" | sed -u -E $'s/\x1b\\[[^[:alpha:]]*[[:alpha:]]//g') 2>&1