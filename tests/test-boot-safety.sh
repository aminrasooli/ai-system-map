#!/usr/bin/env bash
# test-boot-safety.sh — fixture-driven tests for scripts/check-boot-safety.sh.
#
# Every scenario is a synthetic host built under a temporary directory: a fake
# boot directory, module trees, GRUB or systemd-boot files, a PCI tree, a DKMS
# tree, and stub `modinfo`/`dkms`/`apt-get`/`apt-mark`/`dpkg-query`/`mokutil`
# binaries. The script under test is pointed at them through its BOOTCHK_*
# seams, so these tests never read the real package database, never run the
# real apt, and work the same on any Linux host or CI runner. All version
# numbers and names below are invented.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$ROOT/scripts/check-boot-safety.sh"
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
cleanup() { chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

echo "AI System Map — boot safety tests"
echo "Root: $ROOT"

# ---------------------------------------------------------------- fixture kit
# mkfx NAME -> creates $TMP/NAME with the standard layout and stub binaries.
mkfx() {
  local fx="$TMP/$1"
  mkdir -p "$fx"/{boot/grub,modules,etc/default,pci,lib,dkms,bin,sdboot,efi}
  printf 'NAME="Example Linux"\nVERSION_ID="42"\n' >"$fx/etc/os-release"
  printf '6.8.0-45-generic\n' >"$fx/running"
  : >"$fx/holds.txt"; : >"$fx/dpkg-metas.txt"; : >"$fx/dpkg-state.txt"
  printf '0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n' >"$fx/apt-sim.txt"
  printf '0\n' >"$fx/apt-exit"
  : >"$fx/apt-calls.log"
  printf 'SecureBoot disabled\n' >"$fx/sb-state.txt"
  # modinfo: version comes from a sidecar file next to the module
  cat >"$fx/bin/modinfo" <<'EOF'
#!/bin/sh
# stub: modinfo -F version <path>
p="$3"; [ -f "$p.version" ] && { cat "$p.version"; exit 0; }; exit 1
EOF
  cat >"$fx/bin/dkms" <<EOF
#!/bin/sh
cat "$fx/dkms-status.txt" 2>/dev/null
EOF
  # apt-get: refuses to run without -s, so a regression that drops the
  # simulation flag fails loudly instead of touching a real system.
  cat >"$fx/bin/apt-get" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$fx/apt-calls.log"
case " \$* " in *" -s "*) ;; *) echo "STUB REFUSED: apt-get called without -s" >&2; exit 99 ;; esac
cat "$fx/apt-sim.txt"; exit "\$(cat "$fx/apt-exit")"
EOF
  cat >"$fx/bin/apt-mark" <<EOF
#!/bin/sh
cat "$fx/holds.txt"
EOF
  cat >"$fx/bin/dpkg-query" <<EOF
#!/bin/sh
case "\$*" in *'\${Package} \${db:Status-Abbrev}'*) cat "$fx/dpkg-metas.txt" ;; *) cat "$fx/dpkg-state.txt" ;; esac
EOF
  cat >"$fx/bin/mokutil" <<EOF
