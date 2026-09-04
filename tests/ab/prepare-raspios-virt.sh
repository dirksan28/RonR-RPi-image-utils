#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${1:-}"
[ -n "${CONFIG_FILE}" ] && [ -f "${CONFIG_FILE}" ] || {
  echo "Usage: $0 CONFIG_FILE" >&2
  exit 2
}
# shellcheck source=/dev/null
cd "${PROJECT_DIR}"
source "${CONFIG_FILE}"
export LANG=C
export LANGUAGE=C
export LC_ALL=C

log_message() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

for required in BASE_IMAGE_SHA256 KERNEL_DEB_SHA256 PREPARED_CACHE_DIR BASE_IMAGE_ARCHIVE BASE_IMAGE_RAW PREPARED_IMAGE KERNEL_IMAGE INITRAMFS_IMAGE PREPARED_EXTRA_GB GUEST_USER SSH_PRIVATE_KEY SSH_PUBLIC_KEY; do
  [ -n "${!required:-}" ] || { echo "Missing ${required} in ${CONFIG_FILE}" >&2; exit 2; }
done
for command in curl sha256sum xz qemu-img qemu-aarch64-static dpkg-deb ssh-keygen losetup mount umount chroot sfdisk e2fsck resize2fs truncate; do
  command -v "${command}" >/dev/null || { echo "Missing host command: ${command}" >&2; exit 1; }
done
umask 077
log_message "[INFO] prepare: checking isolated SSH key"
mkdir -p "$(dirname "${SSH_PRIVATE_KEY}")"
if [ -e "${SSH_PRIVATE_KEY}" ] && [ ! -f "${SSH_PUBLIC_KEY}" ]; then
  echo "SSH private key exists without matching public key: ${SSH_PRIVATE_KEY}" >&2
  exit 1
fi
if [ ! -e "${SSH_PRIVATE_KEY}" ] && [ -e "${SSH_PUBLIC_KEY}" ]; then
  echo "SSH public key exists without matching private key: ${SSH_PUBLIC_KEY}" >&2
  exit 1
fi
if [ ! -e "${SSH_PRIVATE_KEY}" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "${SSH_PRIVATE_KEY}"
fi
ssh-keygen -y -f "${SSH_PRIVATE_KEY}" > "${SSH_PUBLIC_KEY}.actual"
if [ -f "${SSH_PUBLIC_KEY}" ] && ! cmp -s "${SSH_PUBLIC_KEY}.actual" "${SSH_PUBLIC_KEY}"; then
  rm -f "${SSH_PUBLIC_KEY}.actual"
  echo "SSH public key does not match private key: ${SSH_PUBLIC_KEY}" >&2
  exit 1
fi
mv "${SSH_PUBLIC_KEY}.actual" "${SSH_PUBLIC_KEY}"
SSH_PUBLIC_KEY_SHA256="$(sha256sum "${SSH_PUBLIC_KEY}")"
SSH_PUBLIC_KEY_SHA256="${SSH_PUBLIC_KEY_SHA256%% *}"

mkdir -p "${PREPARED_CACHE_DIR}"
SOURCE_IMAGE="${BASE_IMAGE:-${BASE_IMAGE_RAW}}"
SOURCE_KERNEL_DEB="${KERNEL_DEB:-${PREPARED_CACHE_DIR}/linux-image-arm64.deb}"
MANIFEST_FILE="${PREPARED_CACHE_DIR}/prepared.manifest"
PREPARATION_VERSION=5

fetch_artifact() {
  local destination="$1"
  local url="$2"
  local checksum="$3"

  if [ ! -f "${destination}" ]; then
    log_message "[INFO] prepare: downloading $(basename "${destination}")"
    case "${url}" in
      ""|*example.invalid*)
        echo "Missing local artifact ${destination} and no usable download URL was configured." >&2
        exit 2
        ;;
    esac
    curl --fail --location --retry 3 --output "${destination}.partial" "${url}"
    mv "${destination}.partial" "${destination}"
  fi
  log_message "[INFO] prepare: verifying $(basename "${destination}")"
  echo "${checksum}  ${destination}" | sha256sum -c -
}

