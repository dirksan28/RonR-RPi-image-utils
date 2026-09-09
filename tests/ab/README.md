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
RonR-RPi-image-utils/tests/ab
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

`cleanup` stops active test runners and their test-owned QEMU guests before unmounting
and detaching resources. It preserves the timestamped artifacts, reports any listener
that still owns the configured SSH port, and does not terminate unrelated processes.
The process owner and PID in a `[WARNING]` message can be inspected or stopped
manually when the listener is outside this harness. Cleanup may require `sudo` for
mount and loop-device operations. Process, port, mount, and loop discovery does
not require root. Privileged cleanup uses non-interactive `sudo -n` only when a
test-owned mount or loop is actually found; if root access is unavailable,
cleanup warns, returns nonzero, and retains the artifacts so the next run does
not start with hidden stale state.

If cleanup reports that non-interactive sudo is unavailable, authenticate in the
same terminal and retry the cleanup command:

```bash
sudo -v
./run-ab-test.sh cleanall
```

Do not run the full A/B test with `sudo`; run `./run-ab-test.sh all` as the
normal user so generated artifacts are not owned by root.

Use `cleanall` only when you also want to delete all saved test results:

```bash
./run-ab-test.sh cleanall
```

### 5. Verify backup images with the Backup Boot Test

The `run-backup-boot-test.sh` script is a focused QEMU smoke test for a previously created **bootable** backup image. It starts the image with the prepared generic ARM64 kernel and initramfs, waits for SSH, runs sanity checks, and records a timestamped result.

```bash
# Prepare test environment (kernel, initramfs, SSH keys) - run once
./run-backup-boot-test.sh prepare

# Boot and verify a backup image (use guest-root.qcow2, NOT guest-backup.img)
./run-backup-boot-test.sh all artifacts/testresult*/local/guest-root.qcow2
```

For A/B artifacts, use `guest-root.qcow2`: it is the bootable QEMU guest overlay. Do **not** use `guest-backup.img`; that file is the raw ext4 backup disk created inside the guest and has no partition table or boot partition, so the boot test rejects it. A standalone `.img` file is accepted only when it contains a bootable partitioned disk image.

Actions: `prepare` | `boot` | `sanity-check` | `all`  
Sanity checks: SSH connectivity, systemd status, disk space, backup artifacts, SSH service, kernel version, backup manifest, and essential commands.

## Results and Logs

Each test invocation creates a timestamped result directory:

```text
tests/ab/artifacts/testresult<UTC timestamp>/
```

Useful files include:

