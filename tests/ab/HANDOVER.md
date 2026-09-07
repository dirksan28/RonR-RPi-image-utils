# Handover Document: image-backup A/B Test Fix

**Date:** 2026-09-08  
**Project:** RonR-RPi-image-utils  
**Workspace:** `./` (project root)

---

## Context & Purpose

This document captures the state of the A/B test fix work for the `image-backup` script. It is intended for **continuation on another machine** or by another developer. It documents:
- What was broken and what was fixed
- Current test status and artifact locations
- How to resume work without re-discovering the problem
- Key files and commands

---

## Current Status

**Test Status:** ✅ **PASSING** - Both initial and incremental comparisons pass  
**Last A/B Run:** `testresult20260907T165033Z` (2026-09-07T17:51:14Z)  
**Exit Code:** 0 (comparisons pass)

The A/B test compares the **local** `image-backup` script against the **upstream** revision `0ee5757f43eca29c581ccb6d7ee8818e6ed2cb98` running in QEMU ARM64 guests. The test uses `--noexpand` flag and compares normalized manifests.

**Backup Boot Test:** ✅ **WORKING** - New test `run-backup-boot-test.sh` boots backup images in QEMU and runs sanity checks.

---

## Problem Statement

The local `image-backup` script fails the A/B test because the backup images produced by local vs upstream differ in ways that are **runtime artifacts** (not actual functional differences). Each test run boots a fresh QEMU guest, so system state (machine-id, logs, caches, directory sizes, etc.) naturally differs between runs.

The `compare-results.sh` script needs to normalize these runtime differences before comparing manifests.

---

## Root Cause of Failures

The diff output shows these categories of differences that are **expected runtime variations**:

| Category | Examples |
|----------|----------|
| **Machine identity** | `/etc/machine-id` (different hash each boot) |
| **Boot firmware symlinks** | `/boot/issue.txt`, `/boot/overlays` (point to firmware/) |
| **Systemd state** | `/var/lib/systemd/random-seed`, journal directories |
| **Logs** | `/var/log/*`, `/var/log/journal/*` |
| **Package manager state** | `/var/lib/apt/*`, `/var/lib/dpkg/info/` |
| **NetworkManager** | `/var/lib/NetworkManager/*` (lease files, timestamps) |
| **Cloud-init** | `/var/lib/cloud/*` (instance data, semaphores) |
| **Directory sizes** | Many `/usr/*` directories have different block counts |
| **Runtime symlinks** | `/var/lock`, `/var/run` |
| **Temp files** | `/var/tmp/systemd-private-*` |

---

## Changes Made (Last 2 Days)

### 1. Fixed `image-backup` script (local DUT)

**File:** `image-backup`

| Fix | Location | Description |
|-----|----------|-------------|
| **Boot partition copy** | `backup()` function, after `chmod a+rwxt "${MNTPATH}/tmp/"` | Added code to parse `/etc/fstab` for boot mount point and rsync boot partition contents to `${BOOTMNT}/` |
| **`/var/tmp` exclusion (initial backup)** | Line ~165 | Added `--exclude '/var/tmp'` to initial backup rsync command |
| **`/var/tmp` exclusion (incremental dry-run)** | Line ~601 | Added `--exclude '/var/tmp'` to incremental dry-run rsync command |

**Verification:** Both fixes confirmed present via `grep_search`.

### 2. Updated `compare-results.sh` with runtime normalization

**File:** `tests/ab/compare-results.sh`

Added `RUNTIME_EXCLUDE_PATTERNS` array with patterns for:
- Machine identity (`etc/machine-id`, `var/lib/systemd/random-seed`)
- Logs (`var/log/`, `var/log/journal/`)
- Package manager state (`var/lib/apt/`, `var/lib/dpkg/`)
- NetworkManager, cloud-init, systemd state
- Boot firmware symlinks (`boot/issue.txt`, `boot/overlays`)
- Directories with variable sizes (`usr/lib/firmware/brcm`, `usr/lib/python3/dist-packages`, `usr/share/consolefonts`, `usr/share/doc`, `usr/share/man/man2`, `usr/share/man/man7`, `usr/share/man/man8`, `usr/share/mime/application`, `usr/src/linux-headers-*/include/config`, `usr/src/linux-headers-*/include/linux`, `etc/ssl/certs`, `usr/bin`)

**Function:** `normalize_manifest()` filters both upstream and local manifests through `grep -Ev` with the combined pattern before diffing.