fetch_artifact "${BASE_IMAGE_ARCHIVE}" "${BASE_IMAGE_URL:-}" "${BASE_IMAGE_SHA256}"
if [ -z "${BASE_IMAGE}" ]; then
  log_message "[INFO] prepare: validating and expanding Raspberry Pi OS archive"
  xz -t "${BASE_IMAGE_ARCHIVE}"
  if [ ! -f "${BASE_IMAGE_RAW}" ]; then
    xz -dc "${BASE_IMAGE_ARCHIVE}" > "${BASE_IMAGE_RAW}.partial"
    mv "${BASE_IMAGE_RAW}.partial" "${BASE_IMAGE_RAW}"
  fi
fi
fetch_artifact "${SOURCE_KERNEL_DEB}" "${KERNEL_DEB_URL:-}" "${KERNEL_DEB_SHA256}"
log_message "[INFO] prepare: validating kernel package"
[ "$(dpkg-deb -f "${SOURCE_KERNEL_DEB}" Architecture)" = "arm64" ] || {
  echo "Kernel package is not an arm64 package: ${SOURCE_KERNEL_DEB}" >&2
  exit 1
}

cache_manifest_matches() {
  local expected_field
  for expected_field in \
    "preparation_version=${PREPARATION_VERSION}" \
    "base_image_sha256=${BASE_IMAGE_SHA256}" \
    "kernel_deb_sha256=${KERNEL_DEB_SHA256}" \
    "prepared_extra_gb=${PREPARED_EXTRA_GB}" \
    "guest_user=${GUEST_USER}" \
    "ssh_public_key_sha256=${SSH_PUBLIC_KEY_SHA256}"; do
    grep -Fqx "${expected_field}" "${MANIFEST_FILE}" || return 1
  done
}

if [ -f "${PREPARED_IMAGE}" ] && [ -f "${KERNEL_IMAGE}" ] && [ -f "${INITRAMFS_IMAGE}" ] && [ -f "${MANIFEST_FILE}" ]; then
  if cache_manifest_matches; then
    log_message "[INFO] prepare: reusing prepared guest cache"
    exit 0
  fi
fi

rm -f "${PREPARED_IMAGE}" "${KERNEL_IMAGE}" "${INITRAMFS_IMAGE}" "${MANIFEST_FILE}"
log_message "[INFO] prepare: creating expanded prepared image"
cp --reflink=auto "${SOURCE_IMAGE}" "${PREPARED_IMAGE}"
truncate -s "+${PREPARED_EXTRA_GB}G" "${PREPARED_IMAGE}"
echo ',+' | sudo sfdisk -N 2 "${PREPARED_IMAGE}" > /dev/null

KERNEL_STAGE="$(mktemp -d)"
ROOT_MOUNT="$(mktemp -d)"
LOOP_DEVICE=""
cleanup() {
  mountpoint -q "${ROOT_MOUNT}" && sudo umount --recursive "${ROOT_MOUNT}" || true
  if [ -n "${LOOP_DEVICE}" ]; then
    while read -r mount_target; do
      [ -n "${mount_target}" ] && sudo umount --recursive "${mount_target}" || true
    done < <(findmnt -rn -S "${LOOP_DEVICE}p1" -o TARGET 2>/dev/null || true)
    sudo losetup -d "${LOOP_DEVICE}" || true
  fi
  rm -rf "${KERNEL_STAGE}" "${ROOT_MOUNT}"
}
trap cleanup EXIT

dpkg-deb -x "${SOURCE_KERNEL_DEB}" "${KERNEL_STAGE}"
KERNEL_PATH="$(find "${KERNEL_STAGE}/boot" -maxdepth 1 -type f -name 'vmlinuz-*' -print -quit)"
[ -n "${KERNEL_PATH}" ] || { echo "Kernel package does not contain boot/vmlinuz-*" >&2; exit 1; }
KERNEL_VERSION="$(basename "${KERNEL_PATH}")"
KERNEL_VERSION="${KERNEL_VERSION#vmlinuz-}"

LOOP_DEVICE="$(sudo losetup --find --show --partscan "${PREPARED_IMAGE}")"
log_message "[INFO] prepare: growing prepared root filesystem"
sudo e2fsck -pf "${LOOP_DEVICE}p2"
sudo resize2fs "${LOOP_DEVICE}p2"
sudo mount "${LOOP_DEVICE}p2" "${ROOT_MOUNT}"
sudo mount -t proc proc "${ROOT_MOUNT}/proc"
sudo mount --rbind /sys "${ROOT_MOUNT}/sys"
sudo mount --make-rslave "${ROOT_MOUNT}/sys"
sudo mount --rbind /dev "${ROOT_MOUNT}/dev"
sudo mount --make-rslave "${ROOT_MOUNT}/dev"
sudo install -m 755 "$(command -v qemu-aarch64-static)" "${ROOT_MOUNT}/usr/bin/qemu-aarch64-static"
sudo install -m 644 "${SOURCE_KERNEL_DEB}" "${ROOT_MOUNT}/tmp/$(basename "${SOURCE_KERNEL_DEB}")"
sudo install -m 644 "${SSH_PUBLIC_KEY}" "${ROOT_MOUNT}/tmp/$(basename "${SSH_PUBLIC_KEY}")"
sudo rm -f "${ROOT_MOUNT}/etc/resolv.conf"
sudo cp /etc/resolv.conf "${ROOT_MOUNT}/etc/resolv.conf"

