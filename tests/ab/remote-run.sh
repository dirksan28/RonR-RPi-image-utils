#!/bin/bash
set -euo pipefail

export LANG=C
export LANGUAGE=C
export LC_ALL=C

ACTION="${1:-}"
CANDIDATE="${2:-}"
IMAGE_BACKUP="${3:-}"
BACKUP_DIR="${4:-}"
INITIAL_SIZE_MB="${5:-}"
ARTIFACT_DIR="${6:-}"
REVISION="${7:-}"
FIXTURE_DIR="/opt/image-backup-ab-fixtures"
IMAGE_FILE="${BACKUP_DIR}/${CANDIDATE}.img"

log_message() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

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

run_image_backup() {
  local label="$1"
  local log_file="$2"
  shift 2

  (
    "$@" 2>&1 | tee "${log_file}"
    exit "${PIPESTATUS[0]}"
  ) &
  local command_pid=$!
  local elapsed=0
  local command_status=0

  while kill -0 "${command_pid}" 2>/dev/null; do
    sleep 30
    if kill -0 "${command_pid}" 2>/dev/null; then
      elapsed=$((elapsed + 30))
      log_message "[INFO] ${label}: image-backup still running after ${elapsed}s"
      ps -eo pid=,ppid=,stat=,etime=,comm=,args= | \
        grep -E 'image-backup|rsync|e2fsck|resize2fs|sfdisk|sgdisk' | \
        grep -v grep || true
    fi
  done

  wait "${command_pid}" || command_status=$?
  return "${command_status}"
}

run_backup() {
  local phase="$1"
  mkdir -p "${ARTIFACT_DIR}/${phase}"
  log_message "[INFO] ${CANDIDATE}/${phase}: checking guest prerequisites"
  preflight | tee "${ARTIFACT_DIR}/${phase}/preflight.txt"
  log_message "[INFO] ${CANDIDATE}/${phase}: preparing fixtures"
  prepare_fixtures
  if [ "${phase}" = "incremental" ]; then
    log_message "[INFO] ${CANDIDATE}/${phase}: applying fixture changes"
    mutate_fixtures
  fi
  findmnt -lno TARGET,SOURCE > "${ARTIFACT_DIR}/${phase}/mounts.txt"
  find "${FIXTURE_DIR}" -xdev -printf '%P\t%y\t%m\n' | sort > "${ARTIFACT_DIR}/${phase}/fixture-manifest.txt"
  printf 'candidate=%s\nrevision=%s\nphase=%s\n' "${CANDIDATE}" "${REVISION}" "${phase}" > "${ARTIFACT_DIR}/${phase}/metadata.txt"

  if [ "${phase}" = "initial" ]; then
    log_message "[INFO] ${CANDIDATE}/${phase}: running image-backup initial phase"
    run_image_backup "${CANDIDATE}/${phase}" "${ARTIFACT_DIR}/${phase}/image-backup.log" \
      "${IMAGE_BACKUP}" -n -o "--exclude=${ARTIFACT_DIR%/artifacts/*}" -i "${IMAGE_FILE},${INITIAL_SIZE_MB},0"
  else
    [ -f "${IMAGE_FILE}" ] || { echo "Missing initial image: ${IMAGE_FILE}" >&2; exit 1; }
    log_message "[INFO] ${CANDIDATE}/${phase}: running image-backup incremental phase"
    run_image_backup "${CANDIDATE}/${phase}" "${ARTIFACT_DIR}/${phase}/image-backup.log" \
      "${IMAGE_BACKUP}" -o "--exclude=${ARTIFACT_DIR%/artifacts/*}" "${IMAGE_FILE}"
  fi

  log_message "[INFO] ${CANDIDATE}/${phase}: collecting image metadata"
  sfdisk --dump "${IMAGE_FILE}" > "${ARTIFACT_DIR}/${phase}/partition-table.txt"
  blkid "${IMAGE_FILE}"* > "${ARTIFACT_DIR}/${phase}/blkid.txt" || true
  log_message "[INFO] ${CANDIDATE}/${phase}: checking image filesystem"
  image_check_status=0
  "${IMAGE_BACKUP%/*}/image-check" --non-interactive "${IMAGE_FILE}" > "${ARTIFACT_DIR}/${phase}/image-check.txt" 2>&1 || image_check_status=$?
  printf '%s\n' "${image_check_status}" > "${ARTIFACT_DIR}/${phase}/image-check.status"
  if [ "${image_check_status}" -ne 0 ]; then
    log_message "[FAIL] ${CANDIDATE}/${phase}: filesystem check failed with exit code ${image_check_status}" >&2
    return "${image_check_status}"
  fi
  log_message "[INFO] ${CANDIDATE}/${phase}: inspecting image contents (this may take a while)"
  inspect_log="${ARTIFACT_DIR}/${phase}/inspect-image.log"
  inspect_status=0
  set +e
  "$(dirname "${BASH_SOURCE[0]}")/inspect-image.sh" "${IMAGE_FILE}" "${ARTIFACT_DIR}/${phase}" 2>&1 | tee "${inspect_log}"
  inspect_pipeline_status=("${PIPESTATUS[@]}")
  set -e
  inspect_status="${inspect_pipeline_status[0]}"
  printf '%s\n' "${inspect_status}" > "${ARTIFACT_DIR}/${phase}/inspect-image.status"
  if [ "${inspect_status}" -ne 0 ]; then
    log_message "[FAIL] ${CANDIDATE}/${phase}: inspect-image failed with exit code ${inspect_status}" >&2
    return "${inspect_status}"
  fi
  log_message "[PASS] ${CANDIDATE}/${phase}: completed"
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
