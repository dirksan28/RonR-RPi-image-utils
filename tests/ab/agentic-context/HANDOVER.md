# Handover: image-backup A/B and Backup Boot Tests

**Date:** 2026-09-09  
**Project:** RonR-RPi-image-utils  
**Workspace:** `/home/schm/vspython/RonR-RPi-image-utils`

This document records the current implementation and the latest validated test state. The worktree has not been committed.

## Current Status

The last known passing full A/B baseline is `tests/ab/artifacts/testresult20260908T083231Z/`.
The latest follow-up run `testresult20260909T110258Z` completed both candidates,
but its original comparisons failed because directory allocation sizes were
compared literally. The comparator now normalizes directory sizes; rerunning
both comparison commands on that artifact passes with exit `0` and no output.
The full A/B flow has not yet been rerun with the fix, so do not report a new
full-run pass yet. An earlier run, `testresult20260909T102629Z`, failed during
the local initial phase with exit `255` and is a separate unresolved failure.

The prepared guest cache remains reusable when its manifest matches, and the
inspection/hash-cache changes remain covered by the passing baseline. The later
port-fallback preflight `testresult20260909T101442Z` passed with exit `0` while
`2222` was deliberately occupied; it identified the listener, selected `2223`,
and completed the guest validation.

The worktree has not been committed. No test runner, QEMU process, or forwarding
listener is currently active. A stale test-owned `/dev/loop46` backed by the
deleted prepared image remains; detaching it requires root access.

## Latest Validated Runs

### Full A/B Test

Artifact directory:

```text
tests/ab/artifacts/testresult20260908T083231Z/
```

The run completed from `2026-09-08T08:32:31Z` to `2026-09-08T09:07:00Z` with exit code `0`.

- Upstream initial: passed.
- Upstream incremental: passed.
- Local initial: passed.
- Local incremental: passed.
- Initial comparison: passed; `initial-comparison.log` is empty.
- Incremental comparison: passed; `incremental-comparison.log` is empty.
- All eight `image-check.status` and `inspect-image.status` files contain `0`.

The complete chronological result is in `tests/ab/artifacts/testresult20260908T083231Z/result.log`.

### Backup Boot Test

Artifact directory:

```text
tests/ab/artifacts/backup-boot-test20260908T094742Z/
```

The test used:

```text
tests/ab/artifacts/testresult20260908T083231Z/local/guest-root.qcow2
```

It passed SSH readiness, all sanity checks, clean shutdown, and exited with code `0`. The result is recorded in `result.log`; `sanity.log` and `qemu-console.log` contain the detailed output.

## Local `image-backup` Changes

The local system under test is `image-backup`. The current safety changes include:

- Dynamic root-source detection with `findmnt`.
- Dynamic exclusion of non-root mounts.
- Symlink target checks using `readlink` and filesystem-source comparisons.
- Explicit exclusion of the backup target mount and `/var/tmp`.
- Safe validation of the target partition and mount point.
- Explicit boot-partition copying and PARTUUID handling.
- Correct preservation of the `rsync` exit status.

The upstream candidate is checked out at:

```text
0ee5757f43eca29c581ccb6d7ee8818e6ed2cb98
```

The local and upstream candidates run in separate sequential QEMU guests with equivalent fixture changes. The comparison uses normalized manifests and partition metadata, not raw image-byte equality.

## Test Harness Layout

The two root entrypoints remain in `tests/ab/`:

```text
tests/ab/run-ab-test.sh
tests/ab/run-backup-boot-test.sh
```

All other shell helpers are under `tests/ab/helperScripts/`:

```text
helperScripts/cleanup.sh
helperScripts/compare-results.sh
helperScripts/inspect-image.sh
helperScripts/prepare-raspios-virt.sh
helperScripts/qemu-guest.sh
helperScripts/remote-run.sh
```

