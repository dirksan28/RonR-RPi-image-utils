#!/bin/bash
set -euo pipefail

IMAGE_FILE="${1:-}"
OUTPUT_DIR="${2:-}"
[ -n "${IMAGE_FILE}" ] && [ -n "${OUTPUT_DIR}" ] || { echo "Usage: $0 IMAGE_FILE OUTPUT_DIR" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "Must run as root" >&2; exit 1; }

ROOT_MOUNT="$(mktemp -d)"
BOOT_MOUNT="$(mktemp -d)"
LOOP_DEVICE=""
cleanup() {
  mountpoint -q "${BOOT_MOUNT}" && umount "${BOOT_MOUNT}" || true
  mountpoint -q "${ROOT_MOUNT}" && umount "${ROOT_MOUNT}" || true
  [ -n "${LOOP_DEVICE}" ] && losetup -d "${LOOP_DEVICE}" || true
  rmdir "${BOOT_MOUNT}" "${ROOT_MOUNT}" || true
}
trap cleanup EXIT

LOOP_DEVICE="$(losetup --read-only -f --show -P "${IMAGE_FILE}")"
mount -o ro "${LOOP_DEVICE}p1" "${BOOT_MOUNT}"
mount -o ro "${LOOP_DEVICE}p2" "${ROOT_MOUNT}"

manifest() {
  local mount_dir="$1"
  local output_file="$2"
  local entry relative_path entry_type metadata checksum link_target
  : > "${output_file}"
  while IFS= read -r -d '' entry; do
    relative_path="${entry#${mount_dir}/}"
    [ "${entry}" = "${mount_dir}" ] && relative_path="."
    metadata="$(stat -c '%F\t%a\t%u\t%g\t%s' "${entry}")"
    entry_type="$(stat -c '%F' "${entry}")"
    checksum="-"
    link_target="-"
    if [ "${entry_type}" = "regular file" ]; then
      checksum="$(sha256sum "${entry}" | awk '{print $1}')"
    elif [ "${entry_type}" = "symbolic link" ]; then
      link_target="$(readlink "${entry}")"
    fi
    printf '%s\t%s\t%s\t%s\n' "${relative_path}" "${metadata}" "${link_target}" "${checksum}"
  done < <(find "${mount_dir}" -xdev -print0) | LC_ALL=C sort > "${output_file}"
}

mkdir -p "${OUTPUT_DIR}"
manifest "${ROOT_MOUNT}" "${OUTPUT_DIR}/root.manifest"
manifest "${BOOT_MOUNT}" "${OUTPUT_DIR}/boot.manifest"
sfdisk --dump "${IMAGE_FILE}" | sed -E '/^label-id:/d; s/, uuid=[^,]+//' > "${OUTPUT_DIR}/partition-table.normalized.txt"