```text
result.log                    # Complete run log with all [INFO]/[PASS]/[FAIL] messages
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

The `result.log` file contains a complete chronological record of all tagged messages (`[INFO]`, `[PASS]`, `[FAIL]`) emitted during the run. This allows quick determination of test success/failure without parsing terminal output.

`helperScripts/inspect-image.sh` inspects the generated image read-only. It pre-calculates regular-file SHA-256 hashes in parallel, then reads the remaining metadata with native `find -printf` formatting instead of spawning `stat` for every entry. It emits timestamped progress messages reporting entries processed, regular files hashed, throughput, and elapsed time. Progress is reported every 5,000 entries by default and at least every 30 seconds; set `INSPECT_PROGRESS_ENTRIES` or `INSPECT_PROGRESS_INTERVAL` in the guest environment to adjust these thresholds. Each phase stores the combined inspection output in `inspect-image.log` and its exit code in `inspect-image.status`. The generated `root.manifest` and `boot.manifest` format is unchanged.

A successful run ends with output similar to:

```text
[2026-09-04T10:15:01Z] [PASS] initial comparison
[2026-09-04T10:22:44Z] [PASS] incremental comparison
[2026-09-04T10:42:45Z] [PASS] A/B test completed successfully
[2026-09-04T10:42:45Z] [INFO] Success Exitcode: 0
[2026-09-04T10:42:45Z] [INFO] A/B artifacts: /home/.../tests/ab/artifacts/testresult<UTC timestamp>
```

A failed run ends with a visible diagnostic, for example:

```text
[2026-09-04T10:05:12Z] [FAIL] all aborted (exit 1)
[2026-09-04T10:05:12Z] [FAIL] candidate: upstream
[2026-09-04T10:05:12Z] [FAIL] phase: initial
[2026-09-04T10:05:12Z] [FAIL] stage: running upstream initial backup
[2026-09-04T10:05:12Z] [INFO] Fail Exitcode: 1
[2026-09-04T10:05:12Z] [INFO] A/B artifacts: /home/.../tests/ab/artifacts/testresult<UTC timestamp>
```

The final `poweroff` messages from systemd only mean that a guest was shut down. They are not a test result. Terminal sequences such as `;1R` may appear after QEMU exits; they are harmless serial-console cursor-position control codes.

## Runtime Expectations

The `all` flow can take a considerable amount of time (~1–2 hours), depending on your local machine). QEMU emulates an ARM64 Raspberry Pi OS environment, and the harness performs two complete backup sequences, then checks both generated images and compares their contents. The first boot can take several minutes, and the backup and check phases can take considerably longer depending on disk speed and host load.

---

## Backup Boot Test details

This test boots a previously created backup image (`.img` file from `image-backup`) in QEMU and runs sanity checks to verify the backup is bootable and functional.

he Backup Boot Verification Test is important because the A/B test and filesystem checks do not prove that an image can actually start as a usable system.

It provides an additional smoke test for:

- valid partition layout and boot partition
- correct root filesystem and mount configuration
- boot-partition contents and PARTUUID handling
- SSH and systemd startup
- essential commands and backup artifacts
regressions that only appear during an actual boot

Typical uses:

1. Run it after changing image-backup to catch boot-partition or filesystem regressions.
2. Verify that a generated QEMU test image is usable before further inspection.
3. Confirm that backup output is not merely structurally valid, but can start a functioning guest.
4. Perform a quick, disposable pre-restore check without writing anything to a physical SD card.

The test is intentionally limited: it uses the prepared generic ARM64 kernel and initramfs for QEMU, so it validates image layout and userspace behavior. It does not prove compatibility with Raspberry Pi firmware, the original Pi kernel, or physical Raspberry Pi hardware.

For A/B artifacts, use guest-root.qcow2. guest-backup.img is the raw ext4 backup disk created inside the guest and is not itself a bootable disk image.

### Prerequisites

1. Run the A/B test preparation first (creates kernel, initramfs, and SSH keys):
   ```bash
   ./run-ab-test.sh prepare
   ```

2. Have a bootable backup image file:
   - From A/B test: `artifacts/testresult*/local/guest-root.qcow2` or the corresponding upstream overlay
   - From a manual `image-backup` run: an output `.img` containing a partition table and boot partition

### Configuration

Copy the example configuration:

```bash
cp config.example.env config.env
```

Edit `config.env` and set `BACKUP_IMAGE` to your backup image path, or pass it as an argument.

### Usage

All commands run from `tests/ab` directory:

```bash
# Prepare the test environment (kernel, initramfs, SSH keys) - run once
./run-backup-boot-test.sh prepare

# Boot the backup image and keep guest running (interactive)
./run-backup-boot-test.sh boot /path/to/backup.img

# Boot, run sanity checks, and shutdown (automated)
./run-backup-boot-test.sh all /path/to/backup.img