`run-ab-test.sh` resolves these through `HELPER_DIR`. `remote-run.sh` and `inspect-image.sh` are copied together into the guest, so their guest-side sibling lookup remains valid. `cleanup.sh` and `prepare-raspios-virt.sh` resolve the repository root three levels above their new location.

## QEMU and Prepared Cache

The harness uses Raspberry Pi OS Lite ARM64/Trixie userspace with a pinned generic Debian ARM64 kernel for QEMU `virt`:

```text
Kernel: 6.12.38+deb13-arm64
Machine: virt
Memory: 2048 MB
CPUs: 2
First requested SSH port: 2222; `run-ab-test.sh` selects a nearby available port
and records the owner when the requested port is busy.
Backup disk: 8 GB
```

QEMU starts with:

```text
-cpu max,pauth=off
```

The prepared cache is described by `tests/ab/cache/prepared.manifest`. The current preparation contract is version `5` and records:

- `preparation_version`
- base-image SHA-256
- kernel-package SHA-256 and version
- prepared extra size
- guest user
- generated public test-key SHA-256

The first preparation or an invalidated rebuild needs network access for the pinned downloads and guest package installation. A matching cache is reused before the guest chroot is entered; it does not run `apt-get update` or `apt-get install`.

The pinned image and kernel are configured in `tests/ab/config.env`, which is ignored by Git. Do not commit private keys, cache files, generated images, or test artifacts.

## Process Lifecycle and Cleanup

The A/B and backup-boot entrypoints record their PID and process start time below
their artifact directory. QEMU console capture uses process substitution so the
runner tracks QEMU directly instead of a surviving `tee` pipeline wrapper.

`run-ab-test.sh cleanup`, `clean`, and `cleanall` first stop repository-owned test
runners and QEMU processes, then inspect the configured SSH port. Process, port,
mount, and loop discovery is unprivileged. Unmounting and loop detachment use
non-interactive `sudo -n` only after matching test-owned resources are found. If
root access is unavailable, cleanup warns, returns nonzero, and retains artifacts;
it does not prompt for a password or continue into a new test run.

An occupied port outside this harness is reported with the process/PID and is not
terminated automatically.

## Inspection Optimization

`helperScripts/inspect-image.sh` no longer starts `stat`, `awk`, and `sha256sum` processes for every file.

- Regular files are hashed in parallel with `xargs`.
- Each `xargs` process slot writes to its own temporary worker file.
- Worker files are merged only after successful hashing, preventing corrupted shared output.
- Metadata is collected with native `find -printf` formatting.
- Hashes are read from a NUL-terminated cache into a Bash map.
- The existing eight-column manifest format and sorted output remain unchanged.
- Progress is reported by entry count and time interval.

The fix was validated against a real generated image containing approximately 80,000 entries. The full A/B run completed all inspection phases successfully.

## Backup Boot Test Scope

Use `guest-root.qcow2` from an A/B result for the backup boot test:

```bash
cd tests/ab
./run-backup-boot-test.sh prepare
./run-backup-boot-test.sh all artifacts/testresult20260908T083231Z/local/guest-root.qcow2
```

Do not use `guest-backup.img` from the A/B result as the boot-test input. It is the raw ext4 backup disk created inside the guest and has no partition table or boot partition; the boot test rejects it. A standalone `.img` is valid only if it is a bootable partitioned disk image.

The boot test uses the generic ARM64 kernel and initramfs from the prepared cache, the generated test SSH key, and local QEMU. A/B `guest-root.qcow2` files are QEMU-only validation artifacts, not physical Raspberry Pi SD-card images.

## How to Resume

Run commands from `tests/ab` unless an absolute path is shown:

```bash
# Reuse or build the prepared cache and boot-validate it.
./run-ab-test.sh prepare

# Check guest tools and the separate backup disk without running candidates.
./run-ab-test.sh preflight

# Run upstream/local initial and incremental comparisons.
./run-ab-test.sh all

# Stop test QEMU state while preserving cache and saved results.
./run-ab-test.sh cleanup

# `clean` is an alias for cleanup; `cleanall` also removes saved result directories.
./run-ab-test.sh clean
./run-ab-test.sh cleanall
```

