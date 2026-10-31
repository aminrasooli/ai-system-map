# Boot safety preflight (Safe Update Guard)

`scripts/check-boot-safety.sh` answers one question before an upgrade or a
reboot:

> Will the kernel that boots **next** still have its GPU driver, and if it
> does not, is a known-good kernel still available to fall back to?

It is read-only. It never installs, builds, loads, holds, reboots or changes
the bootloader. Where it lacks permission or does not understand the
platform, it says `UNKNOWN` and why.

## The failure it catches

A common and expensive sequence on NVIDIA hosts that use the distribution's
prebuilt driver modules:

1. The kernel meta-package (for example `linux-generic` or an HWE variant)
   is not held, so a routine update installs a newer kernel image.
2. The prebuilt NVIDIA module package for that kernel is not installed:
   it is held back because the driver packages are pinned, not yet
   published, or it requires a newer userspace driver than the one installed.
3. The bootloader's default entry is "the newest kernel".
4. The next reboot comes up with no NVIDIA driver. Anything that needs the
   GPU (inference servers, CUDA jobs, a power-limit service, the desktop)
   fails, often with no obvious message until someone logs in.

The same shape occurs with DKMS when the module did not build, and with a
driver upgrade that leaves older kernels holding modules of the previous
version (the userspace library only talks to a module of the same version).

The preflight makes each link in that chain visible *before* the reboot.

## What it checks

| Finding id | Question |
|---|---|
| `kernels.installed`, `kernels.running`, `kernels.module_trees` | Which kernels exist, which is running, do they all have module trees? |
| `boot.next_kernel` | Which kernel will boot next (GRUB `next_entry` one-time boot, `saved_entry`, literal `GRUB_DEFAULT`, or systemd-boot `default`), and on what evidence? |
| `gpu.nvidia` | Is an NVIDIA GPU present on PCI? Is a userspace driver installed? What module is loaded? |
| `gpu.driver.modules` | For every installed kernel: NVIDIA module present, its version, prebuilt or DKMS-built. |
| `gpu.driver.dkms` | DKMS source present, and for which kernels a module was actually *built*. |
| `gpu.driver.next_boot` | Does the next-boot kernel have a module matching userspace? **BLOCKED** if not. |
| `gpu.driver.running` | Does the loaded module match userspace (post-upgrade mismatch)? |
| `gpu.fallback` | Is there another installed kernel with a matching module? |
| `boot.secure_boot` | EFI Secure Boot state; a DKMS module under Secure Boot needs an enrolled signing key. |
| `packages.holds` | (dpkg hosts) Are driver packages held while the kernel meta-package is not? |
| `packages.state` | (dpkg hosts) Interrupted package transactions; two driver versions installed at once. |
| `packages.simulation` | (dpkg hosts) What `apt-get -s upgrade` (or `--simulate-install PKG...`) would remove, orphan or version-split. |
| `boot.reboot_required` | Is a reboot already pending? |

Statuses: `PASS`, `WARNING` (review before acting), `BLOCKED` (do not reboot
into that kernel as it stands), `UNKNOWN` (could not be verified from this
account or platform). The overall result is the worst finding; the exit code
follows it: `0` PASS, `1` WARNING, `2` BLOCKED, `3` UNKNOWN, `64` usage error.

## What it does not do

- It does not fix anything. The `BLOCKED` text lists the options; a human or
  a supervised agent performs them.
- It does not treat a clean `apt-get -s` as proof that a DKMS module will
  compile. A simulation shows package resolution only. Verify a DKMS build
  with `dkms status` after installing and before rebooting.
- It does not read root-only files. On most distributions `grub.cfg` is
  root-only, so the next-boot kernel is resolved from `/etc/default/grub`,
  the GRUB environment block and the installed kernel images, and the report
  says so. Run it as root (or re-run with `--target`) when you need
  certainty.
- It understands GRUB and systemd-boot. Other bootloaders report `UNKNOWN`
  for the next-boot kernel; the per-kernel module checks still run against
  the newest installed kernel.
- Package checks are implemented for dpkg/apt hosts. On other distributions
  they report `UNKNOWN`; kernel, bootloader and module checks still apply.

## Usage

```bash
# Before any reboot
bash scripts/check-boot-safety.sh

# Before a planned one-time boot into a specific kernel (grub-reboot)
bash scripts/check-boot-safety.sh --target 6.8.0-50-generic

# Before a specific package transaction
bash scripts/check-boot-safety.sh --simulate-install nvidia-dkms-560 linux-image-6.8.0-50-generic

# For a watchdog or an agent
bash scripts/check-boot-safety.sh --json > boot-safety.json
```

Example `BLOCKED` output on a fictional host:

```
[WARNING] boot.next_kernel: next boot is 6.8.0-50-generic, not the running 6.8.0-45-generic
          - GRUB_DEFAULT=0 -> entry 0 = newest installed kernel (GRUB sorts by version; grub.cfg not readable to confirm)
[PASS   ] gpu.driver.modules: per-kernel NVIDIA module inventory
          - 6.8.0-45-generic: module 550.10.01 (packaged)
          - 6.8.0-50-generic: NO nvidia module
[BLOCKED] gpu.driver.next_boot: next boot kernel 6.8.0-50-generic has NO NVIDIA module
          - 6.8.0-50-generic has no nvidia.ko in /lib/modules/6.8.0-50-generic
          - booting 6.8.0-50-generic would bring the system up without the NVIDIA driver
[PASS   ] gpu.fallback: GPU-capable fallback kernel(s): 6.8.0-45-generic (550.10.01)
```

## JSON output

`--json` prints one object (schema `ai-system-map/boot-safety/1`):

```json
{
  "schema": "ai-system-map/boot-safety/1",
  "generated": "2026-01-02T09:14:31Z",
  "overall": "BLOCKED",
  "exit_code": 2,
  "host": {
    "os": "Example Linux 42",
    "bootloader": "grub",
    "running_kernel": "6.8.0-45-generic",
    "installed_kernels": ["6.8.0-45-generic", "6.8.0-50-generic"],
    "next_boot": {"kernel": "6.8.0-50-generic", "basis": "GRUB_DEFAULT=0 -> ...", "one_time": false},
    "gpu": {"nvidia_present": true, "userspace_version": "550.10.01", "loaded_module_version": "550.10.01"}
  },
  "findings": [
    {"id": "gpu.driver.next_boot", "status": "BLOCKED", "summary": "...", "evidence": ["..."]}
  ]
}
```

`nvidia_present` is `true`, `false`, or the string `"UNKNOWN"` when the PCI
tree was unreadable. A watchdog can key on `overall` and `exit_code`, and
quote `findings[].evidence` verbatim in its report.

## Fitting it into an operating practice

- Run it in the same step as "is a reboot pending?" in any host check.
- Run it with `--target` as the last gate before `grub-reboot`.
- Hold the kernel meta-package on hosts that pin their GPU driver, so new
  kernels stop arriving ahead of their module. The `packages.holds` finding
  points this out when it is not the case.
- Keep at least one proven kernel with a matching module installed and
  selectable until the new one has booted with a working GPU.

## Testing

`tests/test-boot-safety.sh` builds each scenario as a synthetic host under a
temporary directory (fake boot directory, module trees, GRUB or systemd-boot
files, PCI tree, DKMS tree, and stub `modinfo`/`dkms`/`apt-get`/`apt-mark`/
`dpkg-query`/`mokutil`) and drives the script through its `BOOTCHK_*`
environment seams. The stub `apt-get` refuses to run without `-s`, so a
regression that dropped the simulation flag would fail the suite rather than
touch a real system. All names and versions in the fixtures are invented.
