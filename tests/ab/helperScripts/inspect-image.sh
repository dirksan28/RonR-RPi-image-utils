#!/bin/bash
set -euo pipefail

IMAGE_FILE="${1:-}"
OUTPUT_DIR="${2:-}"
[ -n "${IMAGE_FILE}" ] && [ -n "${OUTPUT_DIR}" ] || { echo "Usage: $0 IMAGE_FILE OUTPUT_DIR" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "Must run as root" >&2; exit 1; }

progress_message() {
  printf '[%s] [INFO] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

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

manifest() (
  local mount_dir="$1"
  local output_file="$2"
  local filesystem_name="$3"
  local entry relative_path entry_type file_type filesystem_type mode uid gid size
  local metadata checksum link_target hash_record hash_path hash_value
  local hash_cache="" hash_worker_dir="" metadata_cache="" manifest_unsorted=""
  local hash_jobs hash_worker_file
  local hash_worker_files=()
  local entry_count=0
  local regular_file_count=0
  local start_time="${SECONDS}"
  local last_report=0
  local last_report_count=0
  local elapsed
  local entries_per_second
  local progress_interval="${INSPECT_PROGRESS_INTERVAL:-30}"
  local progress_entries="${INSPECT_PROGRESS_ENTRIES:-5000}"

  declare -A hash_by_path=()

  cleanup_manifest_files() {
    rm -f -- "${hash_cache}" "${metadata_cache}" "${manifest_unsorted}" || true
    [ -z "${hash_worker_dir}" ] || rm -rf -- "${hash_worker_dir}" || true
  }
  trap cleanup_manifest_files EXIT

  case "${progress_interval}" in
    ''|*[!0-9]*|0) progress_interval=30 ;;
  esac
  case "${progress_entries}" in
    ''|*[!0-9]*|0) progress_entries=5000 ;;
  esac

  hash_jobs="$(nproc)"
  hash_cache="$(mktemp)"
  hash_worker_dir="$(mktemp -d)"
  metadata_cache="$(mktemp)"
  manifest_unsorted="$(mktemp)"
  export HASH_WORKER_DIR="${hash_worker_dir}"

  : > "${output_file}"
  progress_message "inspect ${filesystem_name}: hashing regular files with ${hash_jobs} workers"
  if ! find "${mount_dir}" -xdev -type f -print0 | \
    xargs -0 -r -P "${hash_jobs}" --process-slot-var=HASH_SLOT \
      sh -c 'sha256sum --zero -- "$@" >> "${HASH_WORKER_DIR}/worker.${HASH_SLOT}"' sh; then
    progress_message "inspect ${filesystem_name}: parallel hash calculation failed"
    exit 1
  fi

  shopt -s nullglob
  hash_worker_files=("${hash_worker_dir}"/worker.*)
  shopt -u nullglob
  for hash_worker_file in "${hash_worker_files[@]}"; do
    cat -- "${hash_worker_file}" >> "${hash_cache}"
  done

  while IFS= read -r -d '' hash_record; do
    [ "${#hash_record}" -ge 66 ] || {
      progress_message "inspect ${filesystem_name}: invalid hash cache entry"
      exit 1
    }
    hash_value="${hash_record:0:64}"
    hash_path="${hash_record:66}"
    [[ "${hash_value}" =~ ^[[:xdigit:]]{64}$ ]] || {
      progress_message "inspect ${filesystem_name}: invalid hash cache value"
      exit 1
    }
    hash_by_path["${hash_path}"]="${hash_value}"
  done < "${hash_cache}"

  if ! find "${mount_dir}" -xdev -printf '%p\t%y\t%F\t%m\t%u\t%g\t%s\n' > "${metadata_cache}"; then
    progress_message "inspect ${filesystem_name}: metadata scan failed"
    exit 1
  fi

  progress_message "inspect ${filesystem_name}: starting scan"
  while IFS=$'\t' read -r entry entry_type filesystem_type mode uid gid size; do
    entry_count=$((entry_count + 1))
    relative_path="${entry#${mount_dir}/}"
    [ "${entry}" = "${mount_dir}" ] && relative_path="."
    case "${entry_type}" in
      b) file_type="block special file" ;;
      c) file_type="character special file" ;;
      d) file_type="directory" ;;
      f) file_type="regular file" ;;
      l) file_type="symbolic link" ;;
      p) file_type="fifo" ;;
      s) file_type="socket" ;;
      *) file_type="unknown" ;;
    esac
    metadata="${file_type}"$'\t'"${mode}"$'\t'"${uid}"$'\t'"${gid}"$'\t'"${size}"
    checksum="-"
    link_target="-"
    if [ "${entry_type}" = "f" ]; then
      checksum="${hash_by_path["${entry}"]:-}"
      [ -n "${checksum}" ] || {
        progress_message "inspect ${filesystem_name}: missing hash for ${entry}"
        exit 1
      }
      regular_file_count=$((regular_file_count + 1))
    elif [ "${entry_type}" = "l" ]; then
      link_target="$(readlink -- "${entry}")"
    fi
    printf '%s\t%s\t%s\t%s\n' "${relative_path}" "${metadata}" "${link_target}" "${checksum}"

    elapsed=$((SECONDS - start_time))
    if (( elapsed > 0 )); then
      entries_per_second=$((entry_count / elapsed))
    else
      entries_per_second=0
    fi
    if (( entry_count - last_report_count >= progress_entries )) || \
      (( elapsed - last_report >= progress_interval )); then
      progress_message "inspect ${filesystem_name}: ${entry_count} entries processed, ${regular_file_count} regular files hashed, ${entries_per_second} entries/s, elapsed ${elapsed}s"
      last_report="${elapsed}"
      last_report_count="${entry_count}"
    fi
  done < "${metadata_cache}" > "${manifest_unsorted}"
  LC_ALL=C sort "${manifest_unsorted}" > "${output_file}"
  elapsed=$((SECONDS - start_time))
  progress_message "inspect ${filesystem_name}: completed; ${entry_count} entries processed, ${regular_file_count} regular files hashed, elapsed ${elapsed}s"
)

mkdir -p "${OUTPUT_DIR}"
manifest "${ROOT_MOUNT}" "${OUTPUT_DIR}/root.manifest" root
manifest "${BOOT_MOUNT}" "${OUTPUT_DIR}/boot.manifest" boot
sfdisk --dump "${IMAGE_FILE}" | sed -E '/^label-id:/d; s/, uuid=[^,]+//' > "${OUTPUT_DIR}/partition-table.normalized.txt"