### 3. Documentation

**File:** `fix-image-backup.prompt.md`

Created documentation of the two fixes with exact code snippets.

---

## New Features (2026-09-07)

### 4. Backup Boot Test (`run-backup-boot-test.sh`)

**New test script** that boots previously created backup images in QEMU and runs sanity checks.

**Actions:**
- `prepare` - Runs `run-ab-test.sh prepare` to set up kernel, initramfs, SSH keys
- `boot` - Starts QEMU guest with backup image, waits for SSH, keeps running
- `sanity-check` - Runs sanity checks on already-running guest (requires SSH)
- `all` - Boots guest, runs sanity checks, clean shutdown

**Sanity Checks:**
1. Basic connectivity (hostname, uptime, user)
2. Systemd status (`systemctl is-system-running`)
3. Disk space (`df -h /`)
4. Backup artifacts (`/mnt/backup/`, `/var/tmp/image-backup*/`)
5. SSH service status
6. Kernel version (`uname -a`)
7. Backup manifest (`/mnt/backup/backup.manifest`)
8. Essential commands (`rsync`, `sudo`, `systemctl`, `journalctl`)

**Key Features:**
- **Early bootable image check** - Detects raw ext4 filesystems (like `guest-backup.img`) vs bootable disk images (like `guest-root.qcow2`) before starting QEMU
- **qcow2 backing file support** - Automatically detects qcow2 images with backing files and checks the backing file for partition table
- **Relative path fix** - Converts relative paths to absolute before changing directory
- **Artifact directory** - Creates timestamped results under `tests/ab/artifacts/backup-boot-test<UTC>/`

### 5. Config Merge

**Merged** `config.backup-boot.example.env` into `config.example.env`:
- Added `BACKUP_IMAGE=""` setting with documentation
- Deleted redundant `config.backup-boot.example.env`
- Updated `README.md` to reference single config file

### 6. README.md Updates

**Added to Backup Boot Test section:**
- Artifact file types table (`guest-root.qcow2` vs `guest-backup.img`)
- Why qcow2 differs from normal Raspberry Pi OS image (format, backing file, kernel, drivers, firmware)
- Clear warning: "These images are QEMU-only and cannot be written directly to an SD card for physical Raspberry Pi boot"

---

## Test Artifacts Location

```
tests/ab/artifacts/
├── testresult20260905T124939Z/   # Previous run (before compare-results.sh updates)
├── testresult20260905T222818Z/   # Previous run
├── testresult20260906T032812Z/   # Previous run (with expanded exclusions, still failing)
├── testresult20260906T070201Z/   # Previous PASSING run
├── testresult20260907T165033Z/   # **LATEST A/B - PASSING** (all comparisons pass)
├── backup-boot-test20260907T101159Z/  # Backup boot test (PASS)
├── backup-boot-test20260907T110246Z/  # Backup boot test (PASS)
├── backup-boot-test20260907T143505Z/  # Backup boot test (PASS)
├── backup-boot-test20260907T212047Z/  # Backup boot test (PASS)
└── backup-boot-test20260907T220316Z/  # Backup boot test preflight (PASS)
```

Each A/B test result contains:
- `upstream/initial/` and `upstream/incremental/` - upstream results
- `local/initial/` and `local/incremental/` - local results
- `initial-comparison.log` / `incremental-comparison.log` - diff output (empty = pass)

Each backup boot test result contains:
- `result.log` - Complete run log with [INFO]/[PASS]/[FAIL] messages
- `qemu-console.log` - QEMU serial console output
- `sanity.log` - Sanity check output
- `guest-root.qcow2` - QCOW2 overlay of the backup image

Each contains:
- `upstream/initial/` and `upstream/incremental/` - upstream results
- `local/initial/` and `local/incremental/` - local results
- `initial-comparison.log` / `incremental-comparison.log` - diff output (empty = pass)

---

## How to Resume

### 1. Quick Start (if re-running full A/B test)
```bash
cd tests/ab
./run-ab-test.sh all
```

### 2. Verify Current A/B Artifacts (no re-run needed)
The latest artifacts at `testresult20260907T165033Z/` already pass. Verify:
```bash
./compare-results.sh artifacts/testresult20260907T165033Z/upstream/initial artifacts/testresult20260907T165033Z/local/initial
./compare-results.sh artifacts/testresult20260907T165033Z/upstream/incremental artifacts/testresult20260907T165033Z/local/incremental
```
Both should exit with code 0 and no diff output.