# Run sanity checks on already-running guest
./run-backup-boot-test.sh sanity-check
```

### Actions

| Action | Description |
|--------|-------------|
| `prepare` | Run `run-ab-test.sh prepare` to set up kernel, initramfs, and SSH keys |
| `boot` | Start QEMU guest with backup image, wait for SSH, keep running |
| `sanity-check` | Run sanity checks on already-running guest (requires SSH) |
| `all` | Boot guest, run sanity checks, clean shutdown |

### Sanity Checks

The `sanity-check` and `all` actions perform:

1. **Basic connectivity** - hostname, uptime, user
2. **Systemd status** - `systemctl is-system-running --wait`
3. **Disk space** - `df -h /`
4. **Backup artifacts** - Check `/mnt/backup/` and `/var/tmp/image-backup*/`
5. **SSH service** - `systemctl status ssh`
6. **Kernel version** - `uname -a`
7. **Backup manifest** - Read `/mnt/backup/backup.manifest` if present
8. **Essential commands** - Verify `rsync`, `sudo`, `systemctl`, `journalctl` available

### Results and Logs

Each test creates a timestamped result directory:

```text
tests/ab/artifacts/backup-boot-test<UTC timestamp>/
```

Files include:

```text
result.log              # Complete run log
qemu-console.log        # QEMU serial console output
sanity.log              # Sanity check output
guest-root.qcow2        # QCOW2 overlay of the backup image
```

The `result.log` file contains a complete chronological record of all tagged messages (`[INFO]`, `[PASS]`, `[FAIL]`) emitted during the run. This allows quick determination of test success/failure without parsing terminal output.

A successful run ends with output similar to:

```text
[2026-09-07T10:13:33Z] [PASS] All sanity checks completed
[2026-09-07T10:13:45Z] [PASS] Backup boot test completed successfully
[2026-09-07T10:13:45Z] [INFO] Success Exitcode: 0
[2026-09-07T10:13:45Z] [INFO] Backup boot test artifacts: /home/.../tests/ab/artifacts/backup-boot-test<UTC timestamp>
```

A failed run ends with a visible diagnostic, for example:

```text
[2026-09-07T09:24:12Z] [FAIL] all aborted (exit 1)
[2026-09-07T09:24:12Z] [FAIL] stage: stopping QEMU guest
[2026-09-07T09:24:12Z] [INFO] Fail Exitcode: 1
[2026-09-07T09:24:12Z] [INFO] Backup boot test artifacts: /home/.../tests/ab/artifacts/backup-boot-test<UTC timestamp>
```

The final `poweroff` messages from systemd only mean that a guest was shut down. They are not a test result. Terminal sequences such as `;1R` may appear after QEMU exits; they are harmless serial-console cursor-position control codes.

### Example Workflow

```bash
# 1. Prepare the test environment (once) - sets up kernel, initramfs, SSH keys
./run-backup-boot-test.sh prepare

# 2. Run A/B test to create a bootable QEMU artifact (or use image-backup directly)
./run-ab-test.sh all

# 3. Boot the local backup image for verification
./run-backup-boot-test.sh all artifacts/testresult20260906T070201Z/local/guest-root.qcow2

