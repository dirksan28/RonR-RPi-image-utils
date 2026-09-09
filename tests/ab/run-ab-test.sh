#!/bin/bash
# Orchestrate the A/B test: prepare a guest, run both candidates, and compare their artifacts.
#
# Synopsis:
#   Usage: run-ab-test.sh {prepare|preflight|cleanup|clean|cleanall|initial|incremental|all}
#   Actions prepare the guest, run validation or backup phases, clean test resources,
#   and compare upstream and local image-backup results.
#
# check ./README.md for more details
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_DIR="${SCRIPT_DIR}/helperScripts"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${AB_CONFIG:-${SCRIPT_DIR}/config.env}"
ACTION="${1:-}"

log_message() {
  local msg="[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
  printf '%s\n' "${msg}"
  # Also write to result.log in the artifact directory (if it exists)
  if [ -n "${LOCAL_ARTIFACT_DIR:-}" ] && [ -d "${LOCAL_ARTIFACT_DIR}" ]; then
    printf '%s\n' "${msg}" >> "${LOCAL_ARTIFACT_DIR}/result.log"
  fi
}

usage() {
  echo "Usage: $0 {prepare|preflight|cleanup|clean|cleanall|initial|incremental|all}" >&2
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

# Cleanup is delegated before normal test prerequisites are checked so it can recover a partial run.
if [ "${ACTION}" = "cleanup" ] || [ "${ACTION}" = "clean" ] || [ "${ACTION}" = "cleanall" ]; then
  exec bash "${HELPER_DIR}/cleanup.sh" "${CONFIG_FILE}" "${ACTION}"
fi

# The remaining actions need a complete host and guest test environment.
for required in BASE_IMAGE_SHA256 PREPARED_CACHE_DIR PREPARED_IMAGE KERNEL_IMAGE INITRAMFS_IMAGE GUEST_USER SSH_PRIVATE_KEY SSH_PUBLIC_KEY SSH_PORT GUEST_WORKDIR GUEST_BACKUP_DIR GUEST_BACKUP_DEVICE BACKUP_DISK_SIZE_GB UPSTREAM_REPOSITORY UPSTREAM_REPO_DIR UPSTREAM_REVISION INITIAL_SIZE_MB ARTIFACT_DIR; do
  [ -n "${!required:-}" ] || { echo "Missing ${required} in ${CONFIG_FILE}" >&2; exit 2; }
done
[ -f "${PROJECT_DIR}/image-backup" ] || { echo "Local image-backup not found" >&2; exit 2; }

# Fail early when a long-running QEMU test cannot have all required host tools.
for command in git qemu-system-aarch64 qemu-img virt-customize guestfish virt-copy-out qemu-aarch64-static dpkg-deb ssh scp ssh-keygen curl xz sha256sum; do
  command -v "${command}" >/dev/null || { echo "Missing host command: ${command}" >&2; exit 1; }
done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOCAL_ARTIFACT_DIR="${ARTIFACT_DIR}/testresult${RUN_ID}"
mkdir -p "${LOCAL_ARTIFACT_DIR}"
RUN_PID_FILE="${LOCAL_ARTIFACT_DIR}/run-ab-test.pid"
printf '%s %s\n' "$$" "$(awk '{ print $22 }' "/proc/$$/stat")" > "${RUN_PID_FILE}"
SSH_TARGET=""
SSH_ARGS=()
SCP_ARGS=()
GUEST_PID=""
GUEST_CONSOLE_LOG=""
CURRENT_STAGE="initializing"
CURRENT_CANDIDATE=""
CURRENT_PHASE=""

port_is_in_use() {
  local port="$1"
  # Bash's TCP redirection detects listeners without adding another host dependency.
  (exec 3<>"/dev/tcp/127.0.0.1/${port}") >/dev/null 2>&1
}

port_holder() {
  local port="$1"
  local holder=""
  local details=""

  if command -v ss >/dev/null 2>&1; then
    holder="$(ss -Hlnpt "sport = :${port}" 2>/dev/null | head -n 1 || true)"
  fi
  if { [ -z "${holder}" ] || [[ "${holder}" != *"users:("* ]]; } && command -v fuser >/dev/null 2>&1; then
    details="$(fuser -v "${port}/tcp" 2>&1 | tr '\n' ' ' || true)"
    [ -n "${details}" ] && holder="${holder}${holder:+; }fuser: ${details}"
  fi
  if { [ -z "${holder}" ] || [[ "${holder}" != *"users:("* ]]; } && command -v lsof >/dev/null 2>&1; then
    details="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | tail -n +2 | tr '\n' ' ' || true)"
    [ -n "${details}" ] && holder="${holder}${holder:+; }lsof: ${details}"
  fi
  [ -n "${holder}" ] || holder="unknown process (port inspection tools returned no owner)"
  printf '%s' "${holder}"
}

select_ssh_port() {
  local requested_port="${SSH_PORT}"
  local candidate
  local attempt

  if ! [[ "${requested_port}" =~ ^[0-9]+$ ]] || [ "${requested_port}" -lt 1024 ] || [ "${requested_port}" -gt 65535 ]; then
    echo "SSH_PORT must be an integer between 1024 and 65535: ${requested_port}" >&2
    return 2
  fi

  for ((attempt = 0; attempt < 20; attempt++)); do
    candidate=$((requested_port + attempt))
    [ "${candidate}" -le 65535 ] || break
    if port_is_in_use "${candidate}"; then
      log_message "[WARNING] SSH port ${candidate} is held by: $(port_holder "${candidate}")"
    else
      if [ "${candidate}" -ne "${requested_port}" ]; then
        log_message "[INFO] SSH port ${requested_port} is busy; using ${candidate}"
      fi
      SSH_PORT="${candidate}"
      return 0
    fi
  done

  echo "No available SSH port in ${requested_port}..$((requested_port + 19))" >&2
  return 1
}

configure_ssh() {
  # Disable user SSH configuration and known-host state for repeatable local connections.
  SSH_TARGET="${GUEST_USER}@127.0.0.1"
  SSH_ARGS=(-F /dev/null -p "${SSH_PORT}" -i "${SSH_PRIVATE_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=5)
  SCP_ARGS=(-F /dev/null -P "${SSH_PORT}" -i "${SSH_PRIVATE_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=5)
}

remote() {
  # Keep every guest command on the same isolated SSH connection settings.
  ssh "${SSH_ARGS[@]}" "${SSH_TARGET}" "$@"
}

stop_guest() {
  if [ -n "${GUEST_PID}" ]; then
    # Ask the guest to shut down cleanly, then reap QEMU even if SSH is unavailable.
    CURRENT_STAGE="stopping QEMU guest"
    remote "sudo -n poweroff" >/dev/null 2>&1 || true
    wait "${GUEST_PID}" || true
    GUEST_PID=""
  fi
}

finish_run() {
  local exit_code=$?
  trap - EXIT
  # The EXIT trap preserves the failure stage and cleans up a guest left by an error.
  stop_guest

  if [ "${exit_code}" -eq 0 ]; then
    case "${ACTION}" in
      all) log_message "[PASS] A/B test completed successfully" ;;
      prepare|preflight|initial) log_message "[PASS] ${ACTION} completed successfully" ;;
      *) log_message "[PASS] Test command completed successfully" ;;
    esac
    log_message "[INFO] Success Exitcode: ${exit_code}"
  else
    log_message "[FAIL] ${ACTION} aborted (exit ${exit_code})" >&2
    [ -n "${CURRENT_CANDIDATE}" ] && log_message "[FAIL] candidate: ${CURRENT_CANDIDATE}" >&2
    [ -n "${CURRENT_PHASE}" ] && log_message "[FAIL] phase: ${CURRENT_PHASE}" >&2
    log_message "[FAIL] stage: ${CURRENT_STAGE}" >&2
    log_message "[INFO] Fail Exitcode: ${exit_code}"
  fi
  log_message "[INFO] A/B artifacts: ${LOCAL_ARTIFACT_DIR}"
  rm -f "${RUN_PID_FILE}"
  exit "${exit_code}"
}
trap finish_run EXIT

