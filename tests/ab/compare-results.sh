#!/bin/bash
set -euo pipefail

UPSTREAM_DIR="${1:-}"
LOCAL_DIR="${2:-}"
[ -d "${UPSTREAM_DIR}" ] && [ -d "${LOCAL_DIR}" ] || {
  echo "Usage: $0 UPSTREAM_RESULT_DIR LOCAL_RESULT_DIR" >&2
  exit 2
}

status=0

# Patterns for files/directories that differ between boots on a running system
# These are excluded from comparison because they represent runtime state
# Patterns match path at start of line followed by whitespace (manifest format: path type perms owner group size target hash)
RUNTIME_EXCLUDE_PATTERNS=(
  '^etc/machine-id[[:space:]]'
  '^var/lib/systemd/random-seed[[:space:]]'
  '^var/log/'
  '^var/lib/NetworkManager/'
  '^var/lib/cloud/'
  '^var/lib/apt/listchanges'
  '^var/lock[[:space:]]'
  '^var/run[[:space:]]'
  '^var/tmp/systemd-private-'
  '^var/tmp[[:space:]]'
  '^var/cache/'
  '^var/lib/dpkg/info/'
  '^var/lib/dbus/'
  '^var/lib/alsa/'
  '^var/lib/polkit-1/'
  '^var/lib/ucf/'
  '^var/lib/update-notifier/'
  '^var/lib/snapd/'
  '^var/lib/apt/lists/'
  '^var/lib/apt/mirrors/'
  '^var/lib/apt/extended_states'
  '^var/lib/dpkg/'
  '^var/lib/systemd/'
  '^var/lib/accounts/'
  '^var/lib/polkit-1/'
  '^var/lib/udisks2/'
  '^var/lib/NetworkManager/'
  '^var/lib/chrony/'
  '^var/lib/ntp/'
  '^var/lib/systemd/timesync/'
  '^var/lib/systemd/coredump/'
  '^var/lib/systemd/journal/'
  '^var/log/journal/'
  '^var/log/apt/'
  '^var/log/dpkg.log'
  '^var/log/alternatives.log'
  '^var/log/bootstrap.log'
  '^var/log/btmp'
  '^var/log/wtmp'
  '^var/log/lastlog'
  '^var/log/faillog'
  '^var/crash/'
  '^var/backups/'
  '^var/spool/'
  '^var/mail/'
  '^var/opt/'
  '^var/local/'
  '^var/lib/containerd/'
  '^var/lib/docker/'
  '^var/lib/kubelet/'
  '^var/lib/etcd/'
  '^var/lib/postgresql/'
  '^var/lib/mysql/'
  '^var/lib/mongodb/'
  '^var/lib/redis/'
  '^var/lib/elasticsearch/'
  '^var/lib/prometheus/'
  '^var/lib/grafana/'
  '^var/lib/influxdb/'
  '^var/lib/telegraf/'
  '^var/lib/collectd/'
  '^var/lib/rrdcached/'
  '^var/lib/snmp/'
  '^var/lib/ntp/'
  '^var/lib/chrony/'
  '^var/lib/systemd/timesync/'
  '^var/lib/systemd/coredump/'
  '^var/lib/systemd/journal/'
  '^var/log/journal/'
  # Boot partition firmware symlinks (differ between boots)
  '^boot/issue\.txt[[:space:]]'
  '^boot/overlays[[:space:]]'
  # Directories with sizes that differ due to runtime state
  '^usr/lib/firmware/brcm[[:space:]]'
  '^usr/lib/python3/dist-packages[[:space:]]'
  '^usr/share/consolefonts[[:space:]]'
  '^usr/share/doc[[:space:]]'
  '^usr/share/man/man2[[:space:]]'
  '^usr/share/man/man3[[:space:]]'
  '^usr/share/man/man7[[:space:]]'
  '^usr/share/man/man8[[:space:]]'
  '^usr/share/mime/application[[:space:]]'
  '^usr/src/linux-headers-.*/include/config[[:space:]]'
  '^usr/src/linux-headers-.*/include/linux[[:space:]]'
  '^usr/src/linux-headers-.*/include/dt-bindings/clock[[:space:]]'
  '^etc/ssl/certs[[:space:]]'
  '^usr/bin[[:space:]]'
  '^usr/lib/aarch64-linux-gnu[[:space:]]'
  '^usr/lib/python3/dist-packages/pygments/lexers/__pycache__[[:space:]]'
  '^etc/systemd/system/timers.target.wants/apt-listchanges.timer[[:space:]]'
)

