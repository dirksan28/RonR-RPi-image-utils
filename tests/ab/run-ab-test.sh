#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${AB_CONFIG:-${SCRIPT_DIR}/config.env}"
ACTION="${1:-}"

log_message() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

usage() {
  echo "Usage: $0 {prepare|preflight|cleanup|cleanall|initial|incremental|all}" >&2
  exit 2
}

[ -n "${ACTION}" ] || usage
[ -f "${CONFIG_FILE}" ] || { echo "Missing configuration: ${CONFIG_FILE}" >&2; exit 2; }
# shellcheck source=/dev/null
cd "${PROJECT_DIR}"
source "${CONFIG_FILE}"
export LANG=C
export LANGUAGE=C
export LC_ALL=C

if [ "${ACTION}" = "cleanup" ] || [ "${ACTION}" = "clean" ] || [ "${ACTION}" = "cleanall" ]; then
  exec bash "${SCRIPT_DIR}/cleanup.sh" "${CONFIG_FILE}" "${ACTION}"
fi

for required in BASE_IMAGE_SHA256 PREPARED_CACHE_DIR PREPARED_IMAGE KERNEL_IMAGE INITRAMFS_IMAGE GUEST_USER SSH_PRIVATE_KEY SSH_PUBLIC_KEY GUEST_WORKDIR GUEST_BACKUP_DIR GUEST_BACKUP_DEVICE BACKUP_DISK_SIZE_GB UPSTREAM_REPOSITORY UPSTREAM_REPO_DIR UPSTREAM_REVISION INITIAL_SIZE_MB ARTIFACT_DIR; do
  [ -n "${!required:-}" ] || { echo "Missing ${required} in ${CONFIG_FILE}" >&2; exit 2; }
done
[ -f "${PROJECT_DIR}/image-backup" ] || { echo "Local image-backup not found" >&2; exit 2; }

for command in git qemu-system-aarch64 qemu-img virt-customize guestfish virt-copy-out qemu-aarch64-static dpkg-deb ssh scp ssh-keygen curl xz sha256sum; do
  command -v "${command}" >/dev/null || { echo "Missing host command: ${command}" >&2; exit 1; }
done

SSH_TARGET="${GUEST_USER}@127.0.0.1"
SSH_ARGS=(-F /dev/null -p "${SSH_PORT}" -i "${SSH_PRIVATE_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=5)
SCP_ARGS=(-F /dev/null -P "${SSH_PORT}" -i "${SSH_PRIVATE_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=5)
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOCAL_ARTIFACT_DIR="${ARTIFACT_DIR}/testresult${RUN_ID}"
mkdir -p "${LOCAL_ARTIFACT_DIR}"
GUEST_PID=""
CURRENT_STAGE="initializing"
CURRENT_CANDIDATE=""
CURRENT_PHASE=""

remote() {
  ssh "${SSH_ARGS[@]}" "${SSH_TARGET}" "$@"
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
      all) log_message "[PASS] A/B test completed successfully" ;;
      prepare|preflight|initial) log_message "[PASS] ${ACTION} completed successfully" ;;
      *) log_message "[PASS] Test command completed successfully" ;;
    esac
  else
    log_message "[FAIL] ${ACTION} aborted (exit ${exit_code})" >&2
    [ -n "${CURRENT_CANDIDATE}" ] && log_message "[FAIL] candidate: ${CURRENT_CANDIDATE}" >&2
    [ -n "${CURRENT_PHASE}" ] && log_message "[FAIL] phase: ${CURRENT_PHASE}" >&2
    log_message "[FAIL] stage: ${CURRENT_STAGE}" >&2
  fi
  log_message "[INFO] A/B artifacts: ${LOCAL_ARTIFACT_DIR}"
  exit "${exit_code}"
}
trap finish_run EXIT

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
  CURRENT_STAGE="starting QEMU guest (${candidate})"
  log_message "[INFO] starting QEMU guest: ${candidate}"
  mkdir -p "${candidate_dir}"
  "${SCRIPT_DIR}/qemu-guest.sh" start "${candidate_dir}" "${PREPARED_IMAGE}" "${KERNEL_IMAGE}" "${INITRAMFS_IMAGE}" "${BACKUP_DISK_SIZE_GB}" "${SSH_PORT}" "${QEMU_MACHINE}" "${QEMU_MEMORY_MB}" "${QEMU_CPUS}" "${QEMU_EXTRA_ARGS[@]}" &
  GUEST_PID=$!
  wait_for_ssh
}

deploy_support() {
  CURRENT_STAGE="deploying guest support"
  log_message "[INFO] deploying guest support: ${CURRENT_CANDIDATE:-preflight}"
  remote "mkdir -p '${GUEST_WORKDIR}/bin' '${GUEST_WORKDIR}/artifacts'"
  scp "${SCP_ARGS[@]}" "${SCRIPT_DIR}/remote-run.sh" "${SCRIPT_DIR}/inspect-image.sh" "${PROJECT_DIR}/image-check" "${SSH_TARGET}:${GUEST_WORKDIR}/bin/"
  remote "chmod 755 '${GUEST_WORKDIR}/bin/'*.sh '${GUEST_WORKDIR}/bin/image-check'"
}