# 4. Or boot an upstream backup image for comparison
./run-backup-boot-test.sh all artifacts/testresult20260906T070201Z/upstream/guest-root.qcow2
```

### Notes

- The image is booted using the **generic ARM64 kernel and initramfs** from the prepared cache, not the kernel inside the input image. This provides the QEMU `virt` compatibility needed for the test.
- SSH keys from the prepared cache are used (injected during `prepare`). The backup image must have been created from a prepared guest or have the same authorized_keys.
- The A/B test requests SSH port 2222 by default and automatically tries nearby available ports when it is occupied. The backup boot test uses the configured `SSH_PORT`; run only one test at a time when using the same configured port, or change the port in `config.env`.
- A/B `guest-root.qcow2` artifacts are QEMU-only overlays for validation. They are not physical Raspberry Pi SD-card images and must not be written directly to an SD card.

Do not stop the script merely because the console appears quiet or remains at the serial login prompt. The harness waits for SSH in the background and prints progress every 30 seconds. Stop it only after the configured timeout, an explicit error, or a confirmed hang.

During each backup phase the guest reports progress for fixture setup, `image-backup`, metadata collection, filesystem checking, and image inspection. Every tagged `[INFO]`, `[PASS]`, and `[FAIL]` message includes a UTC timestamp. If a phase fails, the harness tries to copy the partial candidate artifacts before shutting down the guest.

After a message such as:

```text
[2026-09-04T10:22:45Z] [INFO] upstream/initial: inspecting image contents (this may take a while)
```

the guest may remain quiet for a long time. This is expected: `helperScripts/inspect-image.sh` first hashes regular files with parallel `sha256sum` workers and then walks both filesystems with a native `find -printf` metadata scan. Do not interrupt the test merely because inspection is slow. Its progress messages appear in the terminal and in `inspect-image.log`; inspection is read-only and does not alter the generated image or manifest format.

While `image-backup` is running, the guest prints a progress line every 30 seconds and lists active `image-backup`, `rsync`, `e2fsck`, `resize2fs`, and partitioning processes. This is especially useful after the last visible `e2fsck` line: image finalization can still be working on the second dry-run synchronization.

If a run fails or is interrupted, use:

```bash
./run-ab-test.sh cleanup
```

The cleanup command preserves both the reusable `cache/` directory and all `testresult<UTC>` directories. Use `./run-ab-test.sh cleanall` when the saved test results should also be removed; the preparation downloads and image build still remain cached.

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

For each candidate, `helperScripts/qemu-guest.sh` creates a disposable QCOW2 overlay from the prepared image and a fresh virtual backup disk. The guest mounts the backup disk at `/mnt/backup`, where the candidate creates its `.img` file. The guest also creates controlled fixture files, a symlink, a bind mount, and external content so the dynamic exclusion behavior can be checked.

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

### Comparison and Normalization (`helperScripts/compare-results.sh`)

The `helperScripts/compare-results.sh` script performs the final comparison between upstream and local results. It is invoked by `run-ab-test.sh` after both candidates complete, but can also be run manually on existing artifact directories:

```bash
./helperScripts/compare-results.sh artifacts/testresultXXXXXXXXXXXXXX/upstream/initial artifacts/testresultXXXXXXXXXXXXXX/local/initial
./helperScripts/compare-results.sh artifacts/testresultXXXXXXXXXXXXXX/upstream/incremental artifacts/testresultXXXXXXXXXXXXXX/local/incremental
```

#### Manifest Format

Each candidate produces `boot.manifest` and `root.manifest` files. These are tabular text files with one line per filesystem entry:

```
path    type    perms    owner    group    size    target    hash
```

- **path**: absolute path from filesystem root (e.g., `etc/passwd`, `boot/firmware/start4.elf`)
- **type**: `regular file`, `directory`, `symbolic link`, etc.
- **perms**: octal permissions (e.g., `644`, `755`)
- **owner/group**: user and group names
- **size**: file size in bytes (for directories, block size)
- **target**: symlink target (empty for non-symlinks)
- **hash**: SHA-256 checksum (empty for non-regular files)

#### Normalization Process

Before comparing, both manifests are normalized to filter out differences that are **expected runtime variations** between separate QEMU boots. The normalization happens in `normalize_manifest()`:

1. **Test fixture exclusion**: Removes entries under `opt/image-backup-ab-fixtures/bind-target/` and `opt/image-backup-ab-fixtures/external-link` (these are intentional test artifacts that differ by design).
2. **Runtime exclusion**: Filters lines matching `RUNTIME_EXCLUDE_PATTERNS` (see below).

The filtered manifests are then compared with `diff -u`. A pass means zero diff output.

#### `RUNTIME_EXCLUDE_PATTERNS` — Purpose and Categories

Each QEMU guest boots fresh, so system state naturally differs between runs. These patterns exclude paths that represent **runtime state**, not functional differences in the backup script. Patterns match the path at the start of a manifest line followed by whitespace.

| Category | Examples | Reason |
|----------|----------|--------|
| **Machine identity** | `etc/machine-id`, `var/lib/systemd/random-seed` | Generated uniquely on first boot |
| **Boot firmware symlinks** | `boot/issue.txt`, `boot/overlays` | Point to `firmware/`; presence varies by kernel/initramfs |
| **Systemd state** | `var/lib/systemd/*`, `var/log/journal/` | Timestamps, journal cursors, coredump state |
| **Logs** | `var/log/*`, `var/log/apt/`, `var/log/dpkg.log` | Rotated, appended, or created per boot |
| **Package manager state** | `var/lib/apt/*`, `var/lib/dpkg/info/` | Cache, lists, extended states change on APT runs |
| **NetworkManager** | `var/lib/NetworkManager/*` | Lease files, timestamps, connection state |
| **Cloud-init** | `var/lib/cloud/*` | Instance data, semaphores, boot-stage markers |
| **Directory sizes** | `usr/bin`, `usr/lib/aarch64-linux-gnu`, `usr/share/man/man*`, `etc/ssl/certs`, kernel headers under `usr/src/` | Block allocation varies with file creation order |
| **Runtime symlinks** | `var/lock`, `var/run` | Point to `/run/lock`, `/run`; may be directories or symlinks |
| **Temp files** | `var/tmp/systemd-private-*` | Private systemd directories created per boot |

#### Extending Patterns in the Future

If a new test run fails with diffs that are **runtime artifacts** (not functional bugs), add patterns to `RUNTIME_EXCLUDE_PATTERNS` in `helperScripts/compare-results.sh`:

1. Identify the differing path from the diff output.
2. Add a pattern matching the path prefix followed by `[[:space:]]` (e.g., `'^var/lib/new-runtime-path[[:space:]]'`).
3. Re-run `helperScripts/compare-results.sh` on the same artifacts to verify the diff disappears.

**Do not** add patterns for functional differences (e.g., missing boot firmware files, missing `/var/tmp` exclusion) — those indicate bugs in `image-backup` that should be fixed in the script itself.

A test fails when a candidate cannot boot or be reached over SSH, a backup phase exits unsuccessfully, an expected image or manifest is missing, an image filesystem check fails, normalized content differs unexpectedly, the local candidate copies excluded external content, or the local candidate fails to report its dynamic exclusions. The overall command returns exit code `0` only when both initial and incremental comparisons pass.

The test commands are defined in these files:

- `run-ab-test.sh` orchestrates preparation, QEMU guests, candidates, phases, and comparisons.
- `helperScripts/remote-run.sh` defines guest setup, fixtures, initial/incremental backup commands, and artifact collection.
- `helperScripts/compare-results.sh` defines normalization filters and PASS/FAIL comparison rules.
- `helperScripts/inspect-image.sh` defines read-only image mounting and manifest generation.

To adapt the test, change the fixture creation or mutation functions in `helperScripts/remote-run.sh`, adjust the normalized comparison and expected differences in `helperScripts/compare-results.sh`, or add artifact/phase handling in `run-ab-test.sh`. Keep the upstream and local candidate invocations identical unless the difference is itself part of the behavior under test.

## Maintenance

### Updating Images and Kernels

The test harness pairs a specific Raspberry Pi OS userspace image with a matching generic Debian ARM64 kernel to allow stable emulation on QEMU's `virt` machine. When you need to upgrade components or test a different OS release in the future, follow these steps to locate and pin the correct artifacts.

#### 1. Find a New Raspberry Pi OS Image
The harness requires the **64-bit Lite version** of Raspberry Pi OS. 

1. Browse the official release directory: [://raspberrypi.com](https://://raspberrypi.com)
2. Open the desired release folder (e.g., a newer date).
3. Copy the full link to the file ending in `-arm64-lite.img.xz` for `BASE_IMAGE_URL`.
4. Open the accompanying `.sha256` or `.sha256sum` file in that folder and copy the hash for `BASE_IMAGE_SHA256`.

*Note: Always use specific, dated release URLs. Never use `latest` links, as they break reproducibility and checksum verification.*

#### 2. Find a Matching Debian Kernel
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

#### 3. Update `config.env`
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

#### 4. Rebuild the Cache
Once the new values are saved, force the harness to discard the outdated guest state and compile the new environment from your updated inputs:

```bash
# Safeguard: stop active guests and clear active runtime mounts
./run-ab-test.sh cleanup

# Rebuild the cache using the new kernel and image specifications
./run-ab-test.sh prepare
```
The script automatically evaluates the new SHA-256 hashes. It will bypass large downloads if the file matching the URL and checksum is already present in your `cache/` directory, while cleanly building the updated target images.

### Agentic Support

Two documentation files in `agentic-context/` support AI-assisted maintenance and continuation:

| File | Purpose | Audience | Lifecycle |
|------|---------|----------|-----------|
| `agentic-context/plan-qemuImageBackupAbTest.prompt.md` | Design specification for the test harness | Someone understanding/extending the test architecture | Relatively static (test design) |
| `agentic-context/HANDOVER.md` | Continuation guide for the fix work | Someone picking up the fix work on another machine | Evolves with each session |

**Content focus:**
- `agentic-context/plan-qemuImageBackupAbTest.prompt.md` — "What the test does and why" (fixtures, QEMU setup, manifest generation, comparison logic)
- `agentic-context/HANDOVER.md` — "What was broken, what's fixed, how to resume" (boot copy fix, var/tmp exclusion, runtime normalization patterns, passing artifacts)
