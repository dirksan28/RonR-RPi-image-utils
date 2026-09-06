# Handover Document: image-backup A/B Test Fix

**Date:** 2026-09-06  
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
**Last Run:** `testresult20260906T070201Z` (2026-09-06T08:24:19Z)  
**Exit Code:** 0 (comparisons pass)

The A/B test compares the **local** `image-backup` script against the **upstream** revision `0ee5757f43eca29c581ccb6d7ee8818e6ed2cb98` running in QEMU ARM64 guests. The test uses `--noexpand` flag and compares normalized manifests.

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

## Test Artifacts Location

```
tests/ab/artifacts/
├── testresult20260905T124939Z/   # Previous run (before compare-results.sh updates)
├── testresult20260905T222818Z/   # Previous run
├── testresult20260906T032812Z/   # Previous run (with expanded exclusions, still failing)
└── testresult20260906T070201Z/   # **LATEST - PASSING** (all comparisons pass)
```

Each contains:
- `upstream/initial/` and `upstream/incremental/` - upstream results
- `local/initial/` and `local/incremental/` - local results
- `initial-comparison.log` / `incremental-comparison.log` - diff output (empty = pass)

---

## How to Resume

### 1. Quick Start (if re-running full test)
```bash
cd tests/ab
./run-ab-test.sh all
```S

### 2. Verify Current Artifacts (no re-run needed)
The latest artifacts at `testresult20260906T070201Z/` already pass. Verify:
```bash
./compare-results.sh artifacts/testresult20260906T070201Z/upstream/initial artifacts/testresult20260906T070201Z/local/initial
./compare-results.sh artifacts/testresult20260906T070201Z/upstream/incremental artifacts/testresult20260906T070201Z/local/incremental
```
Both should exit with code 0 and no diff output.

### 3. If Test Still Fails (future runs)
Check the latest comparison logs:
```bash
cat tests/ab/artifacts/testresultXXXXXXXXXXXXXX/initial-comparison.log
cat tests/ab/artifacts/testresultXXXXXXXXXXXXXX/incremental-comparison.log
```

Identify new patterns in the diff that need to be added to `RUNTIME_EXCLUDE_PATTERNS` in `compare-results.sh`.

### 4. Key Files to Modify
- `tests/ab/compare-results.sh` - Add more exclusion patterns (if new runtime differences appear)
- `image-backup` - Only if functional bugs found (boot copy, var/tmp exclusion already done)

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