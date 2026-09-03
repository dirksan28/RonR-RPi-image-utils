#!/bin/bash
set -euo pipefail

ACTION="${1:-}"
CANDIDATE="${2:-}"
IMAGE_BACKUP="${3:-}"
BACKUP_DIR="${4:-}"
INITIAL_SIZE_MB="${5:-}"
ARTIFACT_DIR="${6:-}"
REVISION="${7:-}"
FIXTURE_DIR="/opt/image-backup-ab-fixtures"
IMAGE_FILE="${BACKUP_DIR}/${CANDIDATE}.img"

require_root() {
  [ "$(id -u)" -eq 0 ] || { echo "Must run as root" >&2; exit 1; }
}

setup_backup() {
  local root_source root_disk backup_disk
  require_root
  [ -b "${BACKUP_DEVICE}" ] || { echo "Backup device not found: ${BACKUP_DEVICE}" >&2; exit 1; }
  root_source="$(findmnt -nvo SOURCE /)"
  root_disk="$(lsblk -no PKNAME "${root_source}" 2>/dev/null || true)"
  backup_disk="$(basename "${BACKUP_DEVICE}")"
  [ -n "${root_disk}" ] && [ "${root_disk}" != "${backup_disk}" ] || {
    echo "Refusing to format a root filesystem device: ${BACKUP_DEVICE}" >&2
    exit 1
  }
  mkdir -p "${BACKUP_DIR}"
  if mountpoint -q "${BACKUP_DIR}"; then
    umount "${BACKUP_DIR}"
  fi
  mkfs.ext4 -F "${BACKUP_DEVICE}" >/dev/null
  mount "${BACKUP_DEVICE}" "${BACKUP_DIR}"
}

preflight() {
  require_root
  for command in bash findmnt losetup mount umount rsync gdisk sgdisk sfdisk mkfs.ext4 mkfs.vfat dosfsck e2fsck resize2fs; do
    command -v "${command}" >/dev/null || { echo "Missing command: ${command}" >&2; exit 1; }
  done
  root_source="$(findmnt -nvo SOURCE /)"
  backup_source="$(findmnt -nvo SOURCE "${BACKUP_DIR}")"
  [ -n "${backup_source}" ] && [ "${backup_source}" != "${root_source}" ] || {
    echo "Backup directory must be mounted from a non-root filesystem: ${BACKUP_DIR}" >&2
    exit 1
  }
  probe="$(losetup -f)"
  [ -n "${probe}" ] || { echo "No free loop device" >&2; exit 1; }
  printf 'root_source=%s\nbackup_source=%s\nloop_device=%s\n' "${root_source}" "${backup_source}" "${probe}"
}

prepare_fixtures() {
  mkdir -p "${FIXTURE_DIR}/regular" "${BACKUP_DIR}/external-fixture"
  printf 'baseline fixture\n' > "${FIXTURE_DIR}/regular/baseline.txt"
  printf '#!/bin/sh\necho fixture\n' > "${FIXTURE_DIR}/regular/executable.sh"
  chmod 755 "${FIXTURE_DIR}/regular/executable.sh"
  printf 'external fixture\n' > "${BACKUP_DIR}/external-fixture/should-not-be-backed-up.txt"
  ln -sfn "${BACKUP_DIR}/external-fixture" "${FIXTURE_DIR}/external-link"
  mkdir -p "${FIXTURE_DIR}/bind-target"
  if ! mountpoint -q "${FIXTURE_DIR}/bind-target"; then
    mount --bind "${BACKUP_DIR}/external-fixture" "${FIXTURE_DIR}/bind-target"
  fi
}

mutate_fixtures() {
  printf 'changed fixture\n' > "${FIXTURE_DIR}/regular/baseline.txt"
  printf 'new fixture\n' > "${FIXTURE_DIR}/regular/created.txt"
  rm -f "${FIXTURE_DIR}/regular/deleted.txt"
  touch "${FIXTURE_DIR}/regular/deleted.txt"
  rm -f "${FIXTURE_DIR}/regular/deleted.txt"
  chmod 700 "${FIXTURE_DIR}/regular/executable.sh"
  ln -sfn "${FIXTURE_DIR}/regular/baseline.txt" "${FIXTURE_DIR}/internal-link"
}

run_backup() {
  local phase="$1"
  mkdir -p "${ARTIFACT_DIR}/${phase}"
  preflight | tee "${ARTIFACT_DIR}/${phase}/preflight.txt"
  prepare_fixtures
  if [ "${phase}" = "incremental" ]; then
    mutate_fixtures
  fi
  findmnt -lno TARGET,SOURCE > "${ARTIFACT_DIR}/${phase}/mounts.txt"
  find "${FIXTURE_DIR}" -xdev -printf '%P\t%y\t%m\n' | sort > "${ARTIFACT_DIR}/${phase}/fixture-manifest.txt"
  printf 'candidate=%s\nrevision=%s\nphase=%s\n' "${CANDIDATE}" "${REVISION}" "${phase}" > "${ARTIFACT_DIR}/${phase}/metadata.txt"

  if [ "${phase}" = "initial" ]; then
    "${IMAGE_BACKUP}" -n -o "--exclude=${ARTIFACT_DIR%/artifacts/*}" -i "${IMAGE_FILE},${INITIAL_SIZE_MB},0" 2>&1 | tee "${ARTIFACT_DIR}/${phase}/image-backup.log"
  else
    [ -f "${IMAGE_FILE}" ] || { echo "Missing initial image: ${IMAGE_FILE}" >&2; exit 1; }
    "${IMAGE_BACKUP}" -o "--exclude=${ARTIFACT_DIR%/artifacts/*}" "${IMAGE_FILE}" 2>&1 | tee "${ARTIFACT_DIR}/${phase}/image-backup.log"
  fi

  sfdisk --dump "${IMAGE_FILE}" > "${ARTIFACT_DIR}/${phase}/partition-table.txt"
  blkid "${IMAGE_FILE}"* > "${ARTIFACT_DIR}/${phase}/blkid.txt" || true
  printf 'y\n' | "${IMAGE_BACKUP%/*}/image-check" "${IMAGE_FILE}" > "${ARTIFACT_DIR}/${phase}/image-check.txt" 2>&1
  "$(dirname "${BASH_SOURCE[0]}")/inspect-image.sh" "${IMAGE_FILE}" "${ARTIFACT_DIR}/${phase}"
}

case "${ACTION}" in
  setup-backup)
    BACKUP_DIR="${2:-}"
    BACKUP_DEVICE="${3:-}"
    [ -n "${BACKUP_DIR}" ] && [ -n "${BACKUP_DEVICE}" ] || { echo "Usage: $0 setup-backup BACKUP_DIR BACKUP_DEVICE" >&2; exit 2; }
    setup_backup
    ;;
  preflight)
    BACKUP_DIR="${2:-}"
    [ -n "${BACKUP_DIR}" ] || { echo "Usage: $0 preflight BACKUP_DIR" >&2; exit 2; }
    preflight
    ;;
  initial|incremental)
    require_root
    [ -x "${IMAGE_BACKUP}" ] || { echo "Missing image-backup candidate" >&2; exit 1; }
    run_backup "${ACTION}"
    ;;
  *)
    echo "Usage: $0 {preflight|initial|incremental} ..." >&2
    exit 2
    ;;
esac