For a manual comparison of an existing complete A/B result:

```bash
./helperScripts/compare-results.sh \
  artifacts/testresult20260908T083231Z/upstream/initial \
  artifacts/testresult20260908T083231Z/local/initial

./helperScripts/compare-results.sh \
  artifacts/testresult20260908T083231Z/upstream/incremental \
  artifacts/testresult20260908T083231Z/local/incremental
```

Both commands should exit `0` with no diff output.

Use `./run-ab-test.sh cleanall` only when saved result directories should also be removed. It preserves the reusable cache.

## Troubleshooting

For a failed A/B run, inspect the newest `testresult<UTC>` directory:

```bash
cat artifacts/testresultXXXXXXXXXXXXXX/result.log
cat artifacts/testresultXXXXXXXXXXXXXX/initial-comparison.log
cat artifacts/testresultXXXXXXXXXXXXXX/incremental-comparison.log
```

For a failed backup boot run:

```bash
cat artifacts/backup-boot-test<UTC>/result.log
cat artifacts/backup-boot-test<UTC>/sanity.log
```

For a port or stale-process failure, inspect the relevant `qemu-console.log` and
`result.log`. A QEMU bind failure must be treated as the root cause; do not use a
later guest mount error as the diagnosis. If cleanup reports a test-owned loop or
mount but non-interactive sudo is unavailable, authenticate in the host terminal
before rerunning cleanup.

Systemd `poweroff` lines and serial-console cursor sequences are not test results. The meaningful result is the final timestamped `[PASS]` or `[FAIL]` message and the command exit code.

If a comparison exposes a new runtime-only difference, update the patterns in `helperScripts/compare-results.sh`. Do not modify the pinned upstream candidate or the fixture behavior to hide a functional difference.

## Relevant Files

- `image-backup` - local system under test.
- `tests/ab/run-ab-test.sh` - A/B entrypoint.
- `tests/ab/run-backup-boot-test.sh` - backup boot entrypoint.
- `tests/ab/helperScripts/prepare-raspios-virt.sh` - prepared ARM64 guest cache.
- `tests/ab/helperScripts/qemu-guest.sh` - disposable A/B guest launcher.
- `tests/ab/helperScripts/remote-run.sh` - guest fixture, backup, and artifact flow.
- `tests/ab/helperScripts/inspect-image.sh` - read-only image inspection and manifests.
- `tests/ab/helperScripts/compare-results.sh` - normalized comparison rules.
- `tests/ab/helperScripts/cleanup.sh` - QEMU, mount, loop, and artifact cleanup.
- `tests/ab/config.example.env` - shareable configuration template.
- `tests/ab/config.env` - local ignored configuration.
- `tests/ab/README.md` - detailed user documentation.

## Validation Summary

The following checks were completed on 2026-09-09:

```text
bash -n on both root entrypoints and all six helper scripts: PASS
git diff --check: PASS
run-ab-test.sh prepare from repository root: PASS (previous baseline)
run-ab-test.sh prepare from tests/ab: PASS (previous baseline)
run-ab-test.sh all: PASS in testresult20260908T083231Z (previous baseline)
run-ab-test.sh preflight with port 2222 occupied: PASS in testresult20260909T101442Z
run-ab-test.sh cleanup without cached sudo: no prompt; nonzero because /dev/loop46 requires root
run-ab-test.sh all in testresult20260909T102629Z: FAIL, local initial phase exit 255
run-ab-test.sh all in testresult20260909T110258Z: FAIL, comparisons before directory-size fix
manual initial and incremental comparison on testresult20260909T110258Z: PASS after directory-size normalization
run-backup-boot-test.sh prepare: PASS (previous baseline)
run-backup-boot-test.sh all: PASS (previous baseline)
```

No full test run is currently pending. The failed `testresult20260909T102629Z`
run requires diagnosis before another long run is reported as successful. No Git
commit has been created.
