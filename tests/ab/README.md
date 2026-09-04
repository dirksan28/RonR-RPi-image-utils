# Local QEMU ARM64 A/B Test

This harness compares the local modified `image-backup` with a pinned upstream version in disposable ARM64 Raspberry Pi OS guests. It runs locally with QEMU; no physical Raspberry Pi, remote SSH host, GitHub Actions runner, or existing personal SSH key is required.

## Preconditions

The intended host is a 64-bit Linux workstation. The current setup targets an x86_64 Debian/Ubuntu host with:

- at least 4 logical CPUs; 8 are recommended
- at least 4 GB of available RAM; 8 GB are recommended because each guest uses 2 GB
- approximately 40 GB of free disk space for the cached images, temporary guest disks, and retained artifacts
- `sudo` permission for loop devices and filesystem mounts

Install the host dependencies on Debian or Ubuntu:

```bash
sudo apt update
sudo apt install qemu-system-arm qemu-utils libguestfs-tools qemu-user-static \
  openssh-client curl coreutils dpkg
```

The host must provide `qemu-system-aarch64`, `qemu-img`, `virt-customize`, `guestfish`, `qemu-aarch64-static`, `ssh`, `scp`, `curl`, `xz`, and the standard filesystem tools.

## Getting Started

All commands below are run from this directory:

```text
/home/schm/vspython/RonR-RPi-image-utils/tests/ab
```

### 1. Create the local configuration

Copy the template once:

```bash
cp config.example.env config.env
```

The template already contains pinned sources for the Raspberry Pi OS Lite 64-bit image, the generic ARM64 QEMU kernel, and the upstream repository revision. Change `UPSTREAM_REVISION` only when you intentionally want to compare a different upstream commit.

The harness creates and stores its own test-only Ed25519 key pair below `cache/keys/`. Do not copy a personal SSH key into the configuration.

### 2. Prepare the guest cache

Run this once for the current configured image and kernel:

```bash
./run-ab-test.sh prepare
```

`prepare` downloads and verifies the pinned source artifacts, expands and caches the Raspberry Pi OS image, creates a larger disposable prepared image, installs the generic QEMU kernel and test dependencies, injects the generated SSH key, and boot-validates the guest. The APT update/install step runs only when the prepared image is created or invalidated; a matching cache manifest causes the image to be reused without entering the guest chroot or running APT. The first preparation or a rebuild therefore needs internet access for the package repositories, while normal cache reuse does not need APT or guest-network access. It may ask for the host user's `sudo` password. No password is required inside the guest.

The cache is reusable. The large downloads do not need to be repeated unless they are removed or their checksums/configuration change. The cache manifest records the preparation version, source checksums, prepared-image size, guest user, and generated test-key identity. Run `prepare` again after changing the preparation inputs or when you want to rebuild the prepared guest. The harness still separately checks out the pinned upstream revision, which may require repository access when that checkout is not already cached.

Some operations take significant time and may produce no terminal output for a while. In particular, ARM emulation, filesystem checks, `resize2fs`, and image inspection can be slow. Do not assume the run is stuck just because output pauses; for example, `[INFO] upstream/initial: inspecting image contents` may be followed by a long quiet period.

### 3. Run an optional preflight check

```bash
./run-ab-test.sh preflight
```

This reuses the prepared cache, boots one temporary guest, formats and mounts the separate virtual backup disk at `/mnt/backup`, checks the guest tools and loop-device support, then shuts the guest down. It does not run either `image-backup` candidate.

### 4. Run the A/B test

```bash
./run-ab-test.sh all
```

The test runs sequentially to limit host resource usage:

1. A fresh guest runs the pinned upstream script for an initial backup and an incremental backup.
2. That guest is shut down and its artifacts are copied to the run directory.
3. A fresh guest runs the local modified script with the same fixture changes.
4. The initial and incremental results are compared.

Both candidates therefore start from equivalent prepared guest states, and only one QEMU guest runs at a time.

After an interrupted or failed run, clean the runtime state without deleting results:

```bash
./run-ab-test.sh cleanup
```

Use `cleanall` only when you also want to delete all saved test results:

```bash
./run-ab-test.sh cleanall
```

## Updating Images and Kernels (Maintenance)

The test harness pairs a specific Raspberry Pi OS userspace image with a matching generic Debian ARM64 kernel to allow stable emulation on QEMU's `virt` machine. When you need to upgrade components or test a different OS release in the future, follow these steps to locate and pin the correct artifacts.

