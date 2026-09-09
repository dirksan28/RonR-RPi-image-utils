#!/bin/bash
# Stop test-owned runners and QEMU, then remove temporary mounts and loop resources while preserving the prepared cache.
#
# Synopsis:
#   Usage: cleanup.sh CONFIG_FILE [cleanup|clean|cleanall]
#   Expects the A/B test configuration and an optional cleanup action.
#   Stops active or stale test runners and QEMU processes, unmounts test
#   filesystems, detaches test loops, and removes artifact results only for the
#   cleanall action.
#   Process, port, mount, and loop discovery is attempted without root. Privileged
#   cleanup uses non-interactive sudo only after test-owned resources are found.
#   Returns 0 after successful cleanup; returns 1 when test resources remain;
#   returns 2 when CONFIG_FILE is missing or invalid.
#
#   CONFIG_FILE is a sourced Bash file, for example:
#     PREPARED_CACHE_DIR="/path/to/tests/ab/cache"
#     ARTIFACT_DIR="/path/to/tests/ab/artifacts"
#     SSH_PORT=2222
#   See tests/ab/config.example.env for the complete configuration template.
set -u

CONFIG_FILE="${1:-}"
ACTION="${2:-cleanup}"
[ -n "${CONFIG_FILE}" ] && [ -f "${CONFIG_FILE}" ] || {
  echo "Usage: $0 CONFIG_FILE" >&2
  exit 2
}
CONFIG_FILE="$(readlink -f "${CONFIG_FILE}")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Fall back to the repository test paths so cleanup remains useful with a partial config.
CACHE_DIR="${PREPARED_CACHE_DIR:-${PROJECT_DIR}/tests/ab/cache}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${PROJECT_DIR}/tests/ab/artifacts}"
SSH_PORT="${SSH_PORT:-2222}"
CLEANUP_FAILURE=0
PRIVILEGED_CHECKED=0
PRIVILEGED_AVAILABLE=0

log() {
  printf '[cleanup] %s\n' "$*"
}