#!/bin/sh
cat "$fx/sb-state.txt"
EOF
  chmod +x "$fx"/bin/*
  printf '%s\n' "$fx"
}

# add_kernel FX VER [MODVER|none] [packaged|dkms]
add_kernel() {
  local fx="$1" v="$2" mv="${3:-none}" kind="${4:-packaged}" d
  : >"$fx/boot/vmlinuz-$v"
  mkdir -p "$fx/modules/$v/kernel/drivers"
  [ "$mv" = none ] && return 0
  if [ "$kind" = dkms ]; then
    d="$fx/modules/$v/updates/dkms"
    mkdir -p "$fx/dkms/nvidia/$mv/$v/x86_64/module"
    : >"$fx/dkms/nvidia/$mv/$v/x86_64/module/nvidia.ko.zst"
  else
    d="$fx/modules/$v/kernel/nvidia-example"
  fi
  mkdir -p "$d"; : >"$d/nvidia.ko.zst"; printf '%s\n' "$mv" >"$d/nvidia.ko.zst.version"
}
set_userspace() { : >"$1/lib/libnvidia-ml.so.1"; : >"$1/lib/libnvidia-ml.so.$2"; }
set_loaded()    { printf '%s\n' "$2" >"$1/nvsys"; }
set_gpu()       { mkdir -p "$1/pci/0000:01:00.0"; printf '0x10de\n' >"$1/pci/0000:01:00.0/vendor"; printf '0x030000\n' >"$1/pci/0000:01:00.0/class"; }
set_no_gpu()    { mkdir -p "$1/pci/0000:00:1f.0"; printf '0x8086\n' >"$1/pci/0000:00:1f.0/vendor"; printf '0x060100\n' >"$1/pci/0000:00:1f.0/class"; }
# set_grub FX DEFAULT_SETTING [saved_entry] [next_entry]
set_grub() {
  local fx="$1"
  printf 'GRUB_DEFAULT=%s\nGRUB_TIMEOUT=5\n' "$2" >"$fx/etc/default/grub"
  { printf '# GRUB Environment Block\n'; [ -n "${3:-}" ] && printf 'saved_entry=%s\n' "$3"; [ -n "${4:-}" ] && printf 'next_entry=%s\n' "$4"; } >"$fx/boot/grub/grubenv"
  touch -d '2020-01-02 00:00:00' "$fx/etc/default/grub"
  rm -f "$fx/boot/grub/grub.cfg"
  : >"$fx/boot/grub/grub.cfg"; chmod 000 "$fx/boot/grub/grub.cfg"   # root-only, like most distributions
  touch -d '2020-01-03 00:00:00' "$fx/boot/grub/grub.cfg" 2>/dev/null || true
}
# write_grub_cfg FX K1 K2... -> readable Ubuntu-shaped grub.cfg: entry 0 = K1, submenu with all
write_grub_cfg() {
  local fx="$1"; shift
  chmod 644 "$fx/boot/grub/grub.cfg"
  {
    printf "menuentry 'Example Linux' --class gnu-linux \$menuentry_id_option 'gnulinux-simple-0000' {\n\tlinux\t/vmlinuz-%s root=UUID=0000 ro quiet\n\tinitrd\t/initrd.img-%s\n}\n" "$1" "$1"
    printf "submenu 'Advanced options for Example Linux' \$menuentry_id_option 'gnulinux-advanced-0000' {\n"
    for k in "$@"; do
      printf "\tmenuentry 'Example Linux, with Linux %s' --class gnu-linux \$menuentry_id_option 'gnulinux-%s-advanced-0000' {\n\t\tlinux\t/vmlinuz-%s root=UUID=0000 ro quiet\n\t\tinitrd\t/initrd.img-%s\n\t}\n" "$k" "$k" "$k" "$k"
      printf "\tmenuentry 'Example Linux, with Linux %s (recovery mode)' --class gnu-linux \$menuentry_id_option 'gnulinux-%s-recovery-0000' {\n\t\tlinux\t/vmlinuz-%s root=UUID=0000 ro recovery nomodeset\n\t}\n" "$k" "$k" "$k"
    done
    printf "}\nmenuentry 'Memory test' \$menuentry_id_option 'memtest' {\n\tlinux16\t/memtest86+x64.bin\n}\n"
  } >"$fx/boot/grub/grub.cfg"
}

# run_fx FX [args...] -> runs the script against the fixture; output in $OUT, exit in $RC
run_fx() {
  local fx="$1"; shift
  OUT="$(BOOTCHK_BOOT_DIR="$fx/boot" BOOTCHK_MODULES_DIR="$fx/modules" \
    BOOTCHK_GRUBENV="$fx/boot/grub/grubenv" BOOTCHK_GRUB_CFG="$fx/boot/grub/grub.cfg" \
    BOOTCHK_GRUB_DEFAULTS="$fx/etc/default/grub" BOOTCHK_SDBOOT_DIRS="$fx/sdboot" \
    BOOTCHK_PCI_DIR="$fx/pci" BOOTCHK_NVIDIA_PROC_VERSION="$fx/nvproc" BOOTCHK_NVIDIA_SYS_VERSION="$fx/nvsys" \
    BOOTCHK_NVIDIA_LIBDIRS="$fx/lib" BOOTCHK_DKMS_DIR="$fx/dkms" BOOTCHK_OS_RELEASE="$fx/etc/os-release" \
    BOOTCHK_EFI_DIR="$fx/efi-absent" BOOTCHK_LOCKDOWN_FILE="$fx/lockdown" BOOTCHK_REBOOT_MARKERS="$fx/reboot-required" \
    BOOTCHK_RUNNING_KERNEL="$(cat "$fx/running")" \
    BOOTCHK_MODINFO_BIN="$fx/bin/modinfo" BOOTCHK_DKMS_BIN="$fx/bin/dkms" BOOTCHK_APT_GET_BIN="$fx/bin/apt-get" \
    BOOTCHK_APT_MARK_BIN="$fx/bin/apt-mark" BOOTCHK_DPKG_QUERY_BIN="$fx/bin/dpkg-query" BOOTCHK_MOKUTIL_BIN="$fx/bin/mokutil" \
    ${FX_EXTRA_ENV:+env $FX_EXTRA_ENV} bash "$SUT" "$@" 2>&1)"
  RC=$?
}
has()  { grep -qE "^\[$2 *\] $1:" <<<"$OUT"; }   # has ID STATUS
want() { # want "label" ID STATUS
  if has "$2" "$3"; then ok "$1: $2 is $3"; else bad "$1: expected $2 $3"; printf '%s\n' "$OUT" | grep -E "^\[" | sed 's/^/        /'; fi
}
want_rc() { if [ "$RC" -eq "$2" ]; then ok "$1: exit $2"; else bad "$1: exit $RC, expected $2"; fi; }
want_json() { # want_json "label" FX args...
  local label="$1"; shift
  run_fx "$@" --json
  if [ "$HAVE_JQ" = 1 ]; then
    if jq -e '.schema == "ai-system-map/boot-safety/1" and (.findings | length) > 0' <<<"$OUT" >/dev/null 2>&1; then ok "$label: JSON valid"; else bad "$label: JSON invalid"; printf '%s\n' "$OUT" | head -3 | sed 's/^/        /'; fi
  else
    case "$OUT" in '{"schema":"ai-system-map/boot-safety/1"'*'}') ok "$label: JSON shape (jq absent)" ;; *) bad "$label: JSON shape" ;; esac
  fi
}

echo
echo "== syntax =="
if bash -n "$SUT"; then ok "syntax: check-boot-safety.sh"; else bad "syntax: check-boot-safety.sh"; fi

# ---------------------------------------------------------------- scenarios
echo
echo "== 1. working kernel with matching module =="
fx="$(mkfx working)"; add_kernel "$fx" 6.8.0-40-generic 550.10.01; add_kernel "$fx" 6.8.0-45-generic 550.10.01
set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"
set_grub "$fx" saved 'Advanced options for Example Linux>Example Linux, with Linux 6.8.0-45-generic'
run_fx "$fx" --no-simulate
want working boot.next_kernel PASS; want working gpu.driver.next_boot PASS; want working gpu.driver.running PASS
want working gpu.fallback PASS; want working boot.secure_boot PASS; want_rc working 0
grep -q 'next boot:      6.8.0-45-generic' <<<"$OUT" && ok "working: next boot resolved from saved_entry title" || bad "working: next boot not resolved"
want_json working "$fx" --no-simulate

echo
echo "== 2. new kernel installed without its module; bootloader picks newest =="
fx="$(mkfx newmissing)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; add_kernel "$fx" 6.8.0-50-generic none
set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
run_fx "$fx" --no-simulate
want newmissing boot.next_kernel WARNING; want newmissing gpu.driver.next_boot BLOCKED; want newmissing gpu.fallback PASS
want_rc newmissing 2
grep -q 'without the NVIDIA driver' <<<"$OUT" && ok "newmissing: explains the consequence" || bad "newmissing: no consequence text"
grep -q '6.8.0-45-generic (550.10.01)' <<<"$OUT" && ok "newmissing: names the GPU-capable fallback" || bad "newmissing: fallback not named"

echo
echo "== 3. old fallback pinned as default remains GPU-capable =="
fx="$(mkfx pinned)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; add_kernel "$fx" 6.8.0-50-generic none
set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"
set_grub "$fx" saved 'Advanced options for Example Linux>Example Linux, with Linux 6.8.0-45-generic'
run_fx "$fx" --no-simulate
want pinned boot.next_kernel PASS; want pinned gpu.driver.next_boot PASS; want pinned gpu.fallback WARNING
grep -q '6.8.0-50-generic: NO nvidia module' <<<"$OUT" && ok "pinned: inventory flags the new kernel" || bad "pinned: inventory silent"
want_rc pinned 1

echo
echo "== 4. driver upgrade makes the old prebuilt fallback incompatible =="
fx="$(mkfx split)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; add_kernel "$fx" 6.8.0-50-generic 560.20.02
set_userspace "$fx" 560.20.02; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
run_fx "$fx" --no-simulate
want split gpu.driver.next_boot PASS; want split gpu.fallback WARNING; want split gpu.driver.running WARNING
grep -q 'do not match userspace 560.20.02' <<<"$OUT" && ok "split: fallback mismatch explained" || bad "split: mismatch not explained"
want_rc split 1

echo
echo "== 4b. next boot kernel's module does not match userspace =="
fx="$(mkfx mismatch)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; add_kernel "$fx" 6.8.0-50-generic 550.10.01
set_userspace "$fx" 560.20.02; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
run_fx "$fx" --no-simulate
want mismatch gpu.driver.next_boot BLOCKED; want_rc mismatch 2

echo
echo "== 5. DKMS modules present for both kernels =="
fx="$(mkfx dkmsok)"; add_kernel "$fx" 6.8.0-45-generic 560.20.02 dkms; add_kernel "$fx" 6.8.0-50-generic 560.20.02 dkms
printf 'nvidia/560.20.02, 6.8.0-45-generic, x86_64: installed\nnvidia/560.20.02, 6.8.0-50-generic, x86_64: installed\n' >"$fx/dkms-status.txt"
set_userspace "$fx" 560.20.02; set_loaded "$fx" 560.20.02; set_gpu "$fx"; set_grub "$fx" 0
run_fx "$fx" --no-simulate
want dkmsok gpu.driver.next_boot PASS; want dkmsok gpu.fallback PASS; want dkmsok gpu.driver.dkms PASS
grep -q 'module kind: dkms' <<<"$OUT" && ok "dkmsok: module kind reported as dkms" || bad "dkmsok: kind not dkms"
want_rc dkmsok 1   # next boot != running kernel is a WARNING by design

echo
echo "== 6. DKMS source present but module not built for the next kernel =="
fx="$(mkfx dkmsmissing)"; add_kernel "$fx" 6.8.0-45-generic 560.20.02 dkms; add_kernel "$fx" 6.8.0-50-generic none
mkdir -p "$fx/dkms/nvidia/560.20.02/source"
printf 'nvidia/560.20.02, 6.8.0-45-generic, x86_64: installed\n' >"$fx/dkms-status.txt"
set_userspace "$fx" 560.20.02; set_loaded "$fx" 560.20.02; set_gpu "$fx"; set_grub "$fx" 0
run_fx "$fx" --no-simulate
want dkmsmissing gpu.driver.next_boot BLOCKED
grep -q 'not guaranteed to succeed' <<<"$OUT" && ok "dkmsmissing: does not assume the build will succeed" || bad "dkmsmissing: assumes build"
grep -q '6.8.0-50-generic: dkms built for NOTHING' <<<"$OUT" && ok "dkmsmissing: dkms inventory shows nothing built" || bad "dkmsmissing: dkms inventory wrong"
want_rc dkmsmissing 2

echo
echo "== 7. no NVIDIA hardware =="
fx="$(mkfx nogpu)"; add_kernel "$fx" 6.8.0-45-generic; set_no_gpu "$fx"; set_grub "$fx" 0
run_fx "$fx" --no-simulate
want nogpu gpu.nvidia PASS
grep -q 'gpu.driver' <<<"$OUT" && bad "nogpu: driver checks ran without a GPU" || ok "nogpu: driver checks skipped"
want_rc nogpu 0
fx="$(mkfx leftover)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; set_no_gpu "$fx"; set_userspace "$fx" 550.10.01; set_grub "$fx" 0
run_fx "$fx" --no-simulate
want leftover gpu.nvidia WARNING

echo
echo "== 8. no GRUB or systemd-boot =="
fx="$(mkfx nogrub)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; add_kernel "$fx" 6.8.0-50-generic 550.10.01
set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; rm -rf "$fx/boot/grub" "$fx/etc/default/grub"
run_fx "$fx" --no-simulate
want nogrub boot.next_kernel UNKNOWN
grep -q 'bootloader:     UNKNOWN' <<<"$OUT" && ok "nogrub: bootloader UNKNOWN" || bad "nogrub: bootloader guessed"
grep -q 'next boot kernel 6.8.0-50-generic has NVIDIA module' <<<"$OUT" && ok "nogrub: falls back to evaluating newest kernel" || bad "nogrub: no fallback evaluation"
want_rc nogrub 3

echo
echo "== 8b. systemd-boot =="
fx="$(mkfx sdboot)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; add_kernel "$fx" 6.8.0-50-generic none
set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; rm -rf "$fx/boot/grub" "$fx/etc/default/grub"
mkdir -p "$fx/sdboot/entries"; printf 'default example-45.conf\ntimeout 3\n' >"$fx/sdboot/loader.conf"
printf 'title Example Linux\nlinux /vmlinuz-6.8.0-45-generic\ninitrd /initrd.img-6.8.0-45-generic\n' >"$fx/sdboot/entries/example-45.conf"
printf 'title Example Linux (new)\nlinux /vmlinuz-6.8.0-50-generic\n' >"$fx/sdboot/entries/example-50.conf"
run_fx "$fx" --no-simulate
grep -q 'bootloader:     systemd-boot' <<<"$OUT" && ok "sdboot: detected" || bad "sdboot: not detected"
want sdboot boot.next_kernel PASS; want sdboot gpu.driver.next_boot PASS

echo
echo "== 9. insufficient permissions =="
fx="$(mkfx perms)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
chmod 000 "$fx/boot" "$fx/pci"
run_fx "$fx" --no-simulate
want perms kernels.installed UNKNOWN; want perms gpu.nvidia UNKNOWN; want perms gpu.fallback UNKNOWN
chmod 755 "$fx/boot" "$fx/pci"
grep -q 'permission denied or missing' <<<"$OUT" && ok "perms: says why instead of guessing" || bad "perms: reason missing"
want_rc perms 3

echo
echo "== 10. missing or corrupt package metadata =="
fx="$(mkfx aptbroken)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
printf 'E: The package lists or status file could not be parsed or opened.\n' >"$fx/apt-sim.txt"; printf '100\n' >"$fx/apt-exit"
run_fx "$fx"
want aptbroken packages.simulation UNKNOWN
grep -q 'could not be parsed' <<<"$OUT" && ok "aptbroken: apt error surfaced" || bad "aptbroken: apt error hidden"

echo
echo "== 11. unexpected apt removals and orphaned kernels =="
fx="$(mkfx aptremv)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
cat >"$fx/apt-sim.txt" <<'EOF'
Remv linux-modules-nvidia-550-6.8.0-45-generic [6.8.0-45.45]
Inst linux-image-6.8.0-50-generic (6.8.0-50.50 Example:stable [amd64])
Inst nvidia-driver-550 [550.10.01-1] (560.20.02-1 Example:stable [amd64])
1 upgraded, 1 newly installed, 1 to remove and 0 not upgraded.
EOF
printf 'ii nvidia-driver-550 550.10.01-1\nii linux-modules-nvidia-550-6.8.0-45-generic 6.8.0-45.45\n' >"$fx/dpkg-state.txt"
run_fx "$fx"
want aptremv packages.simulation WARNING
grep -q 'REMOVES kernel/driver packages: linux-modules-nvidia-550-6.8.0-45-generic' <<<"$OUT" && ok "aptremv: removal named" || bad "aptremv: removal not named"
grep -q 'installs kernel(s) 6.8.0-50-generic with no matching linux-modules-nvidia' <<<"$OUT" && ok "aptremv: orphaned kernel named" || bad "aptremv: orphan missed"
grep -q 'not proof that a DKMS module will build' <<<"$OUT" && ok "aptremv: simulation caveat present" || bad "aptremv: caveat missing"
grep -qE -- '(^| )-s( |$)' "$fx/apt-calls.log" && ok "aptremv: apt-get called with -s" || bad "aptremv: apt-get called WITHOUT -s"
grep -qE 'install|upgrade' "$fx/apt-calls.log" && ok "aptremv: apt-get invoked exactly as a simulation" || bad "aptremv: apt not invoked"

echo
echo "== 11b. --simulate-install evaluates a planned transaction =="
fx="$(mkfx aptinst)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
printf 'Inst nvidia-dkms-560 (560.20.02-1 Example:stable [amd64])\n0 upgraded, 1 newly installed, 0 to remove and 0 not upgraded.\n' >"$fx/apt-sim.txt"
run_fx "$fx" --simulate-install nvidia-dkms-560 "weird;name"
want aptinst packages.simulation PASS
grep -q 'install --no-install-recommends -- nvidia-dkms-560 weird;name' "$fx/apt-calls.log" && ok "aptinst: packages passed literally after --" || bad "aptinst: argument handling"

echo
echo "== 12. multiple installed kernels =="
fx="$(mkfx many)"; for k in 6.8.0-31-generic 6.8.0-38-generic 6.8.0-45-generic 6.8.0-50-generic; do add_kernel "$fx" "$k" 550.10.01; done
add_kernel "$fx" 6.8.0-55-generic none; set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
run_fx "$fx" --no-simulate
want many gpu.driver.next_boot BLOCKED
grep -q '6.8.0-31-generic (550.10.01) 6.8.0-38-generic (550.10.01) 6.8.0-45-generic (550.10.01) 6.8.0-50-generic (550.10.01)' <<<"$OUT" \
  && ok "many: all four fallbacks listed in version order" || bad "many: fallback list wrong"
grep -q '5 installed kernel(s)' <<<"$OUT" && ok "many: five kernels counted" || bad "many: count wrong"

echo
echo "== 13. diagnostic tools unavailable =="
fx="$(mkfx notools)"; add_kernel "$fx" 6.8.0-40-generic 550.10.01; add_kernel "$fx" 6.8.0-45-generic 550.10.01
set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
rm "$fx"/bin/modinfo "$fx"/bin/apt-get "$fx"/bin/apt-mark "$fx"/bin/dkms
run_fx "$fx"
want notools gpu.driver.modinfo UNKNOWN; want notools gpu.driver.next_boot UNKNOWN
want notools packages.holds UNKNOWN; want notools packages.simulation UNKNOWN
want_rc notools 3

echo
echo "== 14. hostile filenames and odd values =="
fx="$(mkfx hostile)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"
: >"$fx/boot/vmlinuz-6.8.0-99; touch pwned"
: >"$fx/boot/vmlinuz-\$(touch pwned2)"
: >"$fx/boot/vmlinuz-\`touch pwned3\`"
: >"$fx/boot/vmlinuz-with space"
printf '' >"$fx/boot/vmlinuz-new
line"
set_grub "$fx" saved 'He said "boot" \ this>'"'"'that'
( cd "$fx" && run_fx "$fx" --no-simulate; printf '%s' "$OUT" >"$fx/out.txt"; printf '%s' "$RC" >"$fx/rc.txt" )
OUT="$(cat "$fx/out.txt")"; RC="$(cat "$fx/rc.txt")"
if [ -e "$fx/pwned" ] || [ -e "$fx/pwned2" ] || [ -e "$fx/pwned3" ] || [ -e pwned ] || [ -e pwned2 ] || [ -e pwned3 ]; then
  bad "hostile: a filename was executed"
else
  ok "hostile: no filename was executed"
fi
grep -q 'unusual names were ignored' <<<"$OUT" && ok "hostile: odd entries ignored and counted" || bad "hostile: odd entries not reported"
grep -q '1 installed kernel(s)' <<<"$OUT" && ok "hostile: only the sane kernel counted" || bad "hostile: count polluted"
grep -qF 'touch' <<<"$OUT" && bad "hostile: hostile name echoed into the report" || ok "hostile: hostile names not echoed"
want_json hostile "$fx" --no-simulate
if [ "$HAVE_JQ" = 1 ]; then
  jq -e '.host.next_boot.basis | test("boot")' <<<"$OUT" >/dev/null 2>&1 && ok "hostile: quotes/backslashes in grubenv survive JSON escaping" || bad "hostile: JSON escaping of grubenv value"
fi
run_fx "$fx" --no-simulate --target 'x; rm -rf /'
want_rc hostile-target 64

echo
echo "== 15. unsupported distribution (no dpkg) =="
fx="$(mkfx rpm)"; add_kernel "$fx" 6.11.3-200.example.x86_64 560.20.02 dkms; add_kernel "$fx" 6.11.5-300.example.x86_64 560.20.02 dkms
printf 'NAME="Other Linux"\nVERSION_ID="41"\n' >"$fx/etc/os-release"; printf '6.11.5-300.example.x86_64\n' >"$fx/running"
set_userspace "$fx" 560.20.02; set_loaded "$fx" 560.20.02; set_gpu "$fx"; set_grub "$fx" 0; rm "$fx/bin/dpkg-query"
run_fx "$fx"
want rpm packages.holds UNKNOWN
grep -q 'not a dpkg/apt system' <<<"$OUT" && ok "rpm: says package checks are not implemented here" || bad "rpm: wrong message"
want rpm gpu.driver.next_boot PASS; want rpm gpu.fallback PASS
grep -q 'os:             Other Linux 41' <<<"$OUT" && ok "rpm: os-release honoured" || bad "rpm: os not read"
grep -q 'packages.simulation' <<<"$OUT" && bad "rpm: apt simulation ran without apt" || ok "rpm: no apt simulation attempted"

echo
echo "== 16. --target evaluates a planned one-time boot =="
fx="$(mkfx target)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; add_kernel "$fx" 6.8.0-50-generic none
set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"
set_grub "$fx" saved 'Advanced options for Example Linux>Example Linux, with Linux 6.8.0-45-generic'
run_fx "$fx" --no-simulate --target 6.8.0-50-generic
want target boot.next_kernel PASS; want target gpu.driver.next_boot BLOCKED; want_rc target 2
grep -q 'bootloader would pick: 6.8.0-45-generic' <<<"$OUT" && ok "target: still reports what the bootloader would do" || bad "target: bootloader choice hidden"
run_fx "$fx" --no-simulate --target 6.8.0-77-generic
want target-missing boot.next_kernel WARNING

echo
echo "== 17. grub-reboot one-time entry =="
fx="$(mkfx onetime)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; add_kernel "$fx" 6.8.0-50-generic none
set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"
set_grub "$fx" saved 'Advanced options for Example Linux>Example Linux, with Linux 6.8.0-45-generic' 'Advanced options for Example Linux>Example Linux, with Linux 6.8.0-50-generic'
run_fx "$fx" --no-simulate
want onetime gpu.driver.next_boot BLOCKED
grep -q 'one-time next_entry' <<<"$OUT" && ok "onetime: next_entry takes precedence over saved_entry" || bad "onetime: next_entry ignored"
if [ "$HAVE_JQ" = 1 ]; then run_fx "$fx" --no-simulate --json; jq -e '.host.next_boot.one_time == true' <<<"$OUT" >/dev/null && ok "onetime: JSON one_time true" || bad "onetime: JSON one_time"; fi

echo
echo "== 18. readable grub.cfg: title, index, id and unknown specs =="
fx="$(mkfx cfg)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; add_kernel "$fx" 6.8.0-50-generic none
set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"
set_grub "$fx" saved 'Advanced options for Example Linux>Example Linux, with Linux 6.8.0-45-generic'; write_grub_cfg "$fx" 6.8.0-50-generic 6.8.0-45-generic
run_fx "$fx" --no-simulate; grep -q 'next boot:      6.8.0-45-generic' <<<"$OUT" && ok "cfg: submenu title path resolved" || bad "cfg: title path"
set_grub "$fx" '1>2' ; write_grub_cfg "$fx" 6.8.0-50-generic 6.8.0-45-generic
run_fx "$fx" --no-simulate; grep -q 'next boot:      6.8.0-45-generic' <<<"$OUT" && ok "cfg: numeric submenu index 1>2 resolved" || bad "cfg: numeric index"
set_grub "$fx" 'gnulinux-advanced-0000>gnulinux-6.8.0-50-generic-advanced-0000'; write_grub_cfg "$fx" 6.8.0-50-generic 6.8.0-45-generic
run_fx "$fx" --no-simulate; grep -q 'next boot:      6.8.0-50-generic' <<<"$OUT" && ok "cfg: menuentry id path resolved" || bad "cfg: id path"
set_grub "$fx" saved 'No Such Entry'; write_grub_cfg "$fx" 6.8.0-50-generic 6.8.0-45-generic
run_fx "$fx" --no-simulate; grep -q 'GRUB falls back to entry 0' <<<"$OUT" && grep -q 'next boot:      6.8.0-50-generic' <<<"$OUT" \
  && ok "cfg: unknown entry falls back to entry 0" || bad "cfg: fallback to entry 0"
set_grub "$fx" 0; write_grub_cfg "$fx" 6.8.0-50-generic 6.8.0-45-generic
run_fx "$fx" --no-simulate; grep -q 'next boot:      6.8.0-50-generic' <<<"$OUT" && ok "cfg: index 0 = first entry" || bad "cfg: index 0"
set_grub "$fx" 'Memory test'; write_grub_cfg "$fx" 6.8.0-50-generic 6.8.0-45-generic
run_fx "$fx" --no-simulate; want cfg-memtest boot.next_kernel UNKNOWN

echo
echo "== 19. pending update-grub and shell-expanded GRUB_DEFAULT are UNKNOWN =="
fx="$(mkfx pending)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"
set_grub "$fx" saved 'Advanced options for Example Linux>Example Linux, with Linux 6.8.0-45-generic'; touch "$fx/etc/default/grub"
run_fx "$fx" --no-simulate; want pending boot.next_kernel UNKNOWN
grep -q 'update-grub run may be pending' <<<"$OUT" && ok "pending: names the likely cause" || bad "pending: cause missing"
set_grub "$fx" '$(cat /etc/shadow)'
run_fx "$fx" --no-simulate; want expansion boot.next_kernel UNKNOWN
grep -q 'shell expansion' <<<"$OUT" && ok "expansion: refused to evaluate" || bad "expansion: evaluated?"

echo
echo "== 20. package holds =="
fx="$(mkfx holds)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
printf 'nvidia-driver-550\nlinux-modules-nvidia-550-6.8.0-45-generic\n' >"$fx/holds.txt"
printf 'linux-image-generic ii\nlinux-generic ii\n' >"$fx/dpkg-metas.txt"
run_fx "$fx" --no-simulate; want holds-unheld-meta packages.holds WARNING
grep -q 'kernel meta-package(s) are not: linux-image-generic linux-generic' <<<"$OUT" && ok "holds: unheld meta-packages named" || bad "holds: meta not named"
printf 'nvidia-driver-550\nlinux-modules-nvidia-550-6.8.0-45-generic\nlinux-image-generic\nlinux-generic\n' >"$fx/holds.txt"
run_fx "$fx" --no-simulate; want holds-all-held packages.holds PASS
: >"$fx/holds.txt"; run_fx "$fx" --no-simulate; want holds-none packages.holds PASS

echo
echo "== 21. dpkg driver package states =="
fx="$(mkfx dpkgstate)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
printf 'ii nvidia-driver-550 550.10.01-1\nhi linux-modules-nvidia-550-6.8.0-45-generic 6.8.0-45.45\nun nvidia-driver-560 <none>\nrc libnvidia-old 1.0\n' >"$fx/dpkg-state.txt"
run_fx "$fx" --no-simulate; want dpkg-ok packages.state PASS
printf 'ii nvidia-driver-550 550.10.01-1\niU nvidia-kernel-common-550 550.10.01-1\n' >"$fx/dpkg-state.txt"
run_fx "$fx" --no-simulate; want dpkg-interrupted packages.state WARNING
grep -q 'nvidia-kernel-common-550 (iU)' <<<"$OUT" && ok "dpkg: interrupted package named" || bad "dpkg: interrupted not named"
printf 'ii nvidia-driver-560 560.20.02-1\nii libnvidia-compute-550 550.10.01-1\nii linux-modules-nvidia-550-6.8.0-45-generic 6.8.0-45.45\n' >"$fx/dpkg-state.txt"
run_fx "$fx" --no-simulate; want dpkg-two-versions packages.state WARNING
grep -q 'more than one NVIDIA driver version installed: 550.10.01 560.20.02' <<<"$OUT" && ok "dpkg: both versions listed" || bad "dpkg: versions not listed"

echo
echo "== 22. Secure Boot with a DKMS module =="
fx="$(mkfx sb)"; add_kernel "$fx" 6.8.0-45-generic 560.20.02 dkms; set_userspace "$fx" 560.20.02; set_loaded "$fx" 560.20.02; set_gpu "$fx"; set_grub "$fx" 0
mkdir -p "$fx/efi"; printf 'SecureBoot enabled\n' >"$fx/sb-state.txt"; printf '[none] integrity confidentiality\n' >"$fx/lockdown"
FX_EXTRA_ENV="BOOTCHK_EFI_DIR=$fx/efi" run_fx "$fx" --no-simulate; want sb boot.secure_boot WARNING
grep -q 'kernel lockdown: none' <<<"$OUT" && ok "sb: lockdown reported" || bad "sb: lockdown missing"
rm "$fx/bin/mokutil"; FX_EXTRA_ENV="BOOTCHK_EFI_DIR=$fx/efi" run_fx "$fx" --no-simulate; want sb-nomokutil boot.secure_boot UNKNOWN
FX_EXTRA_ENV=""

echo
echo "== 23. running kernel removed from disk; module tree missing; reboot marker =="
fx="$(mkfx removed)"; add_kernel "$fx" 6.8.0-50-generic 550.10.01; set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
: >"$fx/boot/vmlinuz-6.8.0-52-generic"; : >"$fx/reboot-required"
run_fx "$fx" --no-simulate
want removed kernels.running WARNING; want removed kernels.module_trees WARNING; want removed boot.reboot_required PASS
grep -q 'kernel(s) without a module tree: 6.8.0-52-generic' <<<"$OUT" && ok "removed: incomplete kernel named" || bad "removed: incomplete kernel not named"

echo
echo "== 24. output hygiene =="
fx="$(mkfx hygiene)"; add_kernel "$fx" 6.8.0-45-generic 550.10.01; set_userspace "$fx" 550.10.01; set_loaded "$fx" 550.10.01; set_gpu "$fx"; set_grub "$fx" 0
run_fx "$fx" --no-simulate
if grep -qE 'BEGIN [A-Z ]*PRIVATE KEY|[A-Za-z0-9_-]{32,}\.[A-Za-z0-9_-]{20,}\.' <<<"$OUT"; then
  bad "hygiene: secret-shaped output"
else
  ok "hygiene: no secret-shaped output"
fi
# No mutating command may appear in command position (start of line, after
# ; & | or inside $( )) outside a comment. Mentions inside prose/help are fine.
if grep -nE '(^|[;&|(]|\$\()[[:space:]]*(sudo|grub-set-default|grub-reboot|grub-editenv[[:space:]]+(set|unset)|modprobe|insmod|update-grub|dkms[[:space:]]+(build|install|autoinstall|remove)|apt(-get)?[[:space:]]+(install|upgrade|dist-upgrade|remove|purge|autoremove))([[:space:]]|$)' "$SUT" \
   | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
  bad "hygiene: a mutating command appears in command position"
else
  ok "hygiene: no mutating command in command position"
fi
if grep -nE 'apt-get' "$SUT" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -E '"\$APT_GET_BIN"' | grep -vqE -- '"\$APT_GET_BIN" -s '; then
  bad "hygiene: an apt-get invocation lacks -s"
else
  ok "hygiene: every apt-get invocation is a simulation (-s)"
fi

echo
echo "================================"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "TESTS: FAIL"; exit 1; fi
echo "TESTS: PASS"
exit 0
