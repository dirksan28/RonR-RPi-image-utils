#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${AB_CONFIG:-${SCRIPT_DIR}/config.env}"
ACTION="${1:-}"

usage() {
  echo "Usage: $0 {prepare|preflight|initial|incremental|all}" >&2
  exit 2
}

[ -n "${ACTION}" ] || usage
[ -f "${CONFIG_FILE}" ] || { echo "Missing configuration: ${CONFIG_FILE}" >&2; exit 2; }
# shellcheck source=/dev/null
cd "${PROJECT_DIR}"
source "${CONFIG_FILE}"

for required in BASE_IMAGE_SHA256 PREPARED_CACHE_DIR PREPARED_IMAGE KERNEL_IMAGE INITRAMFS_IMAGE GUEST_USER SSH_PRIVATE_KEY SSH_PUBLIC_KEY GUEST_WORKDIR GUEST_BACKUP_DIR GUEST_BACKUP_DEVICE BACKUP_DISK_SIZE_GB UPSTREAM_REPOSITORY UPSTREAM_REPO_DIR UPSTREAM_REVISION INITIAL_SIZE_MB ARTIFACT_DIR; do
  [ -n "${!required:-}" ] || { echo "Missing ${required} in ${CONFIG_FILE}" >&2; exit 2; }
done
[ -f "${PROJECT_DIR}/image-backup" ] || { echo "Local image-backup not found" >&2; exit 2; }

for command in git qemu-system-aarch64 qemu-img virt-customize guestfish virt-copy-out qemu-aarch64-static dpkg-deb ssh scp ssh-keygen curl xz sha256sum; do
  command -v "${command}" >/dev/null || { echo "Missing host command: ${command}" >&2; exit 1; }
done

