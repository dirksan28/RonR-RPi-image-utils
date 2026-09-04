#!/bin/bash
set -u

CONFIG_FILE="${1:-}"
ACTION="${2:-cleanup}"
[ -n "${CONFIG_FILE}" ] && [ -f "${CONFIG_FILE}" ] || {
  echo "Usage: $0 CONFIG_FILE" >&2
  exit 2
}
CONFIG_FILE="$(readlink -f "${CONFIG_FILE}")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_DIR}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

CACHE_DIR="${PREPARED_CACHE_DIR:-${PROJECT_DIR}/tests/ab/cache}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${PROJECT_DIR}/tests/ab/artifacts}"
SSH_PORT="${SSH_PORT:-2222}"

log() {
  printf '[cleanup] %s\n' "$*"
}

declare -a TEST_LOOPS=()
declare -a MOUNT_TARGETS=()

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

stop_test_qemu() {
  local pid cmdline
  while read -r pid; do
    [ -d "/proc/${pid}" ] || continue
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    case "${cmdline}" in
      *qemu-system-aarch64*)
        case "${cmdline}" in
          *"${PROJECT_DIR}"*|*"${CACHE_DIR}"*|*"hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"*)
            log "Stopping QEMU process ${pid}"
            sudo kill -TERM "${pid}" 2>/dev/null || true
            ;;
        esac
        ;;
    esac
  done < <(pgrep -x qemu-system-aarch64 2>/dev/null || true)

  local attempt
  for attempt in 1 2 3 4 5; do
    local still_running=0
    while read -r pid; do
      if kill -0 "${pid}" 2>/dev/null; then
        still_running=1
        break
      fi
    done < <(pgrep -x qemu-system-aarch64 2>/dev/null || true)
    [ "${still_running}" -eq 0 ] && return 0
    sleep 1
  done

  while read -r pid; do
    [ -d "/proc/${pid}" ] || continue
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    case "${cmdline}" in
      *"${PROJECT_DIR}"*|*"${CACHE_DIR}"*|*"hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"*)
        log "Force-stopping QEMU process ${pid}"
        sudo kill -KILL "${pid}" 2>/dev/null || true
        ;;
    esac
  done < <(pgrep -x qemu-system-aarch64 2>/dev/null || true)
}

collect_test_loops() {
  local loop backing_file
  while read -r loop backing_file; do
    loop="${loop%:}"
    case "${backing_file}" in
      "${CACHE_DIR}"/*|*"/tests/ab/cache/"*|*" (deleted)")
        add_loop "${loop}"
        ;;
    esac
  done < <(sudo losetup --list --noheadings --output NAME,BACK-FILE 2>/dev/null || true)
}

collect_mounts() {
  local target source loop partition
  while read -r target source; do
    case "${target}:${source}" in
      /tmp/tmp.*:*|/media/*/bootfs:/dev/loop*|/media/*/rootfs:/dev/loop*)
        add_mount_target "${target}"
        ;;
    esac
  done < <(sudo findmnt -rn -o TARGET,SOURCE 2>/dev/null || true)

  for loop in "${TEST_LOOPS[@]}"; do
    for partition in "${loop}" "${loop}p1" "${loop}p2"; do
      while read -r target; do
        add_mount_target "${target}"
      done < <(sudo findmnt -rn -S "${partition}" -o TARGET 2>/dev/null || true)
    done
  done
}

unmount_test_mounts() {
  local target
  while read -r target; do
    [ -n "${target}" ] || continue
    log "Unmounting ${target}"
    sudo umount --recursive "${target}" 2>/dev/null || \
      sudo umount --lazy "${target}" 2>/dev/null || true
  done < <(printf '%s\n' "${MOUNT_TARGETS[@]}" | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-)
}

detach_test_loops() {
  local loop
  for loop in "${TEST_LOOPS[@]}"; do
    log "Detaching ${loop}"
    sudo losetup --detach "${loop}" 2>/dev/null || true
  done
  if command -v udevadm >/dev/null 2>&1; then
    sudo udevadm settle 2>/dev/null || true
  fi
  for loop in "${TEST_LOOPS[@]}"; do
    if sudo losetup "${loop}" >/dev/null 2>&1; then
      log "Loop device still marked autoclear; no mount remains: ${loop}"
    fi
  done
}

clear_artifacts() {
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

log "Preserving cache: ${CACHE_DIR}"
stop_test_qemu
collect_test_loops
collect_mounts
unmount_test_mounts
detach_test_loops
clear_artifacts
log "Cleanup complete; cache was not modified"