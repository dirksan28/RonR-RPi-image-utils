# Local QEMU ARM Image-Backup A/B Test

Build a manually invoked A/B integration harness that starts local QEMU ARM64 Raspberry Pi OS guests and runs upstream and current `image-backup` scripts independently against equivalent disposable guest overlays. It tests initial creation and incremental updates, then compares mounted output images by normalized content manifests and structural metadata. It does not require raw `.img` byte equality, because filesystem metadata and timestamps legitimately differ.

## Prerequisites and inputs

- Provide or resolve a pinned upstream `image-backup` revision before execution. The supplied GitHub URL returned HTTP 404 through the available fetcher, so the implementation must accept a commit SHA, trusted local upstream script, or verified raw GitHub URL rather than assume that URL resolves.
- Install `qemu-system-aarch64`, `qemu-img`, SSH client tools, and the standard shell tools on the development machine.
- Provide a prepared ARM64 Raspberry Pi OS base image, an ARM64 kernel that boots it on QEMU's `virt` machine, and an SSH private key accepted by the guest. The base image remains immutable.
- Create a QCOW2 root overlay and a fresh raw backup disk per candidate. The guest formats and mounts the backup disk at `/mnt/backup`; preflight aborts if it resolves to the guest root source.

## Steps

1. **Define fixtures and source pinning**
   - Add an A/B test directory containing an environment file for QEMU base-image/kernel paths, guest SSH credentials, backup mountpoint, upstream script source and revision, and output location.
   - Add a local launcher that creates the disks, starts QEMU with localhost SSH forwarding, and transfers the checked-in local `image-backup` plus the pinned upstream script to deterministic guest paths.
   - Discard each candidate overlay and backup disk after its artifacts have been collected, so both candidates begin from the same immutable base image.

2. **Provision an equivalent ARM guest state**
   - Provision common test fixtures before either backup: controlled ordinary files, executable files, symlinks, a bind mount, and a mount on the backup disk. Ensure volatile paths that `image-backup` excludes are not used as comparison fixtures.
   - Install runtime packages non-interactively and capture the mount topology, root source, and backup-disk source as artifacts for diagnosis.

3. **Run initial-backup A/B cases**
   - Execute the upstream script in one pristine guest to create an image on `/backup`, using noninteractive flags and `--noexpand` to avoid the generated first-boot resize/reboot side effect.
   - Execute the local script in the equivalent pristine guest with the same image size and options. Store guest console logs, script exit status, image size, partition table dump, filesystem labels, and `image-check` output separately for each variant.
   - Assert each run completes successfully, creates a readable DOS/GPT image with boot and root partitions, and leaves no attached loop device or mountpoint behind.

4. **Run incremental-backup A/B cases**
   - In each guest, apply the same deterministic mutation set after initial backup: create, alter, delete, chmod, chown where supported, and change symlink targets for test fixtures.
   - Run the corresponding script against its own existing image. Capture the same artifacts and verify expected changes. The external mount and symlink fixtures intentionally distinguish the candidates: they may appear in upstream output but must be absent from the local candidate output.

5. **Extract normalized comparison manifests**
   - Add an inspection script on the runner that attaches each generated output image read-only through a loop device, mounts boot and root partitions in isolated temporary directories, and guarantees cleanup with a shell trap.
   - Generate a sorted manifest for each image root containing path, entry type, mode, uid, gid, file size, symlink target, and SHA-256 checksum for regular files. Exclude expected volatile/generated entries such as `/etc/resize-root-fs` and `/etc/rc.local` changes only when `--noexpand` is not used; the selected `--noexpand` mode should make the baseline comparison simpler.
   - Generate structural reports using `sfdisk --dump`, `blkid`, filesystem labels, and `image-check`. Compare the reports after filtering inherently variable identifiers such as filesystem UUIDs and image allocation metadata.

6. **Compare and report results**
   - Add a comparison script that diffs upstream and local manifests for initial and incremental cases, reports only normalized differences, and exits nonzero for unexpected paths or metadata differences.
   - Add explicit assertions for the local changes: local output logs must show detected external mount/symlink exclusions when fixtures trigger them; external bind-mount content must be absent from the local manifest; the destination mountpoint must be excluded; and both `rsync` phases must complete.
   - Produce a concise artifact summary containing script revision, runner kernel and package versions, exit codes, image checks, structural diff, and manifest diff.

## Relevant files

- `image-backup`: System under test; preserve its current command-line contract and use it as the local A/B candidate.
- `image-check`: Reuse to validate each produced image after initial and incremental runs.
- `README.md`: Reference for intended root execution, external destination behavior, and dependencies.
- `tests/ab/`: Test harness location for QEMU configuration, guest provisioning, image inspection, comparison, and documentation.

## Verification

1. Run shell syntax checks for every harness script with `bash -n`.
2. Run a QEMU preflight that verifies guest SSH access, root privileges, loop-device availability, and that `/mnt/backup` differs from the guest root filesystem source.
3. Run the upstream and local initial cases; require success, valid images, and no unexpected normalized manifest differences.
4. Run the corresponding incremental cases after identical deterministic guest mutations; require success, valid images, expected changed/deleted fixture state, and no unexpected normalized manifest differences.
5. Confirm local output logs demonstrate exclusion detection and external-mount content is absent from the local image manifest; record the intentional upstream/local fixture difference separately from regressions.
6. Retain all logs and normalized reports when a comparison fails so differences are reproducible and reviewable.

## Decisions and scope

- Included: manually launched local shell command, local QEMU ARM64 Raspberry Pi OS guests, disposable guest overlays, initial/incremental backups, structural checks, normalized root/boot filesystem comparison, and external mount/symlink exclusion coverage.
- Excluded: GitHub Actions workflow execution, byte-for-byte image comparison, performance benchmarking, developer-host root execution, containers, and booting the resulting images.
- Use `--noexpand` for both variants so image contents are comparable and the generated first-boot resize/reboot behavior is not invoked during the A/B test.
