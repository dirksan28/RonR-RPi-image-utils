# A/B Test Harness Instructions

## Scope

These instructions apply to `tests/ab/` and all of its descendants. This directory contains the local QEMU ARM64 integration harness that compares the repository's `image-backup` with a pinned upstream revision and verifies bootable backup images.

Keep changes here focused on the harness, its documentation, and its test artifacts. Do not change the image utilities in the repository root unless the task explicitly requires it.

## Repository Layout

- `run-ab-test.sh` is the main orchestrator. It prepares the guest, runs the upstream and local candidates sequentially, compares their artifacts, and owns the condensed run log.
- `run-backup-boot-test.sh` boots a previously created bootable image and runs focused sanity checks.
- `helperScripts/` contains guest preparation, QEMU, SSH, cleanup, inspection, and comparison helpers.
- `config.example.env` is the shareable configuration template. `config.env` is a local, sourced Bash configuration file.
- `agentic-context/` contains handovers and plans. It is documentation context, not the execution surface for the harness.
- `artifacts/` and `cache/` contain generated test data and must be treated as disposable or retained test output, not source files.

## Bash Conventions

- Run these scripts with Bash. Do not replace Bash-specific syntax with POSIX `sh` syntax.
- Preserve `set -euo pipefail` and existing cleanup traps unless the task specifically changes error handling.
- Keep helper exit statuses accurate. The orchestrator must be able to convert a helper failure into a visible `[FAIL]` record and a nonzero final exit status.
- Keep verbose command output in phase-specific artifact logs. The terminal and `result.log` should contain concise, useful status messages.
- Add comments only for intent, safety constraints, or non-obvious control flow. Do not add comments that merely restate shell syntax.

## Language and Generated Artifacts

- Keep harness scripts, generated guest files, fixtures, and other executable artifacts in Bash or another shell-script form consistent with this subtree.
- Do not add Python, Perl, Node.js, or other non-shell source files or generated artifacts when the task can be implemented in shell.
- A one-off non-shell command is acceptable for read-only host inspection or validation only when it creates no repository artifact; do not turn it into a checked-in helper or guest file.
- If a non-shell source or generated artifact is genuinely unavoidable, stop before creating it and prompt the user for explicit approval, explaining why shell is insufficient and what would be added.

## Host Port and Guest Ownership

- In `run-ab-test.sh`, treat `SSH_PORT` as the first requested host port, not as proof that the port is free. Before starting QEMU, check for a listener and select a nearby available port when necessary; record the selected port in `result.log` and use it consistently for QEMU, SSH, and SCP.
- After launching QEMU, monitor the runner's child process while waiting for SSH. Never accept a successful SSH connection from a stale or unrelated guest after this run's QEMU process has exited.
- If QEMU exits before SSH becomes ready, return its nonzero status, preserve the QEMU console log, and report the startup failure. Do not continue to guest setup or interpret a later mount error as the root cause.
- Record the active runner PID and process start time below its artifact directory, remove the record on normal exit, and have cleanup use it to stop active test runners before removing their QEMU processes. Keep a command-line fallback for runs created before PID records existed.
- Cleanup must terminate only runners whose command line and working directory identify this repository, and only QEMU processes tied to this test workspace, cache, or forwarding port. Do not kill an unrelated listener; report its command and PID so it can be handled manually.
- Prefer direct child tracking or process substitution for QEMU console capture. Do not hide QEMU behind a `tee` pipeline whose wrapper can survive a failed QEMU startup and leave the orchestrator attached to the wrong process.

## Generated Guest Files and Candidate Parity

- Treat the body of every heredoc that writes a guest script, configuration file, or image content as generated test data. Its comments and whitespace become part of the artifact and can change manifests even when executable behavior is unchanged.
- Keep explanatory comments about generated helpers outside their heredocs unless the comments are intentionally part of the generated file. This preserves the distinction between documenting the generator and changing the guest artifact.
- When the local candidate is expected to match the pinned upstream candidate, preserve byte-for-byte parity for generated helpers and other deterministic files unless a behavior change is intentional and documented.
- Do not hide an unexpected generated-file difference by adding a broad comparison exclusion. First identify whether the difference comes from the generator, the fixture, or the comparison normalization.

## Documentation and Comments

- Treat a change as documentation-triggering when it changes a command or option, default, user-visible behavior, safety or privilege requirement, process/lifecycle handling, port ownership, artifact or logging contract, generated guest output, comparison behavior, or supported workflow. For those changes, check the applicable README before editing and update its owning section when the documented contract is no longer accurate. For this subtree, start with `tests/ab/README.md`; inspect the repository-root `README.md` when the change affects repository-wide usage.
- Review the nearby inline comments in every changed script. Update or add comments when the change affects intent, safety, or non-obvious control flow; do not add narration for self-explanatory code.
- An internal refactor, test-only adjustment, or bug fix that does not change the documented behavior does not require a README change, but its nearby comments and instructions must still be reviewed for accuracy. Documentation changes should be necessary, not automatic.
- Keep the human-facing README coherent and consolidated. Prefer updating the existing section that owns the topic over adding a new fragment, and do not duplicate guidance that already exists elsewhere.

