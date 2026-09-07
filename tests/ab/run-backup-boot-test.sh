#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${BACKUP_BOOT_CONFIG:-${SCRIPT_DIR}/config.env}"
ACTION="${1:-}"
BACKUP_IMAGE_ARG="${2:-}"

log_message() {
  local msg="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
  printf '%s\n' "${msg}"
  # Also write to result.log in the artifact directory (if it exists)
  if [ -n "${LOCAL_ARTIFACT_DIR:-}" ] && [ -d "${LOCAL_ARTIFACT_DIR}" ]; then
    printf '%s\n' "${msg}" >> "${LOCAL_ARTIFACT_DIR}/result.log"
  fi
}

usage() {
  echo "Usage: $0 {prepare|boot|sanity-check|all} [BACKUP_IMAGE_PATH]" >&2
  echo "" >&2
  echo "Actions:" >&2
  echo "  prepare       Run run-ab-test.sh prepare to set up kernel, initramfs, and SSH keys" >&2
  echo "  boot          Start QEMU guest with backup image and wait for SSH" >&2
  echo "  sanity-check  Run sanity checks on already-running guest (requires SSH)" >&2
  echo "  all           Boot guest, run sanity checks, and shutdown" >&2
  echo "" >&2
  echo "BACKUP_IMAGE_PATH: Path to the backup .img file to boot." >&2
  echo "                   Can also be set via BACKUP_IMAGE in config.env" >&2
  exit 2
}

[ -n "${ACTION}" ] || usage
[ -f "${CONFIG_FILE}" ] || { echo "Missing configuration: ${CONFIG_FILE}" >&2; exit 2; }

# Convert backup image argument to absolute path BEFORE changing directory
# This ensures relative paths from the tests/ab directory work correctly
if [ -n "${BACKUP_IMAGE_ARG}" ]; then
  BACKUP_IMAGE_ARG="$(cd "$(dirname "${BACKUP_IMAGE_ARG}")" && pwd)/$(basename "${BACKUP_IMAGE_ARG}")"
fi

# shellcheck source=/dev/null
cd "${PROJECT_DIR}"
source "${CONFIG_FILE}"
export LANG=C
export LANGUAGE=C
export LC_ALL=C

# Determine backup image path
BACKUP_IMAGE="${BACKUP_IMAGE_ARG:-${BACKUP_IMAGE:-}}"
[ -n "${BACKUP_IMAGE}" ] || { echo "Missing BACKUP_IMAGE (argument or config.env)" >&2; exit 2; }
[ -f "${BACKUP_IMAGE}" ] || { echo "Backup image not found: ${BACKUP_IMAGE}" >&2; exit 2; }

# Early check: verify the backup image is a bootable disk image (has partition table)
# Raw filesystem images (e.g., guest-backup.img from image-backup output) lack a partition
# table and boot partition, so they cannot boot in QEMU.
check_bootable_image() {
  local img="$1"
  local img_type
  img_type=$(file -b "$img" 2>/dev/null || echo "unknown")
  
  # Check if it's a raw filesystem without partition table
  if echo "$img_type" | grep -q "ext4 filesystem data" && ! echo "$img_type" | grep -q "partition"; then
    log_message "[FAIL] Backup image is a raw ext4 filesystem (root partition only), not a bootable disk image"
    log_message "[FAIL] This image lacks a partition table and boot partition, so it cannot boot in QEMU"
    log_message "[FAIL] Image type detected: $img_type"
    log_message "[FAIL] Solution: Use the qcow2 overlay image (guest-root.qcow2) from A/B test artifacts instead"
    log_message "[FAIL] Example: ./run-backup-boot-test.sh all artifacts/testresult*/local/guest-root.qcow2"
    exit 2
  fi
  
  # For qcow2 images, check the backing file (which contains the partition table)
  # The qcow2 container itself doesn't have a partition table - it's an overlay
  local check_img="$img"
  if echo "$img_type" | grep -q "QCOW"; then
    local backing_file
    backing_file=$(qemu-img info --output=json "$img" 2>/dev/null | jq -r '.["backing-filename"] // empty' 2>/dev/null || echo "")
    if [ -n "$backing_file" ] && [ "$backing_file" != "null" ] && [ -f "$backing_file" ]; then
      check_img="$backing_file"
      log_message "[INFO] qcow2 image detected, checking backing file for partition table: $backing_file"
    fi
  fi
  
  # Also check with fdisk for partition table (on the actual disk image)
  if ! fdisk -l "$check_img" 2>/dev/null | grep -q "Disklabel type:"; then
    log_message "[FAIL] Backup image does not appear to have a partition table"
    log_message "[FAIL] This image cannot boot in QEMU because it lacks a partition table and boot partition"
    log_message "[FAIL] Solution: Use the qcow2 overlay image (guest-root.qcow2) from A/B test artifacts instead"
    log_message "[FAIL] Example: ./run-backup-boot-test.sh all artifacts/testresult*/local/guest-root.qcow2"
    exit 2
  fi
}

