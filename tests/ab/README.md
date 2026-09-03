# Local QEMU ARM A/B Test

This harness compares the checked-in `image-backup` with a pinned upstream candidate in local QEMU ARM64 Raspberry Pi OS guests. It is manually launched from the development workstation; it does not require physical Raspberry Pi hardware, a remote SSH host, or GitHub Actions workflows.

## Preconditions

The workstation needs Linux, sufficient free disk space for a Raspberry Pi OS image plus two guest overlays, and a user allowed to run QEMU. Install the host dependencies on Debian or Ubuntu:

```bash
sudo apt update
sudo apt install qemu-system-arm qemu-utils libguestfs-tools qemu-user-static \
  openssh-client curl coreutils dpkg
```

This provides `qemu-system-aarch64`, `qemu-img`, libguestfs tools, and `qemu-aarch64-static`.

`prepare` uses `sudo` to attach and mount the disposable image copy, then runs ARM guest commands through `qemu-aarch64-static` in a chroot. The password is requested by the local terminal when required; it is never stored by the harness.

The default configuration downloads and verifies a pinned official Raspberry Pi OS Lite 64-bit archive and a pinned generic ARM64 QEMU `virt` kernel package. The harness generates a dedicated Ed25519 guest SSH key pair; it never uses an existing personal identity.

The harness clones the upstream repository into `tests/ab/cache/upstream-repo` and checks out the SHA configured in `UPSTREAM_REVISION`. The default pin is upstream `master` head `0ee5757f43eca29c581ccb6d7ee8818e6ed2cb98`, resolved on 2026-09-03.

The base image is never modified. The preparation stage creates a cached copy, grows only its root partition by `PREPARED_EXTRA_GB` (default: 2 GB), configures SSH and passwordless `sudo`, installs all `image-backup` dependencies, installs the generic kernel, and verifies the guest boots under QEMU. It limits apt to ARM64 packages and disables translation indexes to keep the prepared image compact. This is a Raspberry Pi OS userspace backup-semantics test; it does not validate Raspberry Pi firmware boot compatibility.

## Getting Started

1. Copy the configuration template:

	```bash
	cp tests/ab/config.example.env tests/ab/config.env
	```

2. Edit `tests/ab/config.env` only when you need a different upstream SHA. The default Pi OS archive, kernel package, upstream repository, and upstream revision are already pinned. Override an image or kernel only together with its SHA-256 checksum.

3. Build and boot-validate the immutable guest cache:

	```bash
	./tests/ab/run-ab-test.sh prepare
	```

4. Start the complete A/B comparison:

	```bash
	./tests/ab/run-ab-test.sh all
	```

`prepare` can be rerun safely. It stores the source archive, expanded image, prepared image, kernel, initramfs, manifest, and generated test key below `tests/ab/cache/`. It reuses the cache only when the configured source-image and kernel-package checksums match its manifest. `preflight`, `initial`, and `all` also run preparation before starting a guest.

The first ARM QEMU boot can take several minutes while Raspberry Pi OS starts its initial services. `SSH_WAIT_SECONDS` defaults to `300`; increase it in `config.env` if the console log shows `ssh.service` starting after that timeout.

The harness ignores the workstation's `~/.ssh/config` and uses only its generated test key for the local `127.0.0.1` QEMU SSH connection. This prevents a workstation `ProxyCommand` or personal SSH identity from affecting the test.

## Commands

```bash
./tests/ab/run-ab-test.sh preflight
./tests/ab/run-ab-test.sh initial
./tests/ab/run-ab-test.sh all
```

For every candidate, the launcher creates an isolated QCOW2 root overlay and a fresh raw virtual disk. The guest formats and mounts that virtual disk at `/mnt/backup`; it is separate from the guest root filesystem. `all` runs initial and incremental cases for upstream and local candidates. Each result is inspected read-only and compared through manifests of paths, type, mode, ownership, file size, symlink target, and regular-file SHA-256 checksums. Filesystem UUIDs and partition label IDs are not compared.

Artifacts are downloaded to the configured `ARTIFACT_DIR` with a UTC timestamp. They include command logs, mount topology, fixture manifests, `image-check` output, partition information, and root/boot manifests.