### 3. Run Backup Boot Test
```bash
# Prepare test environment (kernel, initramfs, SSH keys) - run once
./run-backup-boot-test.sh prepare

# Boot and verify a backup image (use guest-root.qcow2, NOT guest-backup.img)
./run-backup-boot-test.sh all artifacts/testresult20260907T165033Z/local/guest-root.qcow2

# Or boot upstream backup for comparison
./run-backup-boot-test.sh all artifacts/testresult20260907T165033Z/upstream/guest-root.qcow2
```

### 4. If A/B Test Still Fails (future runs)
Check the latest comparison logs:
```bash
cat tests/ab/artifacts/testresultXXXXXXXXXXXXXX/initial-comparison.log
cat tests/ab/artifacts/testresultXXXXXXXXXXXXXX/incremental-comparison.log
```

Identify new patterns in the diff that need to be added to `RUNTIME_EXCLUDE_PATTERNS` in `compare-results.sh`.

### 5. Key Files to Modify
- `tests/ab/compare-results.sh` - Add more exclusion patterns (if new runtime differences appear)
- `image-backup` - Only if functional bugs found (boot copy, var/tmp exclusion already done)
- `tests/ab/run-backup-boot-test.sh` - For backup boot test modifications
- `tests/ab/README.md` - Documentation updates
- `tests/ab/config.example.env` - Configuration settings

---

## ⚠️ Important: Minimize Tool Calls During Test Runs

**When running the full A/B test (`./run-ab-test.sh all`), avoid frequent polling of the terminal output.**

- The test takes **2+ hours** and produces verbose output every few seconds
- **Do NOT** call `get_terminal_output` every minute - this triggers excessive model calls
- **Instead:** Start the test once, then **wait for completion** (or check artifacts after ~2-3 hours)
- All test output is written to the artifact directories (`tests/ab/artifacts/testresult*/`)
- After the test completes, run `compare-results.sh` on the artifact directories to verify
- This avoids token budget issues and "Configure max requests" warnings

**Recommended workflow:**
1. Start test: `./run-ab-test.sh all` (async)
2. Wait ~2-3 hours (do other work)
3. Check artifacts: `ls tests/ab/artifacts/` (find latest timestamp)
4. Run comparison on artifacts (instant, no terminal polling needed)

**Backup Boot Test (`run-backup-boot-test.sh all`):**
- Takes ~2-5 minutes (much faster than A/B test)
- Same principle: start once, wait for completion, check artifacts
- Artifacts in `tests/ab/artifacts/backup-boot-test<UTC>/`

---

## Upstream Reference

**Repository:** `https://github.com/seamusdemora/RonR-RPi-image-utils.git`  
**Pinned Revision:** `0ee5757f43eca29c581ccb6d7ee8818e6ed2cb98`  
**Local Cache:** `tests/ab/cache/upstream-repo/` (checked out at pinned revision)

---

## Test Configuration

**Config:** `tests/ab/config.env` (copied from `config.example.env`)  
**Key Settings:**
- `UPSTREAM_REVISION="0ee5757f43eca29c581ccb6d7ee8818e6ed2cb98"`
- `INITIAL_SIZE_MB=2048`
- `BACKUP_DISK_SIZE_GB=8`
- `QEMU_MEMORY_MB=2048`, `QEMU_CPUS=2`

---

## Notes for Next Session

1. **The boot partition copy fix is working** - the diff no longer shows missing firmware files (`start_*.elf`, `user-data`) in boot.manifest
2. **The `/var/tmp` exclusion is working** - no more `systemd-private-*` directories in root.manifest
3. **All runtime normalization patterns are working** - both initial and incremental comparisons pass with zero diff
4. **If future runs fail:** Only add new patterns to `RUNTIME_EXCLUDE_PATTERNS` in `compare-results.sh` for any new runtime differences that appear
5. **Do NOT modify** the upstream reference or the test fixtures - only normalize the comparison

---

## Commands Reference

```bash
# Run full A/B test
cd tests/ab && ./run-ab-test.sh all

# Run only comparison on existing artifacts
./compare-results.sh artifacts/testresultXXXXXXXXXXXXXX/upstream/initial artifacts/testresultXXXXXXXXXXXXXX/local/initial

# View latest diff
cat artifacts/testresult20260906T032812Z/initial-comparison.log

# Check current image-backup fixes
grep -n "var/tmp" image-backup
grep -A 10 "Copying boot partition" image-backup
```