port_is_in_use() {
  local port="$1"
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

report_ssh_port() {
  if port_is_in_use "${SSH_PORT}"; then
    log "[WARNING] SSH port ${SSH_PORT} is still held by: $(port_holder "${SSH_PORT}")"
    CLEANUP_FAILURE=1
  else
    log "[INFO] SSH port ${SSH_PORT} is free"
  fi
}

# Track resources once; later cleanup steps can safely be called on repeated runs.
declare -a TEST_LOOPS=()
declare -a MOUNT_TARGETS=()
declare -a TEST_RUNNERS=()

contains_item() {
  local wanted="$1"
  shift
  local item
  for item in "$@"; do
    [ "${item}" = "${wanted}" ] && return 0
  done
  return 1
}

add_loop() {
  local loop="$1"
  [ -n "${loop}" ] || return 0
  contains_item "${loop}" "${TEST_LOOPS[@]}" || TEST_LOOPS+=("${loop}")
}

add_mount_target() {
  local target="$1"
  [ -n "${target}" ] || return 0
  contains_item "${target}" "${MOUNT_TARGETS[@]}" || MOUNT_TARGETS+=("${target}")
}

add_runner() {
  local pid="$1"
  [ -n "${pid}" ] || return 0
  contains_item "${pid}" "${TEST_RUNNERS[@]}" || TEST_RUNNERS+=("${pid}")
}

signal_process() {
  local signal="$1"
  local pid="$2"
  kill "-${signal}" "${pid}" 2>/dev/null || sudo -n kill "-${signal}" "${pid}" 2>/dev/null
}

ensure_privileged_cleanup() {
  if [ "${PRIVILEGED_CHECKED}" -eq 1 ]; then
    [ "${PRIVILEGED_AVAILABLE}" -eq 1 ]
    return
  fi
  PRIVILEGED_CHECKED=1
  if [ "${EUID}" -eq 0 ] || { command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; }; then
    PRIVILEGED_AVAILABLE=1
    return 0
  fi
  CLEANUP_FAILURE=1
  log "[WARNING] Root access is required to clean test mounts or loop devices, but non-interactive sudo is unavailable. Run 'sudo -v' in this terminal, then retry './run-ab-test.sh cleanall'. Do not run the full A/B test with sudo."
  return 1
}

run_privileged() {
  if [ "${EUID}" -eq 0 ]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

runner_is_test_owned() {
  local pid="$1"
  local cmdline
  local cwd
  [ -d "/proc/${pid}" ] || return 1
  cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
  [ "${cwd}" = "${PROJECT_DIR}" ] || return 1
  case "${cmdline}" in
    *run-ab-test.sh*|*run-backup-boot-test.sh*) return 0 ;;
  esac
  return 1
}

collect_test_runners() {
  local pid_file pid expected_start actual_start

  # PID records make cleanup precise and also protect against PID reuse.
  while read -r pid_file; do
    [ -f "${pid_file}" ] || continue
    pid=""
    expected_start=""
    read -r pid expected_start < "${pid_file}" || true
    if [[ "${pid:-}" =~ ^[0-9]+$ ]] && runner_is_test_owned "${pid}"; then
      if [ -n "${expected_start:-}" ]; then
        actual_start="$(awk '{ print $22 }' "/proc/${pid}/stat" 2>/dev/null || true)"
        [ "${actual_start}" = "${expected_start}" ] || continue
      fi
      add_runner "${pid}"
    else
      rm -f "${pid_file}"
    fi
  done < <(find "${ARTIFACT_DIR}" -type f -name 'run-*.pid' -print 2>/dev/null || true)

  # Also find runs created before PID records were introduced.
  while read -r pid; do
    runner_is_test_owned "${pid}" && add_runner "${pid}"
  done < <(pgrep -f 'run-(ab-test|backup-boot-test)\.sh' 2>/dev/null || true)
}

stop_test_runners() {
  local pid cmdline attempt still_running
  collect_test_runners
  for pid in "${TEST_RUNNERS[@]}"; do
    [ -d "/proc/${pid}" ] || continue
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    log "Stopping test runner ${pid}: ${cmdline}"
    if ! signal_process TERM "${pid}"; then
      CLEANUP_FAILURE=1
      log "[WARNING] Could not send TERM to test runner ${pid}"
    fi
  done

  for attempt in 1 2 3 4 5; do
    still_running=0
    for pid in "${TEST_RUNNERS[@]}"; do
      if kill -0 "${pid}" 2>/dev/null; then
        still_running=1
        break
      fi
    done
    [ "${still_running}" -eq 0 ] && return 0
    sleep 1
  done

  for pid in "${TEST_RUNNERS[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      log "Force-stopping test runner ${pid}"
      if ! signal_process KILL "${pid}"; then
        CLEANUP_FAILURE=1
        log "[WARNING] Could not send KILL to test runner ${pid}"
      fi
    fi
  done
  for pid in "${TEST_RUNNERS[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      CLEANUP_FAILURE=1
      log "[WARNING] Test runner ${pid} remains after cleanup"
    fi
  done
}

test_qemu_pid() {
  local pid="$1"
  local cmdline
  [ -d "/proc/${pid}" ] || return 1
  cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  case "${cmdline}" in
    *qemu-system-aarch64*)
      case "${cmdline}" in
        *"${PROJECT_DIR}"*|*"${CACHE_DIR}"*|*"hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

test_qemu_pids() {
  local pid
  while read -r pid; do
    test_qemu_pid "${pid}" && printf '%s\n' "${pid}"
  done < <(pgrep -x qemu-system-aarch64 2>/dev/null || true)
}

stop_test_qemu() {
  local pid cmdline
  # Terminate only QEMU processes that can be tied to this test workspace or port.
  while read -r pid; do
    [ -d "/proc/${pid}" ] || continue
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    log "Stopping QEMU process ${pid}: ${cmdline}"
    if ! signal_process TERM "${pid}"; then
      CLEANUP_FAILURE=1
      log "[WARNING] Could not send TERM to QEMU process ${pid}"
    fi
  done < <(test_qemu_pids)

  # Give a terminated guest a short grace period before checking for leftovers.
  local attempt
  for attempt in 1 2 3 4 5; do
    local still_running=0
    while read -r pid; do
      if kill -0 "${pid}" 2>/dev/null; then
        still_running=1
        break
      fi
    done < <(test_qemu_pids)
    [ "${still_running}" -eq 0 ] && return 0
    sleep 1
  done

  # A stuck guest can retain mounts, so force-stop only the same identified processes.
  while read -r pid; do
    kill -0 "${pid}" 2>/dev/null || continue
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    log "Force-stopping QEMU process ${pid}: ${cmdline}"
    if ! signal_process KILL "${pid}"; then
      CLEANUP_FAILURE=1
      log "[WARNING] Could not send KILL to QEMU process ${pid}"
    fi
  done < <(test_qemu_pids)
  while read -r pid; do
    CLEANUP_FAILURE=1
    log "[WARNING] QEMU process ${pid} remains after cleanup"
  done < <(test_qemu_pids)
}

collect_test_loops() {
  local loop backing_file
  # Loop devices backed by the prepared cache are test-owned and safe to detach later.
  while read -r loop backing_file; do
    loop="${loop%:}"
    case "${backing_file}" in
      "${CACHE_DIR}"/*|*"/tests/ab/cache/"*|*" (deleted)")
        add_loop "${loop}"
        ;;
    esac
  done < <(losetup --list --noheadings --output NAME,BACK-FILE 2>/dev/null || true)
}

collect_mounts() {
  local target source loop partition
  # Collect known temporary mounts and anything attached to the test loop partitions.
  while read -r target source; do
    case "${target}:${source}" in
      /tmp/tmp.*:*|/media/*/bootfs:/dev/loop*|/media/*/rootfs:/dev/loop*)
        add_mount_target "${target}"
        ;;
    esac
  done < <(findmnt -rn -o TARGET,SOURCE 2>/dev/null || true)

  for loop in "${TEST_LOOPS[@]}"; do
    for partition in "${loop}" "${loop}p1" "${loop}p2"; do
      while read -r target; do
        add_mount_target "${target}"
      done < <(findmnt -rn -S "${partition}" -o TARGET 2>/dev/null || true)
    done
  done
}

unmount_test_mounts() {
  local target
  [ "${#MOUNT_TARGETS[@]}" -gt 0 ] || return 0
  ensure_privileged_cleanup || return 0
  # Unmount deepest paths first so nested mounts do not block their parents.
  while read -r target; do
    [ -n "${target}" ] || continue
    log "Unmounting ${target}"
    run_privileged umount --recursive "${target}" 2>/dev/null || \
      run_privileged umount --lazy "${target}" 2>/dev/null || {
        CLEANUP_FAILURE=1
        log "[WARNING] Could not unmount ${target}"
      }
  done < <(printf '%s\n' "${MOUNT_TARGETS[@]}" | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)
}

detach_test_loops() {
  local loop
  [ "${#TEST_LOOPS[@]}" -gt 0 ] || return 0
  ensure_privileged_cleanup || return 0
  # Detach loops after mounts are gone, then wait for udev to finish device cleanup.
  for loop in "${TEST_LOOPS[@]}"; do
    log "Detaching ${loop}"
    if ! run_privileged losetup --detach "${loop}" 2>/dev/null; then
      CLEANUP_FAILURE=1
      log "[WARNING] Could not detach ${loop}"
    fi
  done
  if command -v udevadm >/dev/null 2>&1; then
    run_privileged udevadm settle 2>/dev/null || true
  fi
  for loop in "${TEST_LOOPS[@]}"; do
    if losetup "${loop}" >/dev/null 2>&1; then
      log "Loop device still marked autoclear; no mount remains: ${loop}"
    fi
  done
}

clear_artifacts() {
  # Only cleanall may remove results, and only below the repository artifact directory.
  [ "${ACTION}" = "cleanall" ] || {
    log "Keeping test results under ${ARTIFACT_DIR}"
    return 0
  }
  case "${ARTIFACT_DIR}" in
    "${PROJECT_DIR}/tests/ab/artifacts"|"${PROJECT_DIR}/tests/ab/artifacts/"*)
      log "Removing all test results below ${ARTIFACT_DIR}"
      find "${ARTIFACT_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
      ;;
    *)
      log "Leaving custom artifact path untouched: ${ARTIFACT_DIR}"
      ;;
  esac
}

# Cleanup order matters: stop guests before discovering and detaching their resources.
log "Preserving cache: ${CACHE_DIR}"
stop_test_runners
stop_test_qemu
report_ssh_port
collect_test_loops
collect_mounts
unmount_test_mounts
detach_test_loops
if [ "${CLEANUP_FAILURE}" -eq 0 ]; then
  clear_artifacts
  log "Cleanup complete; cache was not modified"
else
  log "[WARNING] Cleanup could not release all test resources; retained artifacts were not removed"
  exit 1
fi