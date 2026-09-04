#!/bin/bash
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

ROOT_OVERLAY="${OUTPUT_DIR}/guest-root.qcow2"
BACKUP_DISK="${OUTPUT_DIR}/guest-backup.img"
CONSOLE_LOG="${OUTPUT_DIR}/qemu-console.log"
qemu-img create -f qcow2 -F raw -b "${BASE_IMAGE}" "${ROOT_OVERLAY}" >/dev/null
qemu-img create -f raw "${BACKUP_DISK}" "${DISK_GB}G" >/dev/null

exec qemu-system-aarch64 \
  -M "${MACHINE}" -cpu max,pauth=off -m "${MEMORY_MB}" -smp "${CPUS}" \
  -kernel "${KERNEL_IMAGE}" -initrd "${INITRAMFS_IMAGE}" -append 'root=/dev/vda2 rw rootwait console=ttyAMA0' \
  -drive "if=none,file=${ROOT_OVERLAY},format=qcow2,id=rootdisk" -device virtio-blk-pci,drive=rootdisk \
  -drive "if=none,file=${BACKUP_DISK},format=raw,id=backupdisk" -device virtio-blk-pci,drive=backupdisk \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0 \
  -nographic "$@" 2>&1 | tee "${CONSOLE_LOG}"