### 1. Find a New Raspberry Pi OS Image
The harness requires the **64-bit Lite version** of Raspberry Pi OS. 

1. Browse the official release directory: [://raspberrypi.com](https://://raspberrypi.com)
2. Open the desired release folder (e.g., a newer date).
3. Copy the full link to the file ending in `-arm64-lite.img.xz` for `BASE_IMAGE_URL`.
4. Open the accompanying `.sha256` or `.sha256sum` file in that folder and copy the hash for `BASE_IMAGE_SHA256`.

*Note: Always use specific, dated release URLs. Never use `latest` links, as they break reproducibility and checksum verification.*

### 2. Find a Matching Debian Kernel
The Raspberry Pi kernel inside the base image is stripped of QEMU drivers and will not boot. You must supply a generic Debian ARM64 kernel that matches the Debian codename branch of your chosen Raspberry Pi OS:
* Raspberry Pi OS **Bookworm** is based on Debian 12 (use `deb12` packages)
* Raspberry Pi OS **Trixie** is based on Debian 13 (use `deb13` packages)

To ensure the exact kernel package remains permanently available even after being phased out from main Debian mirrors, the harness pulls from the Debian Snapshot Archive:

1. Browse the kernel package index: [snapshot.debian.org/package/linux/](https://debian.org)
2. Select a kernel version matching your Debian branch.
3. Scroll down to the **`arm64`** architecture list.
4. Locate the standard, unsigned or signed image package matching this pattern:
   `linux-image-<version>+deb13-arm64-unsigned_<revision>_arm64.deb`
   *(Do not use `-dbg`, `-cloud`, or meta-packages).*
5. Copy the download link for `KERNEL_DEB_URL`.
6. Copy the SHA-256 hash displayed right next to the file entry for `KERNEL_DEB_SHA256`.

### 3. Update `config.env`
Open your `config.env` file and update the configuration keys. It is best practice to version-tag the generated filenames so that old and new test environments can coexist within your cache directory without conflicts:

```bash
# --- Raspberry Pi OS Base ---
BASE_IMAGE_URL="https://://raspberrypi.comraspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz"
BASE_IMAGE_SHA256="acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3"
BASE_IMAGE_ARCHIVE="\${PREPARED_CACHE_DIR}/raspios-2026-06-18.img.xz"
BASE_IMAGE_RAW="\${PREPARED_CACHE_DIR}/raspios-2026-06-18.img"

# --- Debian Kernel Package ---
KERNEL_DEB="\${PREPARED_CACHE_DIR}/linux-image-6.12.38+deb13-arm64-unsigned_6.12.38-1_arm64.deb"
KERNEL_DEB_URL="https://debian.org"
KERNEL_DEB_SHA256="37a1b3480c9547490e724c734aa7d6a2b535e31f28a40e14e6a8462d8e03ca32"

# --- Generated Cache Artifacts (Version-tagged) ---
PREPARED_IMAGE="\${PREPARED_CACHE_DIR}/raspios-2026-06-18-virt-prepared.img"
KERNEL_IMAGE="\${PREPARED_CACHE_DIR}/Image-6.12.38-1"
INITRAMFS_IMAGE="\${PREPARED_CACHE_DIR}/initrd-6.12.38-1.img"
```

### 4. Rebuild the Cache
Once the new values are saved, force the harness to discard the outdated guest state and compile the new environment from your updated inputs:

```bash
# Safeguard: stop active guests and clear active runtime mounts
./run-ab-test.sh cleanup

# Rebuild the cache using the new kernel and image specifications
./run-ab-test.sh prepare
```
The script automatically evaluates the new SHA-256 hashes. It will bypass large downloads if the file matching the URL and checksum is already present in your `cache/` directory, while cleanly building the updated target images.


## Theory of Operation

The harness uses an official Raspberry Pi OS Lite 64-bit userspace but boots it with a pinned generic ARM64 kernel on QEMU's `virt` machine. 

The original Raspberry Pi OS image is **not compatible with QEMU's virtual standard hardware (`virt` machine)** out of the box. The original Pi kernel is strictly optimized for physical Raspberry Pi chips and does not understand QEMU's high-performance virtual drivers (`virtio` for disks and network). Furthermore, QEMU boots like a generic PC/server, while a real Pi requires its own specific firmware boot path. 

Replacing the kernel during the `prepare` step solves this: it keeps the original Raspberry Pi OS software environment (userspace) intact but gives it a compatible "engine" (the Debian kernel) to run stably and fast inside QEMU.

This tests `image-backup` behavior in a realistic ARM64 Linux environment; it does not test Raspberry Pi firmware boot behavior.

The preparation process keeps the downloaded source image immutable. It creates a separate prepared copy, grows its root partition by `PREPARED_EXTRA_GB` (2 GB by default), mounts that copy through a loop device, and runs ARM64 package setup through `qemu-aarch64-static` in a chroot. The prepared image receives:

- the generic ARM64 kernel and matching initramfs
- the PCI virtio drivers required for QEMU disks and networking
- `rsync`, filesystem, partitioning, and image-check tools
- OpenSSH and a generated test-only public key
- a test user with passwordless `sudo`

The harness sets `LANG=C`, `LANGUAGE=C`, and `LC_ALL=C` for host-controlled and guest test commands. This avoids warnings from unavailable host-specific locales such as `de_DE.UTF-8`; it does not change or assume a timezone.

For each candidate, `qemu-guest.sh` creates a disposable QCOW2 overlay from the prepared image and a fresh virtual backup disk. The guest mounts the backup disk at `/mnt/backup`, where the candidate creates its `.img` file. The guest also creates controlled fixture files, a symlink, a bind mount, and external content so the dynamic exclusion behavior can be checked.

For each candidate, the corresponding `image-backup` script is copied into the guest and executed **inside the virtual QEMU machine** through SSH. The upstream script comes from the pinned checkout in `cache/upstream-repo`; the local script comes from this project. Both scripts therefore back up the same kind of running guest system, but in separate sequential QEMU guests.

The candidate is run first in initial mode and then in incremental mode after deterministic fixture changes. The resulting images are checked and inspected read-only. The comparison uses normalized boot/root manifests containing paths, types, permissions, ownership, sizes, symlink targets, and regular-file SHA-256 checksums. Filesystem UUIDs, partition identifiers, and allocation-specific metadata are not used as equality criteria, because those values may legitimately differ between separately created images.

### Test Details

The test has two independent candidate runs:

1. The pinned upstream `image-backup` creates and updates `upstream.img`.
2. The local modified `image-backup` creates and updates `local.img`.

For each candidate, the harness records:

- the guest console log
- mount topology and preflight information
- the candidate's `image-backup` output
- partition-table and filesystem-check output
- read-only boot and root filesystem manifests
- regular-file checksums

The comparison does not require the raw `.img` files to be byte-identical. It compares the normalized manifests and filtered partition metadata. A comparison passes when both expected manifests match and the intentional behavior difference is correct: the upstream result may contain the external bind-mount fixture, while the local result must exclude it and report the dynamic exclusion. The initial and incremental image checks must also complete successfully.

A test fails when a candidate cannot boot or be reached over SSH, a backup phase exits unsuccessfully, an expected image or manifest is missing, an image filesystem check fails, normalized content differs unexpectedly, the local candidate copies excluded external content, or the local candidate fails to report its dynamic exclusions. The overall command returns exit code `0` only when both initial and incremental comparisons pass.

The test commands are defined in these files:

- `run-ab-test.sh` orchestrates preparation, QEMU guests, candidates, phases, and comparisons.
- `remote-run.sh` defines guest setup, fixtures, initial/incremental backup commands, and artifact collection.
- `compare-results.sh` defines normalization filters and PASS/FAIL comparison rules.
- `inspect-image.sh` defines read-only image mounting and manifest generation.

To adapt the test, change the fixture creation or mutation functions in `remote-run.sh`, adjust the normalized comparison and expected differences in `compare-results.sh`, or add artifact/phase handling in `run-ab-test.sh`. Keep the upstream and local candidate invocations identical unless the difference is itself part of the behavior under test.

## Commands

```bash
./run-ab-test.sh prepare
```
Builds or reuses the prepared ARM64 guest cache and boot-validates it. This is normally a one-time setup step.

```bash
./run-ab-test.sh preflight
```
Boots one temporary guest and checks its tools, loop devices, root filesystem, and separate backup disk. No backup comparison is performed.

```bash
./run-ab-test.sh all
```
Runs upstream and local initial/incremental backups sequentially, compares both result sets, prints a final PASS/FAIL summary, and returns a meaningful exit code.

```bash
./run-ab-test.sh cleanup
```
Stops test-related QEMU processes, removes test mounts and loop devices, and preserves all saved test results and `cache/`. Use this after an interrupted or failed run before starting again.

```bash
./run-ab-test.sh cleanall
```
Performs the same runtime cleanup and removes all saved results below the standard `artifacts/` directory. It never removes the reusable `cache/` directory.

The standalone `initial` command compares initial backups only. The standalone `incremental` command is intentionally not supported because an incremental backup requires the initial image from the same candidate run; use `all` for the complete sequence.

## Results and Logs

Each test invocation creates a timestamped result directory:

```text
tests/ab/artifacts/testresult<UTC timestamp>/
```

Useful files include:

```text
upstream/qemu-console.log
upstream/initial/image-backup.log
upstream/initial/image-check.txt
upstream/initial/image-check.status
upstream/initial/inspect-image.log
upstream/initial/inspect-image.status
upstream/initial/root.manifest
upstream/incremental/...
local/qemu-console.log
local/initial/...
local/incremental/...
initial-comparison.log
incremental-comparison.log
```

`inspect-image.sh` inspects the generated image read-only. It pre-calculates regular-file SHA-256 hashes in parallel, then reads the remaining metadata with native `find -printf` formatting instead of spawning `stat` for every entry. It emits timestamped progress messages reporting entries processed, regular files hashed, throughput, and elapsed time. Progress is reported every 5,000 entries by default and at least every 30 seconds; set `INSPECT_PROGRESS_ENTRIES` or `INSPECT_PROGRESS_INTERVAL` in the guest environment to adjust these thresholds. Each phase stores the combined inspection output in `inspect-image.log` and its exit code in `inspect-image.status`. The generated `root.manifest` and `boot.manifest` format is unchanged.

A successful run ends with output similar to:

```text
[2026-09-04T10:15:01Z] [PASS] initial comparison
[2026-09-04T10:22:44Z] [PASS] incremental comparison
[2026-09-04T10:42:45Z] [PASS] A/B test completed successfully
[2026-09-04T10:42:45Z] [INFO] A/B artifacts: /home/.../tests/ab/artifacts/testresult<UTC timestamp>
```

A failed run ends with a visible diagnostic, for example:

```text
[2026-09-04T10:05:12Z] [FAIL] all aborted (exit 1)
[2026-09-04T10:05:12Z] [FAIL] candidate: upstream
[2026-09-04T10:05:12Z] [FAIL] phase: initial
[2026-09-04T10:05:12Z] [FAIL] stage: running upstream initial backup
[2026-09-04T10:05:12Z] [INFO] A/B artifacts: /home/.../tests/ab/artifacts/testresult<UTC timestamp>
```

The final `poweroff` messages from systemd only mean that a guest was shut down. They are not a test result. Terminal sequences such as `;1R` may appear after QEMU exits; they are harmless serial-console cursor-position control codes.

## Runtime Expectations

The `all` flow can take a considerable amount of time (10-12h). QEMU is emulating an ARM64 Raspberry Pi OS environment, and the harness performs two complete backup sequences, then checks both generated images and compares their contents. The first boot can take several minutes, and the backup/check phases can take considerably longer depending on disk speed and host load.

Do not stop the script merely because the console appears quiet or remains at the serial login prompt. The harness waits for SSH in the background and prints progress every 30 seconds. Stop it only after the configured timeout, an explicit error, or a confirmed hang.

During each backup phase the guest reports progress for fixture setup, `image-backup`, metadata collection, filesystem checking, and image inspection. Every tagged `[INFO]`, `[PASS]`, and `[FAIL]` message includes a UTC timestamp. If a phase fails, the harness tries to copy the partial candidate artifacts before shutting down the guest.

After a message such as:

```text
[2026-09-04T10:22:45Z] [INFO] upstream/initial: inspecting image contents (this may take a while)
```

the guest may remain quiet for a long time. This is expected: `inspect-image.sh` first hashes regular files with parallel `sha256sum` workers and then walks both filesystems with a native `find -printf` metadata scan. Do not interrupt the test merely because inspection is slow. Its progress messages appear in the terminal and in `inspect-image.log`; inspection is read-only and does not alter the generated image or manifest format.

While `image-backup` is running, the guest prints a progress line every 30 seconds and lists active `image-backup`, `rsync`, `e2fsck`, `resize2fs`, and partitioning processes. This is especially useful after the last visible `e2fsck` line: image finalization can still be working on the second dry-run synchronization.

If a run fails or is interrupted, use:

```bash
./run-ab-test.sh cleanup
```

The cleanup command preserves both the reusable `cache/` directory and all `testresult<UTC>` directories. Use `./run-ab-test.sh cleanall` when the saved test results should also be removed; the preparation downloads and image build still remain cached.