wait_for_ssh() {
  local elapsed=0
  # Poll until the guest is usable, but never accept SSH from an unrelated process
  # after this run's QEMU child has already exited.
  while :; do
    local process_state
    process_state="$(ps -o stat= -p "${GUEST_PID}" 2>/dev/null | tr -d '[:space:]')" || true
    if [ -z "${process_state}" ] || [[ "${process_state}" == Z* ]]; then
      if [ "${elapsed}" -lt 2 ]; then
        sleep 2
        elapsed=2
        continue
      fi
      local guest_status=0
      wait "${GUEST_PID}" || guest_status=$?
      GUEST_PID=""
      [ "${guest_status}" -ne 0 ] || guest_status=1
      echo "QEMU guest exited before SSH became ready (exit ${guest_status})" >&2
      if [ -f "${GUEST_CONSOLE_LOG}" ]; then
        echo "Last QEMU console output:" >&2
        tail -n 20 "${GUEST_CONSOLE_LOG}" >&2
      fi
      return "${guest_status}"
    fi
    if remote "true" >/dev/null 2>&1; then
      return 0
    fi
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
  CURRENT_STAGE="selecting host SSH port"
  select_ssh_port
  configure_ssh
  CURRENT_STAGE="starting QEMU guest (${candidate})"
  log_message "[INFO] starting QEMU guest: ${candidate} (SSH port ${SSH_PORT})"
  # Each candidate gets a separate artifact directory and QEMU process.
  mkdir -p "${candidate_dir}"
  GUEST_CONSOLE_LOG="${candidate_dir}/qemu-console.log"
  "${HELPER_DIR}/qemu-guest.sh" start "${candidate_dir}" "${PREPARED_IMAGE}" "${KERNEL_IMAGE}" "${INITRAMFS_IMAGE}" "${BACKUP_DISK_SIZE_GB}" "${SSH_PORT}" "${QEMU_MACHINE}" "${QEMU_MEMORY_MB}" "${QEMU_CPUS}" "${QEMU_EXTRA_ARGS[@]}" &
  GUEST_PID=$!
  CURRENT_STAGE="waiting for guest SSH (${SSH_PORT})"
  wait_for_ssh
}