log_message "[INFO] prepare: provisioning ARM guest packages and SSH"
sudo chroot "${ROOT_MOUNT}" /usr/bin/qemu-aarch64-static /bin/bash -ceu "
  export LANG=C
  export LANGUAGE=C
  export LC_ALL=C
  export DEBIAN_FRONTEND=noninteractive
  for architecture in \$(dpkg --print-foreign-architectures); do
    dpkg --remove-architecture \"\${architecture}\"
  done
  cat > /etc/apt/apt.conf.d/99image-backup-ab <<'EOF'
APT::Architecture \"arm64\";
APT::Architectures { \"arm64\"; };
Acquire::Languages \"none\";
EOF
  printf 'LANG=C\\nLANGUAGE=C\\nLC_ALL=C\\n' > /etc/default/locale
  rm -rf /var/lib/apt/lists/*
  apt-get update
  apt-get install -y initramfs-tools linux-base kmod openssh-server sudo rsync gdisk dosfstools e2fsprogs util-linux f2fs-tools
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  dpkg -i /tmp/$(basename "${SOURCE_KERNEL_DEB}")
  cat > /etc/initramfs-tools/modules <<'EOF'
virtio
virtio_ring
virtio_pci
virtio_blk
virtio_net
ext4
EOF
  update-initramfs -u -k ${KERNEL_VERSION}
  id -u ${GUEST_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${GUEST_USER}
  usermod -s /bin/bash ${GUEST_USER}
  install -d -m 700 -o ${GUEST_USER} -g ${GUEST_USER} /home/${GUEST_USER}/.ssh
  install -m 600 -o ${GUEST_USER} -g ${GUEST_USER} /tmp/$(basename "${SSH_PUBLIC_KEY}") /home/${GUEST_USER}/.ssh/authorized_keys
  printf '${GUEST_USER} ALL=(ALL) NOPASSWD: ALL\\n' > /etc/sudoers.d/image-backup-ab
  chmod 440 /etc/sudoers.d/image-backup-ab
  ssh-keygen -A
  systemctl enable ssh
  printf 'preparation_version=%s\\nbase_image_sha256=%s\\nkernel_deb_sha256=%s\\nkernel_version=%s\\nprepared_extra_gb=%s\\nguest_user=%s\\nssh_public_key_sha256=%s\\n' '${PREPARATION_VERSION}' '${BASE_IMAGE_SHA256}' '${KERNEL_DEB_SHA256}' '${KERNEL_VERSION}' '${PREPARED_EXTRA_GB}' '${GUEST_USER}' '${SSH_PUBLIC_KEY_SHA256}' > /etc/image-backup-ab-manifest
"

sudo install -m 644 "${ROOT_MOUNT}/boot/vmlinuz-${KERNEL_VERSION}" "${KERNEL_IMAGE}"
sudo install -m 644 "${ROOT_MOUNT}/boot/initrd.img-${KERNEL_VERSION}" "${INITRAMFS_IMAGE}"
sudo chown "$(id -u):$(id -g)" "${KERNEL_IMAGE}" "${INITRAMFS_IMAGE}"
printf 'preparation_version=%s\nbase_image_sha256=%s\nkernel_deb_sha256=%s\nkernel_version=%s\nprepared_extra_gb=%s\nguest_user=%s\nssh_public_key_sha256=%s\n' "${PREPARATION_VERSION}" "${BASE_IMAGE_SHA256}" "${KERNEL_DEB_SHA256}" "${KERNEL_VERSION}" "${PREPARED_EXTRA_GB}" "${GUEST_USER}" "${SSH_PUBLIC_KEY_SHA256}" > "${MANIFEST_FILE}"
log_message "[PASS] prepare: prepared guest image ready: ${PREPARED_IMAGE}"