## Configuration and Safety

- Run commands from `tests/ab` unless a command explicitly says otherwise.
- Create local configuration with `cp config.example.env config.env`; do not commit machine-specific `config.env` values.
- Treat generated SSH keys, raw images, QEMU overlays, caches, and timestamped artifacts as sensitive test data. Do not replace the harness's generated test keys with a personal SSH key.
- Use `cleanup` to remove runtime state while retaining results. Use `cleanall` only when deleting all saved test results is intentional.
- Cleanup must return nonzero and retain artifacts when a test runner, QEMU process, or configured SSH port remains; this prevents `cleanup && all` from starting over stale runtime state.
- Cleanup discovery must not require root. Only attempt privileged unmount or loop-detach operations after matching test-owned resources are found, use `sudo -n`, and report a warning plus nonzero status when root access is unavailable rather than prompting.
- Preserve partial artifacts after a failure so the failing phase can be diagnosed.

## Running the Harness

The supported actions are:

```bash
./run-ab-test.sh prepare
./run-ab-test.sh preflight
./run-ab-test.sh all
./run-ab-test.sh cleanup
./run-ab-test.sh clean
./run-ab-test.sh cleanall
```

`all` is a long-running QEMU test, commonly taking one to two hours. ARM emulation, filesystem checks, image inspection, and resize operations can be quiet for extended periods. Do not infer failure from a quiet terminal alone.

For a long run, start the command once and monitor the newest `artifacts/testresult<UTC timestamp>/result.log` approximately every 15 minutes. Read detailed QEMU, backup, inspection, or comparison logs only when the condensed log indicates a failure or diagnosis is needed. Do not delete the active artifact directory while the run is in progress.

The boot verification flow is:

```bash
./run-backup-boot-test.sh prepare
./run-backup-boot-test.sh all artifacts/testresult*/local/guest-root.qcow2
```

Use `guest-root.qcow2` for A/B boot verification. `guest-backup.img` is the raw ext4 backup disk inside the guest and is not a bootable partitioned image.

## Artifact and Logging Contract

Each invocation that creates results must use a timestamped directory below `artifacts/`, for example:

```text
artifacts/testresult20260909T084049Z/
```

The orchestrator owns the condensed `result.log`. Helpers should write detailed logs, status files, manifests, and phase artifacts, then return their actual exit status. The orchestrator records the user-facing summary.

Every meaningful progress milestone must be written to `result.log` as a timestamped `[INFO]` message. This includes preparation, guest startup, support deployment, backup-disk setup, candidate upload, each initial and incremental phase, artifact collection, comparison, cleanup, and shutdown. `[INFO]` is the progress record, not only a step-start marker.

Each meaningful major step must also have an outcome:

- Write `[PASS]` when the step completes successfully.
- Write `[FAIL]` when the step fails, including the stage and relevant exit status when available.
- Preserve the detailed diagnostic output in the timestamped artifact directory.

Every completed run must record a final exit-state message in the status section:

```text
[INFO] Success Exitcode: 0
```

or:

```text
[INFO] Fail Exitcode: <nonzero-status>
```

The artifact-directory location should also be recorded so a failure can be investigated without guessing which run produced the log. A run that ends after an `[INFO]` start message without a corresponding outcome and exit-state record is incomplete and should be diagnosed before being reported as successful.

## Validation

After changing a Bash script, run syntax checks from `tests/ab`:

```bash
bash -n run-ab-test.sh run-backup-boot-test.sh helperScripts/*.sh
```

Also run from the repository root:

```bash
git diff --check
```

Use `prepare` or `preflight` for focused executable validation when the configured host dependencies and cache are available. Run `all` only when the full A/B comparison is required; record its artifact directory and final exit status. Do not claim a full runtime test passed when only syntax or documentation checks were run.

When changing a generator such as `image-backup`, compare the generated helper body with the pinned upstream source before starting a long run. From the repository root, the current resize-helper check is:

```bash
local_helper=$(mktemp)
upstream_helper=$(mktemp)
trap 'rm -f "${local_helper}" "${upstream_helper}"' EXIT
sed -n '/cat <<\\EOF1 > .*resize-root-fs/,/^EOF1$/p' image-backup | sed '1d;$d' > "${local_helper}"
sed -n '/cat <<\\EOF1 > .*resize-root-fs/,/^EOF1$/p' tests/ab/cache/upstream-repo/image-backup | sed '1d;$d' > "${upstream_helper}"
diff -u "${upstream_helper}" "${local_helper}"
```

An empty diff is expected when the generated helper is not intentionally changed. If the pinned upstream cache is unavailable, perform the equivalent comparison against the generated helper in a retained A/B artifact or document why the parity check could not be run.