preflight() {
  CURRENT_STAGE="preparing cache for preflight"
  log_message "[INFO] preflight: preparing or reusing guest cache"
  prepare_cache
  log_message "[INFO] preflight: booting validation guest"
  start_guest preflight
  deploy_support
  log_message "[INFO] preflight: checking backup disk and guest tools"
  remote "sudo -n '${GUEST_WORKDIR}/bin/remote-run.sh' setup-backup '${GUEST_BACKUP_DIR}' '${GUEST_BACKUP_DEVICE}'"
  remote "sudo -n '${GUEST_WORKDIR}/bin/remote-run.sh' preflight '${GUEST_BACKUP_DIR}'"
  stop_guest
}

prepare_cache() {
  CURRENT_STAGE="preparing guest cache"
  log_message "[INFO] prepare: building or reusing guest cache"
  "${SCRIPT_DIR}/prepare-raspios-virt.sh" "${CONFIG_FILE}"
  CURRENT_STAGE="pinning upstream source"
  log_message "[INFO] prepare: checking out pinned upstream revision"
  prepare_upstream
  [ -f "${SSH_PRIVATE_KEY}" ] || { echo "Preparation did not create SSH private key" >&2; exit 1; }
  [ -f "${SSH_PUBLIC_KEY}" ] || { echo "Preparation did not create SSH public key" >&2; exit 1; }
}

prepare() {
  prepare_cache
  log_message "[INFO] prepare: boot-validating prepared guest"
  start_guest prepared-boot-validation
  deploy_support
  log_message "[INFO] prepare: checking backup disk and guest tools"
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

  CURRENT_CANDIDATE="${candidate}"
  log_message "[INFO] ${candidate}: starting sequential candidate run"
  start_guest "${candidate}"
  deploy_support
  CURRENT_STAGE="preparing backup disk (${candidate})"
  log_message "[INFO] ${candidate}: preparing backup disk"
  remote "sudo -n '${GUEST_WORKDIR}/bin/remote-run.sh' setup-backup '${GUEST_BACKUP_DIR}' '${GUEST_BACKUP_DEVICE}'"
  CURRENT_STAGE="uploading ${candidate} image-backup"
  log_message "[INFO] ${candidate}: uploading image-backup"
  scp "${SCP_ARGS[@]}" "${source_script}" "${SSH_TARGET}:${GUEST_WORKDIR}/bin/${candidate}-image-backup"
  remote "chmod 755 '${GUEST_WORKDIR}/bin/${candidate}-image-backup'"
  for phase in initial incremental; do
    CURRENT_PHASE="${phase}"
    CURRENT_STAGE="running ${candidate} ${phase} backup"
    log_message "[INFO] ${candidate}/${phase}: starting backup phase"
    if remote "sudo -n '${GUEST_WORKDIR}/bin/remote-run.sh' '${phase}' '${candidate}' '${GUEST_WORKDIR}/bin/${candidate}-image-backup' '${GUEST_BACKUP_DIR}' '${INITIAL_SIZE_MB}' '${GUEST_WORKDIR}/artifacts/${candidate}' '${UPSTREAM_REVISION}'"; then
      :
    else
      local phase_status=$?
      log_message "[FAIL] ${candidate}/${phase} backup failed (exit ${phase_status})" >&2
      CURRENT_STAGE="preserving partial ${candidate}/${phase} artifacts"
      scp -r "${SCP_ARGS[@]}" "${SSH_TARGET}:${GUEST_WORKDIR}/artifacts/${candidate}" "${LOCAL_ARTIFACT_DIR}/" >/dev/null 2>&1 || true
      return "${phase_status}"
    fi
    [ "${phase}" = "${final_phase}" ] && break
  done
  CURRENT_STAGE="downloading ${candidate} artifacts"
  scp -r "${SCP_ARGS[@]}" "${SSH_TARGET}:${GUEST_WORKDIR}/artifacts/${candidate}" "${LOCAL_ARTIFACT_DIR}/"
  stop_guest
  CURRENT_PHASE=""
}

compare_phase() {
  local phase="$1"
  local report_file="${LOCAL_ARTIFACT_DIR}/${phase}-comparison.log"
  CURRENT_STAGE="comparing ${phase} results"
  log_message "[INFO] Comparing ${phase} results..."
  if "${SCRIPT_DIR}/compare-results.sh" "${LOCAL_ARTIFACT_DIR}/upstream/${phase}" "${LOCAL_ARTIFACT_DIR}/local/${phase}" > "${report_file}" 2>&1; then
    log_message "[PASS] ${phase} comparison"
    return 0
  else
    local compare_status=$?
    log_message "[FAIL] ${phase} comparison (exit ${compare_status})" >&2
    cat "${report_file}" >&2
    return "${compare_status}"
  fi
}

case "${ACTION}" in
  prepare)
    prepare
    ;;
  preflight)
    preflight
    ;;
  initial)
    prepare_cache
    run_candidate upstream initial
    run_candidate local initial
    compare_phase initial
    ;;
  incremental)
    echo "Incremental requires the initial image. Use: $0 all" >&2
    exit 2
    ;;
  all)
    prepare_cache
    run_candidate upstream incremental
    run_candidate local incremental
    comparison_status=0
    compare_phase initial || comparison_status=1
    compare_phase incremental || comparison_status=1
    exit "${comparison_status}"
    ;;
  *)
    usage
    ;;
esac

echo "Artifacts: ${LOCAL_ARTIFACT_DIR}"