# Run the check for boot, sanity-check, and all actions (not for prepare)
if [ "${ACTION}" != "prepare" ]; then
  check_bootable_image "${BACKUP_IMAGE}"
fi

# Required configuration variables
for required in KERNEL_IMAGE INITRAMFS_IMAGE SSH_PRIVATE_KEY SSH_PUBLIC_KEY GUEST_USER QEMU_MACHINE QEMU_MEMORY_MB QEMU_CPUS SSH_PORT SSH_WAIT_SECONDS ARTIFACT_DIR; do
  [ -n "${!required:-}" ] || { echo "Missing ${required} in ${CONFIG_FILE}" >&2; exit 2; }
done

for command in qemu-system-aarch64 qemu-img ssh scp ssh-keygen; do
  command -v "${command}" >/dev/null || { echo "Missing host command: ${command}" >&2; exit 1; }
done

SSH_TARGET="${GUEST_USER}@127.0.0.1"
SSH_ARGS=(-F /dev/null -p "${SSH_PORT}" -i "${SSH_PRIVATE_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=5)
SCP_ARGS=(-F /dev/null -P "${SSH_PORT}" -i "${SSH_PRIVATE_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=5)

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOCAL_ARTIFACT_DIR="${ARTIFACT_DIR}/backup-boot-test${RUN_ID}"
mkdir -p "${LOCAL_ARTIFACT_DIR}"

GUEST_PID=""
CURRENT_STAGE="initializing"

remote() {
  ssh "${SSH_ARGS[@]}" "${SSH_TARGET}" "$@"
}

copy_to_guest() {
  scp "${SCP_ARGS[@]}" "$@" "${SSH_TARGET}:"
}

copy_from_guest() {
  scp "${SCP_ARGS[@]}" "${SSH_TARGET}:$1" "$2"
}

stop_guest() {
  if [ -n "${GUEST_PID}" ]; then
    CURRENT_STAGE="stopping QEMU guest"
    remote "sudo -n poweroff" >/dev/null 2>&1 || true
    wait "${GUEST_PID}" || true
    GUEST_PID=""
  fi
}

finish_run() {
  local exit_code=$?
  trap - EXIT
  stop_guest

  if [ "${exit_code}" -eq 0 ]; then
    case "${ACTION}" in
      all) log_message "[PASS] Backup boot test completed successfully" ;;
      boot) log_message "[PASS] Guest booted and SSH ready" ;;
      sanity-check) log_message "[PASS] Sanity checks completed" ;;
      *) log_message "[PASS] Test command completed successfully" ;;
    esac
    log_message "[INFO] Success Exitcode: ${exit_code}"
  else
    log_message "[FAIL] ${ACTION} aborted (exit ${exit_code})" >&2
    log_message "[FAIL] stage: ${CURRENT_STAGE}" >&2
    log_message "[INFO] Fail Exitcode: ${exit_code}"
  fi
  log_message "[INFO] Backup boot test artifacts: ${LOCAL_ARTIFACT_DIR}"
  exit "${exit_code}"
}
trap finish_run EXIT

wait_for_ssh() {
  local elapsed=0
  log_message "[INFO] Waiting for SSH on port ${SSH_PORT}..."
  until remote "true" >/dev/null 2>&1; do
    elapsed=$((elapsed + 2))
    [ "${elapsed}" -le "${SSH_WAIT_SECONDS}" ] || {
      echo "Guest SSH did not become ready within ${SSH_WAIT_SECONDS} seconds" >&2
      return 1
    }
    sleep 2
  done
  log_message "[INFO] SSH ready after ${elapsed} seconds"
}

