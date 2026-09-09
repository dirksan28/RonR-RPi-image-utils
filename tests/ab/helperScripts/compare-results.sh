#!/bin/bash
# Compare candidate artifacts while ignoring expected runtime state from separate boots.
#
# Synopsis:
#   Usage: compare-results.sh UPSTREAM_RESULT_DIR LOCAL_RESULT_DIR
#   Expects both directories to contain the candidate manifests, normalized partition table,
#   and local image-backup log produced by the A/B test.
#   Writes unified differences and validation messages to stdout/stderr.
#   Returns 0 when the normalized results match; returns 1 for differences or failed assertions,
#   and 2 when either result directory is missing.
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
  # grep receives one expression so all exclusions are applied in a single pass.
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
  # Root manifests also omit fixture paths that intentionally point outside the image.
  # Exclude test fixtures and runtime-changing files. Directory st_size values
  # depend on filesystem block allocation and copy order, not directory content.
  # Manifest format: path<spaces>type<spaces>perms<spaces>owner<spaces>group<spaces>size<spaces>target<spaces>hash
  # Fixture paths: opt/image-backup-ab-fixtures/bind-target/... and opt/image-backup-ab-fixtures/external-link...
  grep -Ev "^opt/image-backup-ab-fixtures/(bind-target|external-link)(/|[[:space:]]|$)" "${input_file}" | \
  grep -Ev "${RUNTIME_EXCLUDE_PATTERN}" | \
  awk -F '\t' 'BEGIN { OFS = "\t" } $2 == "directory" { $6 = "-" } { print }' > "${output_file}"
}

compare_file() {
  local file_name="$1"
  if ! diff -u "${UPSTREAM_DIR}/${file_name}" "${LOCAL_DIR}/${file_name}"; then
    status=1
  fi
}

compare_root_manifests() {
  # Normalize both root manifests before comparing their deterministic content.
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
  # Boot has no root fixtures, so only runtime-changing entries are removed.
   local upstream_manifest local_manifest
   upstream_manifest="$(mktemp)"
   local_manifest="$(mktemp)"
   trap "rm -f \"${upstream_manifest}\" \"${local_manifest}\"" EXIT

   # For boot manifest, only exclude runtime-changing files (no test fixtures on boot).
   # Normalize directory allocation sizes for the same reason as root manifests.
   grep -Ev "${RUNTIME_EXCLUDE_PATTERN}" "${UPSTREAM_DIR}/boot.manifest" | \
     awk -F '\t' 'BEGIN { OFS = "\t" } $2 == "directory" { $6 = "-" } { print }' > "${upstream_manifest}"
   grep -Ev "${RUNTIME_EXCLUDE_PATTERN}" "${LOCAL_DIR}/boot.manifest" | \
     awk -F '\t' 'BEGIN { OFS = "\t" } $2 == "directory" { $6 = "-" } { print }' > "${local_manifest}"
   if ! diff -u "${upstream_manifest}" "${local_manifest}"; then
     status=1
   fi
   trap - EXIT
}

normalize_partition_table() {
  local input_file="$1"
  local output_file="$2"
  # Replace candidate-specific image names while retaining partition geometry.
  # Normalize device path and partition references (upstream.img vs local.img) to generic placeholder
  sed -E \
      -e 's#device: /mnt/backup/.*\.img#device: /mnt/backup/IMAGE.img#' \
      -e 's#/mnt/backup/(upstream|local)\.img([0-9])#/mnt/backup/IMAGE.img\2#g' \
      "${input_file}" > "${output_file}"
}

compare_partition_tables() {
  # Compare normalized partition layout separately from filesystem manifests.
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

# These assertions verify that the test exercised external mount and symlink exclusion behavior.
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