SSH_TARGET="${GUEST_USER}@127.0.0.1"
SSH_ARGS=(-F /dev/null -p "${SSH_PORT}" -i "${SSH_PRIVATE_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOCAL_ARTIFACT_DIR="${ARTIFACT_DIR}/${RUN_ID}"
mkdir -p "${LOCAL_ARTIFACT_DIR}"
GUEST_PID=""

remote() {
  ssh "${SSH_ARGS[@]}" "${SSH_TARGET}" "$@"
}

stop_guest() {
  if [ -n "${GUEST_PID}" ]; then
    remote "sudo -n poweroff" >/dev/null 2>&1 || true
    wait "${GUEST_PID}" || true
    GUEST_PID=""
  fi
}
trap stop_guest EXIT

wait_for_ssh() {
  local elapsed=0
  until remote "true" >/dev/null 2>&1; do
    elapsed=$((elapsed + 2))
    [ "${elapsed}" -le "${SSH_WAIT_SECONDS:-300}" ] || {
      echo "Guest SSH did not become ready within ${SSH_WAIT_SECONDS:-300} seconds" >&2
      return 1
    }
    if [ $((elapsed % 30)) -eq 0 ]; then
      echo "Waiting for guest SSH (${elapsed}/${SSH_WAIT_SECONDS:-300} seconds)..." >&2
    fi
    sleep 2
  done
}

start_guest() {
  local candidate="$1"
  local candidate_dir="${LOCAL_ARTIFACT_DIR}/${candidate}"
  mkdir -p "${candidate_dir}"
  "${SCRIPT_DIR}/qemu-guest.sh" start "${candidate_dir}" "${PREPARED_IMAGE}" "${KERNEL_IMAGE}" "${INITRAMFS_IMAGE}" "${BACKUP_DISK_SIZE_GB}" "${SSH_PORT}" "${QEMU_MACHINE}" "${QEMU_MEMORY_MB}" "${QEMU_CPUS}" "${QEMU_EXTRA_ARGS[@]}" &
  GUEST_PID=$!
  wait_for_ssh
}

deploy_support() {
  remote "mkdir -p '${GUEST_WORKDIR}/bin' '${GUEST_WORKDIR}/artifacts'"
  scp "${SSH_ARGS[@]}" "${SCRIPT_DIR}/remote-run.sh" "${SCRIPT_DIR}/inspect-image.sh" "${PROJECT_DIR}/image-check" "${SSH_TARGET}:${GUEST_WORKDIR}/bin/"
  remote "chmod 755 '${GUEST_WORKDIR}/bin/'*.sh '${GUEST_WORKDIR}/bin/image-check'"
}

preflight() {
  prepare
  start_guest preflight
  deploy_support
  remote "sudo -n '${GUEST_WORKDIR}/bin/remote-run.sh' setup-backup '${GUEST_BACKUP_DIR}' '${GUEST_BACKUP_DEVICE}'"
  remote "sudo -n '${GUEST_WORKDIR}/bin/remote-run.sh' preflight '${GUEST_BACKUP_DIR}'"
  stop_guest
}

prepare() {
  "${SCRIPT_DIR}/prepare-raspios-virt.sh" "${CONFIG_FILE}"
  prepare_upstream
  [ -f "${SSH_PRIVATE_KEY}" ] || { echo "Preparation did not create SSH private key" >&2; exit 1; }
  [ -f "${SSH_PUBLIC_KEY}" ] || { echo "Preparation did not create SSH public key" >&2; exit 1; }
  start_guest prepared-boot-validation
  deploy_support
  remote "sudo -n '${GUEST_WORKDIR}/bin/remote-run.sh' setup-backup '${GUEST_BACKUP_DIR}' '${GUEST_BACKUP_DEVICE}'"
  remote "sudo -n '${GUEST_WORKDIR}/bin/remote-run.sh' preflight '${GUEST_BACKUP_DIR}'"
  stop_guest
}

prepare_upstream() {
  if [ ! -d "${UPSTREAM_REPO_DIR}/.git" ]; then
    git clone --no-checkout "${UPSTREAM_REPOSITORY}" "${UPSTREAM_REPO_DIR}"
  fi
  git -C "${UPSTREAM_REPO_DIR}" remote set-url origin "${UPSTREAM_REPOSITORY}"
  git -C "${UPSTREAM_REPO_DIR}" fetch --quiet origin "${UPSTREAM_REVISION}"
  git -C "${UPSTREAM_REPO_DIR}" checkout --quiet --detach "${UPSTREAM_REVISION}"
  [ "$(git -C "${UPSTREAM_REPO_DIR}" rev-parse HEAD)" = "${UPSTREAM_REVISION}" ] || {
    echo "Unable to check out upstream revision: ${UPSTREAM_REVISION}" >&2
    exit 1
  }
  [ -f "${UPSTREAM_REPO_DIR}/image-backup" ] || {
    echo "Upstream revision does not contain image-backup: ${UPSTREAM_REVISION}" >&2
    exit 1
  }
}

run_candidate() {
  local candidate="$1"
  local final_phase="$2"
  local source_script

  case "${candidate}" in
    upstream)
      source_script="${UPSTREAM_REPO_DIR}/image-backup"
      ;;
    local) source_script="${PROJECT_DIR}/image-backup" ;;
    *) echo "Unknown candidate: ${candidate}" >&2; exit 2 ;;
  esac

  start_guest "${candidate}"
  deploy_support
  remote "sudo -n '${GUEST_WORKDIR}/bin/remote-run.sh' setup-backup '${GUEST_BACKUP_DIR}' '${GUEST_BACKUP_DEVICE}'"
  scp "${SSH_ARGS[@]}" "${source_script}" "${SSH_TARGET}:${GUEST_WORKDIR}/bin/${candidate}-image-backup"
  remote "chmod 755 '${GUEST_WORKDIR}/bin/${candidate}-image-backup'"
  for phase in initial incremental; do
    remote "sudo -n '${GUEST_WORKDIR}/bin/remote-run.sh' '${phase}' '${candidate}' '${GUEST_WORKDIR}/bin/${candidate}-image-backup' '${GUEST_BACKUP_DIR}' '${INITIAL_SIZE_MB}' '${GUEST_WORKDIR}/artifacts/${candidate}' '${UPSTREAM_REVISION}'"
    [ "${phase}" = "${final_phase}" ] && break
  done
  scp -r "${SSH_ARGS[@]}" "${SSH_TARGET}:${GUEST_WORKDIR}/artifacts/${candidate}" "${LOCAL_ARTIFACT_DIR}/"
  stop_guest
}

compare_phase() {
  local phase="$1"
  "${SCRIPT_DIR}/compare-results.sh" "${LOCAL_ARTIFACT_DIR}/upstream/${phase}" "${LOCAL_ARTIFACT_DIR}/local/${phase}"
}

case "${ACTION}" in
  prepare)
    prepare
    ;;
  preflight)
    preflight
    ;;
  initial)
    preflight
    run_candidate upstream initial
    run_candidate local initial
    compare_phase initial
    ;;
  incremental)
    echo "Incremental requires the initial image. Use: $0 all" >&2
    exit 2
    ;;
  all)
    preflight
    run_candidate upstream incremental
    run_candidate local incremental
    compare_phase initial
    compare_phase incremental
    ;;
  *)
    usage
    ;;
esac

echo "Artifacts: ${LOCAL_ARTIFACT_DIR}"
