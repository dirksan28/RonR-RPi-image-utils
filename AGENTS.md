# Main Image Utility Instructions

## Scope

These instructions apply specifically to the root-level `image-*` utilities in this repository, including `image-backup`, `image-check`, `image-chroot`, `image-compare`, `image-config`, `image-info`, `image-mount`, `image-set-partuuid`, and `image-shrink`.

When a task also changes files under `tests/ab/`, follow `tests/ab/AGENTS.md` for the A/B harness rules. Do not apply the image-utility header and comment requirements mechanically to the test harness or generated artifacts.

## Header Comments and Synopsis

Every changed root-level `image-*` script must begin with a concise header comment immediately after its Bash shebang. The header must:

- state what the script does
- identify the relevant safety or operational purpose when it is not obvious
- include a `Synopsis` section
- document the command name, positional arguments, options, defaults, and meaningful modes

Keep the synopsis synchronized with the actual command-line interface. When behavior or options change, inspect the existing usage function and update both the header synopsis and the usage output when necessary. Do not describe options that the script does not implement.

Use the established format:

```bash
#!/bin/bash
# image-example performs one focused image operation.
#
# Synopsis:
#   Usage: image-example [options] imagefile
#   -h,--help       This usage description
```

Keep the header concise enough to scan before reading the implementation. Link the reader to `README.md` or the relevant existing documentation section when more explanation is needed instead of duplicating a full user guide in the script.

## Inline Documentation

Use comments in changed scripts to explain intent, safety constraints, image layout assumptions, filesystem or partition behavior, cleanup requirements, and non-obvious control flow. Comments are especially useful around loop-device attachment, mount and unmount ordering, live filesystem copying, partition-table changes, generated first-boot helpers, and failure cleanup.

Do not add comments that merely narrate assignments, simple conditionals, or obvious shell syntax. Keep comments next to the code they explain, and update nearby comments when a change makes them inaccurate. Preserve the existing comment style and avoid unrelated comment rewrites.

## README and Documentation Maintenance

For a major behavior, command-line interface, safety, or workflow change, inspect the repository-root `README.md` before editing and update the applicable existing section when the documented user-facing contract is no longer accurate. Consult `README.txt` as well when the changed behavior is covered by the legacy user guide.

Do not modify existing documentation for an internal refactor, comment-only cleanup, or test-only adjustment that does not change the documented behavior. Documentation changes must be necessary and focused.

Keep the human-facing `README.md` coherent and consolidated. Prefer updating the existing section that owns the topic over adding a new fragment, and do not duplicate the same guidance in multiple scattered sections. Avoid broad README rewrites, formatting churn, and unrelated corrections while changing an image utility.

## Implementation and Validation

- Preserve Bash syntax and the existing public command-line interface unless the task explicitly changes it.
- Preserve root-privilege checks, loop-device cleanup, mount teardown, and error handling unless the task requires a behavior change.
- Keep documentation-only changes separate from executable behavior changes when practical.
- After changing a script, run syntax checks for the affected utilities, for example:

```bash
bash -n image-backup image-check image-chroot image-compare image-config image-info image-mount image-set-partuuid image-shrink
```

- From the repository root, run:

```bash
git diff --check
```

- Do not claim runtime validation for an image utility unless the required root privileges, image fixture, and relevant host tools were actually available and the command completed successfully.