deploy_support() {
  CURRENT_STAGE="deploying guest support"
  log_message "[INFO] deploying guest support: ${CURRENT_CANDIDATE:-preflight}"
  # Upload only the guest-side helpers and checker needed by the selected phase.
  remote "mkdir -p '${GUEST_WORKDIR}/bin' '${GUEST_WORKDIR}/artifacts'"
  scp "${SCP_ARGS[@]}" "${HELPER_DIR}/remote-run.sh" "${HELPER_DIR}/inspect-image.sh" "${PROJECT_DIR}/image-check" "${SSH_TARGET}:${GUEST_WORKDIR}/bin/"
  remote "chmod 755 '${GUEST_WORKDIR}/bin/'*.sh '${GUEST_WORKDIR}/bin/image-check'"
}

preflight() {
  CURRENT_STAGE="preparing cache for preflight"
  # Validate the prepared guest and backup disk before running either candidate.
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
  # Build or reuse the guest image, then pin the exact upstream source revision.
  log_message "[INFO] prepare: building or reusing guest cache"
  "${HELPER_DIR}/prepare-raspios-virt.sh" "${CONFIG_FILE}"
  CURRENT_STAGE="pinning upstream source"
  log_message "[INFO] prepare: checking out pinned upstream revision"
  prepare_upstream
  [ -f "${SSH_PRIVATE_KEY}" ] || { echo "Preparation did not create SSH private key" >&2; exit 1; }
  [ -f "${SSH_PUBLIC_KEY}" ] || { echo "Preparation did not create SSH public key" >&2; exit 1; }
}

prepare() {
  # Preparation ends with a disposable boot validation of the newly built guest.
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
  # Keep the upstream checkout detached and exactly aligned with the configured revision.
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
  # Run phases one candidate at a time so each starts with a known guest state.
  start_guest "${candidate}"
  deploy_support
  CURRENT_STAGE="preparing backup disk (${candidate})"
  log_message "[INFO] ${candidate}: preparing backup disk"
  remote "sudo -n '${GUEST_WORKDIR}/bin/remote-run.sh' setup-backup '${GUEST_BACKUP_DIR}' '${GUEST_BACKUP_DEVICE}'"
  CURRENT_STAGE="uploading ${candidate} image-backup"
  log_message "[INFO] ${candidate}: uploading image-backup"
  scp "${SCP_ARGS[@]}" "${source_script}" "${SSH_TARGET}:${GUEST_WORKDIR}/bin/${candidate}-image-backup"
  remote "chmod 755 '${GUEST_WORKDIR}/bin/${candidate}-image-backup'"
  # Initial is always run; incremental is included only when requested by the caller.
  for phase in initial incremental; do
    CURRENT_PHASE="${phase}"
    CURRENT_STAGE="running ${candidate} ${phase} backup"
    log_message "[INFO] ${candidate}/${phase}: starting backup phase"
    if remote "sudo -n '${GUEST_WORKDIR}/bin/remote-run.sh' '${phase}' '${candidate}' '${GUEST_WORKDIR}/bin/${candidate}-image-backup' '${GUEST_BACKUP_DIR}' '${INITIAL_SIZE_MB}' '${GUEST_WORKDIR}/artifacts/${candidate}' '${UPSTREAM_REVISION}'"; then
      :
    else
      local phase_status=$?
      log_message "[FAIL] ${candidate}/${phase} backup failed (exit ${phase_status})" >&2
      # Preserve partial artifacts before returning so a failed phase remains diagnosable.
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
  # Keep the full diff in an artifact while reporting only the comparison result here.
  if "${HELPER_DIR}/compare-results.sh" "${LOCAL_ARTIFACT_DIR}/upstream/${phase}" "${LOCAL_ARTIFACT_DIR}/local/${phase}" > "${report_file}" 2>&1; then
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