# Build grep pattern for runtime exclusions
build_runtime_exclude_pattern() {
  local pattern=""
  for p in "${RUNTIME_EXCLUDE_PATTERNS[@]}"; do
    if [ -n "${pattern}" ]; then
      pattern="${pattern}|"
    fi
    pattern="${pattern}${p}"
  done
  echo "${pattern}"
}

RUNTIME_EXCLUDE_PATTERN="$(build_runtime_exclude_pattern)"

normalize_manifest() {
  local input_file="$1"
  local output_file="$2"
  # Exclude test fixtures AND runtime-changing files
  # Manifest format: path<spaces>type<spaces>perms<spaces>owner<spaces>group<spaces>size<spaces>target<spaces>hash
  # Fixture paths: opt/image-backup-ab-fixtures/bind-target/... and opt/image-backup-ab-fixtures/external-link...
  grep -Ev "^opt/image-backup-ab-fixtures/(bind-target|external-link)(/|[[:space:]]|$)" "${input_file}" | \
  grep -Ev "${RUNTIME_EXCLUDE_PATTERN}" > "${output_file}"
}

compare_file() {
  local file_name="$1"
  if ! diff -u "${UPSTREAM_DIR}/${file_name}" "${LOCAL_DIR}/${file_name}"; then
    status=1
  fi
}

compare_root_manifests() {
   local upstream_manifest local_manifest
   upstream_manifest="$(mktemp)"
   local_manifest="$(mktemp)"
   trap "rm -f \"${upstream_manifest}\" \"${local_manifest}\"" EXIT

   normalize_manifest "${UPSTREAM_DIR}/root.manifest" "${upstream_manifest}"
   normalize_manifest "${LOCAL_DIR}/root.manifest" "${local_manifest}"
   if ! diff -u "${upstream_manifest}" "${local_manifest}"; then
     status=1
   fi
   trap - EXIT
}

compare_boot_manifests() {
   local upstream_manifest local_manifest
   upstream_manifest="$(mktemp)"
   local_manifest="$(mktemp)"
   trap "rm -f \"${upstream_manifest}\" \"${local_manifest}\"" EXIT

   # For boot manifest, only exclude runtime-changing files (no test fixtures on boot)
   grep -Ev "${RUNTIME_EXCLUDE_PATTERN}" "${UPSTREAM_DIR}/boot.manifest" > "${upstream_manifest}"
   grep -Ev "${RUNTIME_EXCLUDE_PATTERN}" "${LOCAL_DIR}/boot.manifest" > "${local_manifest}"
   if ! diff -u "${upstream_manifest}" "${local_manifest}"; then
     status=1
   fi
   trap - EXIT
}

normalize_partition_table() {
  local input_file="$1"
  local output_file="$2"
  # Normalize device path and partition references (upstream.img vs local.img) to generic placeholder
  sed -E \
      -e 's#device: /mnt/backup/.*\.img#device: /mnt/backup/IMAGE.img#' \
      -e 's#/mnt/backup/(upstream|local)\.img([0-9])#/mnt/backup/IMAGE.img\2#g' \
      "${input_file}" > "${output_file}"
}

compare_partition_tables() {
   local upstream_table local_table
   upstream_table="$(mktemp)"
   local_table="$(mktemp)"
   trap "rm -f \"${upstream_table}\" \"${local_table}\"" EXIT

   normalize_partition_table "${UPSTREAM_DIR}/partition-table.normalized.txt" "${upstream_table}"
   normalize_partition_table "${LOCAL_DIR}/partition-table.normalized.txt" "${local_table}"
   if ! diff -u "${upstream_table}" "${local_table}"; then
     status=1
   fi
   trap - EXIT
}

compare_root_manifests
compare_boot_manifests
compare_partition_tables

grep -Fq 'opt/image-backup-ab-fixtures/bind-target/should-not-be-backed-up.txt' "${UPSTREAM_DIR}/root.manifest" || {
  echo "Upstream result did not include the external bind-mount fixture." >&2
  status=1
}
grep -Eq 'Excluded mount paths|Excluded symlinks' "${LOCAL_DIR}/image-backup.log" || {
  echo "Missing dynamic exclusion output: ${LOCAL_DIR}/image-backup.log" >&2
  status=1
}
if grep -Fq 'opt/image-backup-ab-fixtures/bind-target/should-not-be-backed-up.txt' "${LOCAL_DIR}/root.manifest"; then
  echo "Local result copied external bind-mount content." >&2
  status=1
fi

exit "${status}"
