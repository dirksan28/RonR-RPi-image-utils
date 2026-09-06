# RonR-RaspberryPi-image-utils

**NB** scruss is *not* the author or maintainer of these files (same goes for seamusdemora, who assumed maintenance of this repo from scruss). Please take up any issues or questions in the [Image File Utilities](https://forums.raspberrypi.com/viewtopic.php?t=332000) thread of the Raspberry Pi Forums site. ***IOW: This is a file repository only; no support is available here.***

Files here are a toolset to create and update a backup of a running RPi OS to a raw image file. The files are copies of those posted on the Raspberry Pi Forums site. The file attachments in that forum don't seem to be persistent (*and are subject to other annoyances imposed by CloudFlare*). Consequently, this repo was created by user scruss and is now maintained by seamus, *to ensure* a current working copy of *`image-utils`* is always available through `git`.

## An Overview

I've used RonR's `image-utils` for several years now, and I've become a big fan. In addition to this README, I've made a couple of [posts on StackExchange re `image-utils`](https://raspberrypi.stackexchange.com/a/109364/83790) as a backup solution. `Image-utils` creates a complete backup of a Raspberry Pi quickly and efficiently; these backups are rendered in the form of an [*"image file"*](https://en.wikipedia.org/wiki/IMG_(file_format)). The **\*.img** format is ideal as a backup because it's a _complete_ backup, it's _portable_, and it can be [_loop-mounted_](https://en.wikipedia.org/wiki/Loop_device). In other words: _If your system or SD card or NVME drive becomes corrupted, it can be restored to operation with minimal effort_. This restoration requires 3 "ingredients", and about 5 minutes:

   * The *raw image* backup file (`*.img`) file - created by `image-backup` 
   * A micro SD card (or NVME drive)
   * [`Etcher`](https://etcher.balena.io/) to write the `.img` file to the micro-SD card (or NVME drive)

The speed and efficiency of `image-backup` are especially noteworthy. Because `image-backup` uses `rsync` for file copying and syncing, a backup requires only the storage space that is actually used by your system. This is **not the same as `dd`**: 
   1. `dd` has no way to tell which portions of your drive/SD card are being used **versus** which portions are not, **because** `dd` has no concept of a file. Consequently, a `dd` backup of a 32 GB SD card requires: ...**32GB**!!
   2. Because of this fundamental limitation, `dd` is *"v-e-r-y&nbsp;&nbsp;&nbsp;s-l-o-w"*, and inefficient of space utilization.
   3. By comparison, `image-backup` typically requires a small fraction of the time required for a `dd` backup, and the image occupies a small fraction of the space required for a `dd` backup.
   4. `image-utils` can easily and accurately make a backup wile running on a ***live system***; whereas `dd` will **_always fail_** if used to make a backup of a live system. Using `dd` to make a backup requires the SD card (or NVME) first be un-mounted!
   5. The raw image file produced by `image-backup` can be used in a number of interesting ways - as described by Hiks Gerganov in [this post on Baeldung](https://www.baeldung.com/linux/img-raw-image-dump-file-management)

By comparison, for my systems (Lite; running headless), a backup of a 32GB SD card requires typically a 3-5GB \*.img file, and 5-10 minutes; that includes the time for network transfer to a NAS device. 

Another efficiency of `image-utils` is its ability to **update an \*.img file**. In other words, instead of creating an entire new \*.img file from scratch, it can **update** an existing \*.img file to incorporate any changes to the filesystems _since the last backup_. This ability to **update** further reduces the time required for a backup from 5-10 minutes to (potentially) seconds.

## How Do I Use This Repo?

This repo was created to make a current copy of the RPi `image-utils` toolset available through `git`. There are many resources available online describing the use of `git`, so these instructions are minimal. If you have questions, please consult a tutorial of your own choosing. The instructions below reflect using `bash` from a Raspberry Pi OS terminal or SSH, and assume that `git` is installed: 

### 1. clone the repo
```bash
$ cd && pwd
/home/pi
$ git clone https://github.com/seamusdemora/RonR-RPi-image-utils.git
```
#### which should yield (something like) the following results:
```
$ git clone https://github.com/seamusdemora/RonR-RPi-image-utils.git
Cloning into 'RonR-RPi-image-utils'...
remote: Enumerating objects: 161, done.
remote: Counting objects: 100% (94/94), done.
remote: Compressing objects: 100% (69/69), done.
remote: Total 161 (delta 59), reused 44 (delta 24), pack-reused 67
Receiving objects: 100% (161/161), 57.62 KiB | 1.92 MiB/s, done.
Resolving deltas: 100% (95/95), done.
$
```
#### NOTE THAT a new folder named: 'RonR-RPi-image-utils' has been created


### 2. take a look around & verify the 'git clone' operation succeeded:
```bash
$ ls -la RonR-RPi-image-utils
drwxr-xr-x  2 pi pi  4096 Feb 26 15:29 deprecated
drwxr-xr-x  8 pi pi  4096 Feb 26 15:29 .git
-rw-r--r--  1 pi pi 14084 Feb 26 15:29 image-backup
-rw-r--r--  1 pi pi  1534 Feb 26 15:29 image-check
-rw-r--r--  1 pi pi  3714 Feb 26 15:29 image-chroot
-rw-r--r--  1 pi pi  3399 Feb 26 15:29 image-compare
-rw-r--r--  1 pi pi  3107 Feb 26 15:29 image-info
-rw-r--r--  1 pi pi  1667 Feb 26 15:29 image-mount
-rw-r--r--  1 pi pi  5711 Feb 26 15:29 image-set-partuuid
-rw-r--r--  1 pi pi  4150 Feb 26 15:29 image-shrink
-rw-r--r--  1 pi pi 13740 Feb 26 15:29 README.md
-rw-r--r--  1 pi pi  4086 Feb 26 15:29 README.txt
$
```
The README.md is *this document - the one you're reading now*. The `README.txt` file contains RonR's user's guide for image-utils. The `deprecated` folder contains an old file discarded by RonR some time ago. The `.git` folder contains all of the "stuff" that makes `git` work. And the ***`image-*`*** files are the ***`image-utils`*** files. We'll discuss what to do with the ***`image-utils`*** files below. 


### 3. keep your clone synced to stay current:
Changes to `image-utils` are infrequent, but they do happen from time to time. You'll want to keep your copies updated to match the latest release. Here's how:

```bash
$ cd ~/RonR-RPi-image-utils
$ git config pull.rebase false    # this only needs to be done one time (the first time)
$ git pull                        # all subsequent updates require only this command 
```

## Staging & Usage 

Once you've cloned the `image-utils` files to your local git repo, you'll likely find they are much easier to use by following the very simple **`install`** procedure below. **Assuming that `/usr/local/sbin` is in your PATH**, using this `install` procedure makes the utilities easier to use from the command line, or (for example) in a `cron` job. Here's how to install:

```bash
$ cd
$ sudo install --mode=755 ~/RonR-RPi-image-utils/image-* /usr/local/sbin
```

## Creating vs. Updating .img backups

Refer to the [Image File Utilities](https://forums.raspberrypi.com/viewtopic.php?t=332000) thread of the Raspberry Pi Forums site for documentation & support. The following is offered only as an illustration/example:

### Create the .img backup:

To create a ***NEW*** image backup, use the `sudo image-backup` command; you will be prompted for inputs. The ones I typically use are shown below - immediately following the question mark `?`:

```
$ sudo image-backup

Image file to create? /mnt/SynologyNAS/rpi_share/raspberrypi3b/20230212_Pi3B_imagebackup.img

Initial image file ROOT filesystem size (MB) [2317]? 2400

Added space for incremental updates after shrinking (MB) [0]? 200

Create /mnt/SynologyNAS/rpi_share/raspberrypi3b/20230212_Pi3B_imagebackup.img (y/n)?y
```

This will take a few minutes depending on your model Pi, the size of your file system & other variables. Upon completion, you should find the image file you specified in the location specified in your answer to the first prompt/question above. This image file contains everything exactly as it was in your file system at the time of the backup. This image file may be written to an SD card, or `mount`-ed as another file system on your RPi (you can use the `image-mount` utility for this). 

### Update an existing .img backup:

To **update** the image file you have created is even easier; `sudo image-backup <IMG_TO_UPDT>`, or:

```bash
$ sudo image-backup /mnt/SynologyNAS/rpi_share/raspberrypi3b/20230212_Pi3B_imagebackup.img
```

In other words, simply add the URL of the .img file you wish to update to the basic `sudo image-backup` command.

## *Bon Voyage*  

This concludes the README.md file. Once again, any and all questions re `image-utils` should be submitted to [RonR's forum page](https://forums.raspberrypi.com/viewtopic.php?t=332000).

---
## This Version's Benefits

This fork's `image-backup` adds several improvements and safeguards over the upstream version.

| Benefit | Upstream | Local |
|---------|----------|-------|
| External drive / bind-mount exclusion | Hardcoded `/media` and `/mnt` only | Automatic: scans all mount points via `findmnt` and excludes any whose source is not the root partition |
| Symlink-to-external-drive exclusion | None | Scans symlinks (`find / -maxdepth 3 -type l`) and excludes those resolving to another partition |
| Backup-target protection | None (relies on `/media`/`/mnt`) | Excludes `${TARGET_MNT}`, the mount point where the image file is written |
| `/var/tmp` exclusion | Not excluded | Excluded in both the initial and incremental rsync (no `systemd-private-*` runtime dirs) |
| Boot partition copy | Implicit (rsync descends into the mounted boot partition) | Explicit rsync of the boot partition contents, required because the dynamic exclusion would otherwise skip it |
| Configurable temp directory | Hardcoded `/tmp` | `MY_TMP="${TMPDIR:-/tmp}"` — set `TMPDIR` to relocate the temporary mount point used during backup |
| Automated A/B test harness | None | Pinned upstream revision vs. local version booted in disposable QEMU guests; validates compatibility using normalized manifests |

### Why this matters

- **No accidental inclusion of other drives**: upstream only skips `/media` and `/mnt`. A drive mounted at `/data`, `/home/...`, or `/srv` (OpenMediaVault) would be backed up by upstream, potentially producing a huge image or recursing into the backup target.
- **Cleaner images**: `/var/tmp` runtime directories are excluded, so images contain only real data.
- **Boot partition preserved**: the explicit boot copy keeps the image bootable even though the dynamic exclusion treats `/boot/firmware` as a foreign mount point.
- **Works on RAM-disk-heavy systems (OpenMediaVault)**: upstream hardcodes its temporary mount point under `/tmp`. On systems where `/tmp` is a RAM disk — OpenMediaVault uses one heavily — a full backup can exhaust RAM and abort with *"no space left on device"*. The local version reads the `TMPDIR` environment variable, so you can point it at a directory on an external drive and avoid the RAM-disk limit entirely, e.g.:

  ```bash
  TMPDIR=/mnt/backup/tmp sudo image-backup ...
  ```

### A/B test harness — safe, upstream-compatible changes

The test harness is not just a pass/fail check — it's the safety net that makes modifying `image-backup` with confidence:

* **Verifies upstream compatibility**: Every run boots the pinned upstream revision (https://github.com/seamusdemora/RonR-RPi-image-utils.git) and the local version in identical disposable QEMU guests, then compares normalized boot/root manifests and partition tables. A pass means the local image is functionally equivalent to upstream's, apart from intentional differences.
* **Catches regressions early**: Any accidental behavior change (missing files, wrong permissions, dropped boot contents, unintended exclusions) shows up as a diff instead of silently shipping in a backup.
* **Filters out runtime noise**: `RUNTIME_EXCLUDE_PATTERNS` normalize machine-id, logs, caches, and other per-boot state, so only *real* functional differences surface — you don't chase false positives from two fresh boots.
* **Reproducible and disposable**: By pinning source revisions against the `seamusdemora/RonR-RPi-image-utils.git` repository, utilizing checksums, and running throwaway QEMU guests to emulate the ARM architecture locally, you can safely iterate on `image-backup` and re-run tests. You get a trustworthy environment every time—without touching a physical Pi or risking real data.
* **Documents the intended delta**: The comparison explicitly asserts the one behavior that *should* differ — the local dynamic exclusion of external mounts — so future changes can preserve or extend it deliberately.

**In short**: you can change `image-backup` with confidence, because the A/B test tells you immediately whether the result is still compatible with the upstream version.

See the [test documentation](tests/ab/README.md) for details.

<!--- 
You can hide shit in here  :)   LOL 
---> 