start_guest() {
  CURRENT_STAGE="starting QEMU guest"
  log_message "[INFO] Starting QEMU guest with backup image: ${BACKUP_IMAGE}"

  # Determine image format and backing file using qemu-img info JSON with jq
  local img_info
  img_info=$(qemu-img info --output=json "${BACKUP_IMAGE}" 2>/dev/null || echo "{}")
  local img_format
  img_format=$(echo "${img_info}" | jq -r '.format // "raw"')
  local backing_file
  backing_file=$(echo "${img_info}" | jq -r '.["backing-filename"] // empty')
  
  local root_overlay="${LOCAL_ARTIFACT_DIR}/guest-root.qcow2"
  local console_log="${LOCAL_ARTIFACT_DIR}/qemu-console.log"

  if [ "${img_format}" = "qcow2" ]; then
    if [ -n "${backing_file}" ] && [ "${backing_file}" != "null" ]; then
      # qcow2 with backing file - use the original file directly
      # The backing file path in the qcow2 is absolute and should still be valid
      log_message "[INFO] Detected qcow2 image with backing file, using original file directly"
      root_overlay="${BACKUP_IMAGE}"
    else
      # qcow2 without backing file - create overlay with qcow2 backing format
      log_message "[INFO] Detected qcow2 image without backing file, creating overlay"
      qemu-img create -f qcow2 -F qcow2 -b "${BACKUP_IMAGE}" "${root_overlay}" >/dev/null
    fi
  else
    # For raw images, create overlay with raw backing format
    log_message "[INFO] Detected raw image, creating overlay with raw backing format"
    qemu-img create -f qcow2 -F raw -b "${BACKUP_IMAGE}" "${root_overlay}" >/dev/null
  fi

  # Start QEMU in background
  qemu-system-aarch64 \
    -M "${QEMU_MACHINE}" -cpu max,pauth=off -m "${QEMU_MEMORY_MB}" -smp "${QEMU_CPUS}" \
    -kernel "${KERNEL_IMAGE}" -initrd "${INITRAMFS_IMAGE}" -append 'root=/dev/vda2 rw rootwait console=ttyAMA0' \
    -drive "if=none,file=${root_overlay},format=qcow2,id=rootdisk" -device virtio-blk-pci,drive=rootdisk \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" -device virtio-net-pci,netdev=net0 \
    -nographic "${QEMU_EXTRA_ARGS[@]}" 2>&1 | tee "${console_log}" &

  GUEST_PID=$!
  log_message "[INFO] QEMU guest started with PID ${GUEST_PID}"
}

run_sanity_checks() {
  CURRENT_STAGE="running sanity checks"
  log_message "[INFO] Running sanity checks..."

  # Helper function to run remote command with timeout
  remote_timeout() {
    # Run SSH command directly with timeout
    timeout 30 ssh "${SSH_ARGS[@]}" "${SSH_TARGET}" "$@" 2>&1 || true
  }

  # 1. Basic connectivity and system info
  log_message "[CHECK] Basic connectivity and system info"
  remote_timeout "hostname && uptime && whoami" | tee -a "${LOCAL_ARTIFACT_DIR}/sanity.log"

  # 2. Check systemd status (without --wait to avoid long hangs)
  log_message "[CHECK] Systemd status"
  remote_timeout "systemctl is-system-running" | tee -a "${LOCAL_ARTIFACT_DIR}/sanity.log"

  # 3. Check disk space
  log_message "[CHECK] Disk space"
  remote_timeout "df -h /" | tee -a "${LOCAL_ARTIFACT_DIR}/sanity.log"

  # 4. Check backup-related files if they exist
  log_message "[CHECK] Backup artifacts"
  remote_timeout "ls -la /mnt/backup/ 2>/dev/null || echo 'No /mnt/backup directory'" | tee -a "${LOCAL_ARTIFACT_DIR}/sanity.log"
  remote_timeout "ls -la /var/tmp/image-backup*/ 2>/dev/null || echo 'No image-backup workdir'" | tee -a "${LOCAL_ARTIFACT_DIR}/sanity.log"

  # 5. Check SSH service
  log_message "[CHECK] SSH service status"
  remote_timeout "systemctl status ssh --no-pager" | tee -a "${LOCAL_ARTIFACT_DIR}/sanity.log"

  # 6. Check kernel and initramfs
  log_message "[CHECK] Kernel version"
  remote_timeout "uname -a" | tee -a "${LOCAL_ARTIFACT_DIR}/sanity.log"

  # 7. Check for backup manifest if present
  log_message "[CHECK] Backup manifest"
  remote_timeout "cat /mnt/backup/backup.manifest 2>/dev/null | head -20 || echo 'No backup manifest found'" | tee -a "${LOCAL_ARTIFACT_DIR}/sanity.log"

  # 8. Basic command availability
  log_message "[CHECK] Essential commands"
  remote_timeout "which rsync sudo systemctl journalctl" | tee -a "${LOCAL_ARTIFACT_DIR}/sanity.log"

  log_message "[PASS] All sanity checks completed"
}

# Main execution
case "${ACTION}" in
  prepare)
    log_message "[INFO] Running run-ab-test.sh prepare..."
    exec bash "${SCRIPT_DIR}/run-ab-test.sh" prepare
    ;;
  boot)
    start_guest
    wait_for_ssh
    log_message "[INFO] Guest is ready. SSH: ssh -p ${SSH_PORT} -i ${SSH_PRIVATE_KEY} ${GUEST_USER}@127.0.0.1"
    log_message "[INFO] Console log: ${LOCAL_ARTIFACT_DIR}/qemu-console.log"
    log_message "[INFO] Press Ctrl+C to stop the guest"
    wait "${GUEST_PID}"
    ;;
  sanity-check)
    wait_for_ssh
    run_sanity_checks
    ;;
  all)
    start_guest
    wait_for_ssh
    run_sanity_checks
    stop_guest
    ;;
  *)
    usage
    ;;
esac