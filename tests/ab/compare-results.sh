#!/bin/bash
set -euo pipefail

UPSTREAM_DIR="${1:-}"
LOCAL_DIR="${2:-}"
[ -d "${UPSTREAM_DIR}" ] && [ -d "${LOCAL_DIR}" ] || {
  echo "Usage: $0 UPSTREAM_RESULT_DIR LOCAL_RESULT_DIR" >&2
  exit 2
}

status=0
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
  trap 'rm -f "${upstream_manifest}" "${local_manifest}"' EXIT

  grep -Ev '^opt/image-backup-ab-fixtures/(bind-target|external-link)(/|\t)' \
    "${UPSTREAM_DIR}/root.manifest" > "${upstream_manifest}"
  grep -Ev '^opt/image-backup-ab-fixtures/(bind-target|external-link)(/|\t)' \
    "${LOCAL_DIR}/root.manifest" > "${local_manifest}"
  if ! diff -u "${upstream_manifest}" "${local_manifest}"; then
    status=1
  fi
}

compare_root_manifests
compare_file boot.manifest
compare_file partition-table.normalized.txt

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
