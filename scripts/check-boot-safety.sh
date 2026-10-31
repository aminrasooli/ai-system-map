#!/usr/bin/env bash
# check-boot-safety.sh — read-only preflight for kernel / GPU-driver upgrades
# and reboots ("Safe Update Guard").
#
# The question it answers before you reboot or upgrade:
#
#   Will the kernel that boots NEXT still have its GPU driver, and if it does
#   not, is a known-good kernel still available to fall back to?
#
# The failure mode it exists for: a kernel meta-package pulls in a newer
# kernel, the vendor's prebuilt NVIDIA module for that kernel is not
# installed (held back, not yet published, or incompatible with the installed
# userspace driver), the bootloader defaults to the newest kernel, and the
# machine comes back from the next reboot with no GPU driver at all.
#
# Read-only, least privilege. It never calls grub-set-default, grub-reboot,
# apt-get install, dkms build, modprobe or sudo. apt is only ever invoked in
# simulation mode (-s). When something cannot be read without privileges, or
# the platform is not one it understands, it reports UNKNOWN and says why.
# A successful apt simulation is reported as exactly that; it is never taken
# as proof that a DKMS module will compile.
#
# Usage:
#   check-boot-safety.sh [--json] [--target KERNEL] [--no-simulate]
#                        [--simulate-install PKG...] [--help]
#
#   --json               machine-readable report (schema ai-system-map/boot-safety/1)
#   --target KERNEL      evaluate KERNEL as the next boot instead of the
#                        bootloader default (e.g. a planned one-time boot)
#   --no-simulate        skip the apt upgrade simulation
#   --simulate-install   simulate `apt-get -s install --no-install-recommends PKG...`
#                        instead of `apt-get -s upgrade` (everything after the
#                        flag is a package argument)
#
# Exit codes: 0 PASS, 1 WARNING, 2 BLOCKED, 3 UNKNOWN, 64 usage error.
#
# Every path and external tool is overridable through BOOTCHK_* environment
# variables so the test-suite can drive it from synthetic fixtures. A seam
# can only make the report wrong; it cannot make the script write anything.

set -uo pipefail

# ---------------------------------------------------------------- seams
BOOT_DIR="${BOOTCHK_BOOT_DIR:-/boot}"
MODULES_DIR="${BOOTCHK_MODULES_DIR:-/lib/modules}"
GRUBENV="${BOOTCHK_GRUBENV:-/boot/grub/grubenv}"
GRUB_CFG="${BOOTCHK_GRUB_CFG:-/boot/grub/grub.cfg}"
GRUB_DEFAULTS="${BOOTCHK_GRUB_DEFAULTS:-/etc/default/grub}"
SDBOOT_DIRS="${BOOTCHK_SDBOOT_DIRS:-/boot/loader:/efi/loader:/boot/efi/loader}"
PCI_DIR="${BOOTCHK_PCI_DIR:-/sys/bus/pci/devices}"
NV_PROC_VERSION="${BOOTCHK_NVIDIA_PROC_VERSION:-/proc/driver/nvidia/version}"
NV_SYS_VERSION="${BOOTCHK_NVIDIA_SYS_VERSION:-/sys/module/nvidia/version}"
NV_LIBDIRS="${BOOTCHK_NVIDIA_LIBDIRS:-/usr/lib/x86_64-linux-gnu:/usr/lib/aarch64-linux-gnu:/usr/lib64:/usr/lib}"
DKMS_DIR="${BOOTCHK_DKMS_DIR:-/var/lib/dkms}"
OS_RELEASE="${BOOTCHK_OS_RELEASE:-/etc/os-release}"
EFI_DIR="${BOOTCHK_EFI_DIR:-/sys/firmware/efi}"
LOCKDOWN_FILE="${BOOTCHK_LOCKDOWN_FILE:-/sys/kernel/security/lockdown}"
REBOOT_MARKERS="${BOOTCHK_REBOOT_MARKERS:-/run/reboot-required:/var/run/reboot-required}"
RUNNING_KERNEL="${BOOTCHK_RUNNING_KERNEL:-$(uname -r 2>/dev/null)}"

MODINFO_BIN="${BOOTCHK_MODINFO_BIN:-modinfo}"
DKMS_BIN="${BOOTCHK_DKMS_BIN:-dkms}"
APT_GET_BIN="${BOOTCHK_APT_GET_BIN:-apt-get}"
APT_MARK_BIN="${BOOTCHK_APT_MARK_BIN:-apt-mark}"
DPKG_QUERY_BIN="${BOOTCHK_DPKG_QUERY_BIN:-dpkg-query}"
MOKUTIL_BIN="${BOOTCHK_MOKUTIL_BIN:-mokutil}"

# ---------------------------------------------------------------- options
JSON=0
TARGET_OVERRIDE=""
SIMULATE=1
SIM_INSTALL=()
usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
}
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --target) [ $# -ge 2 ] || { echo "error: --target needs a kernel version" >&2; exit 64; }
              TARGET_OVERRIDE="$2"; shift 2 ;;
    --target=*) TARGET_OVERRIDE="${1#--target=}"; shift ;;
    --no-simulate) SIMULATE=0; shift ;;
    --simulate-install) shift; SIM_INSTALL=("$@"); set -- ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option '$1'" >&2; usage >&2; exit 64 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

# Only version strings made of these characters are trusted anywhere in the
# report. Anything else (a hostile filename, a corrupt entry) is counted and
# mentioned, never echoed verbatim.
SAFE_RE='^[A-Za-z0-9][A-Za-z0-9._+-]*$'
is_safe() { [[ "$1" =~ $SAFE_RE ]]; }
# Loose version pattern used to pull a kernel version out of a bootloader
# entry title or id: "6.8.0-45-generic", "6.11.3-arch1-1", "6.1.0-25-amd64".
KVER_RE='[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9._+]+)*'

# ---------------------------------------------------------------- findings
# Parallel arrays; evidence lines for one finding are joined with \x1f.
F_ID=(); F_STATUS=(); F_SUMMARY=(); F_EVIDENCE=()
finding() { # id status summary [evidence...]
  local id="$1" st="$2" sum="$3" ev="" e
  shift 3
  for e in "$@"; do ev+="${ev:+$'\x1f'}$e"; done
  F_ID+=("$id"); F_STATUS+=("$st"); F_SUMMARY+=("$sum"); F_EVIDENCE+=("$ev")
}
sev() { case "$1" in PASS) echo 0 ;; UNKNOWN) echo 1 ;; WARNING) echo 2 ;; BLOCKED) echo 3 ;; *) echo 0 ;; esac; }

# Host facts collected along the way (for the JSON "host" object).
H_OS="UNKNOWN"; H_BOOTLOADER="UNKNOWN"; H_NEXT_KERNEL=""; H_NEXT_BASIS=""; H_NEXT_ONE_TIME=false
H_NV_PRESENT="UNKNOWN"; H_NV_USER=""; H_NV_LOADED=""
INSTALLED_KERNELS=()

# ================================================================ platform
if [ -r "$OS_RELEASE" ]; then
  # shellcheck disable=SC1090
  H_OS="$( . "$OS_RELEASE" 2>/dev/null && printf '%s %s' "${NAME:-}" "${VERSION_ID:-}" )"
  H_OS="${H_OS% }"
fi
[ -n "$H_OS" ] || H_OS="UNKNOWN"

HAS_DPKG=0
have "$DPKG_QUERY_BIN" && HAS_DPKG=1

# ================================================================ kernels
newest_kernel() { printf '%s\n' "${INSTALLED_KERNELS[@]}" | sort -V | tail -1; }
kernel_installed() { local k; for k in "${INSTALLED_KERNELS[@]}"; do [ "$k" = "$1" ] && return 0; done; return 1; }

ODD_BOOT_NAMES=0; BOOT_READABLE=0
if [ -d "$BOOT_DIR" ] && [ -r "$BOOT_DIR" ]; then
  BOOT_READABLE=1
  for f in "$BOOT_DIR"/vmlinuz-*; do
    [ -e "$f" ] || continue
    v="${f##*/vmlinuz-}"
    case "$v" in *.old|*.bak|*.efi.signed) continue ;; esac
    if is_safe "$v"; then INSTALLED_KERNELS+=("$v"); else ODD_BOOT_NAMES=$((ODD_BOOT_NAMES + 1)); fi
  done
  if [ "${#INSTALLED_KERNELS[@]}" -eq 0 ]; then
    finding kernels.installed UNKNOWN "no vmlinuz-* found in $BOOT_DIR" \
      "the boot directory may be a separate partition that is not mounted, or this distribution names kernels differently"
  else
    mapfile -t INSTALLED_KERNELS < <(printf '%s\n' "${INSTALLED_KERNELS[@]}" | sort -V)
    ev=("installed kernels: ${INSTALLED_KERNELS[*]}")
    [ "$ODD_BOOT_NAMES" -gt 0 ] && ev+=("$ODD_BOOT_NAMES vmlinuz entr(y/ies) with unusual names were ignored")
    finding kernels.installed PASS "${#INSTALLED_KERNELS[@]} installed kernel(s)" "${ev[@]}"
  fi
else
  finding kernels.installed UNKNOWN "cannot read $BOOT_DIR" "permission denied or missing; kernel inventory needs read access to the boot directory"
fi

if [ -n "$RUNNING_KERNEL" ] && is_safe "$RUNNING_KERNEL"; then
  if [ "${#INSTALLED_KERNELS[@]}" -gt 0 ] && ! kernel_installed "$RUNNING_KERNEL"; then
    finding kernels.running WARNING "running kernel $RUNNING_KERNEL is no longer installed" \
      "its image was removed or replaced; a reboot cannot return to it"
  else
    finding kernels.running PASS "running kernel $RUNNING_KERNEL"
  fi
else
  RUNNING_KERNEL=""
  finding kernels.running UNKNOWN "running kernel version unreadable"
fi

# Module trees without a kernel image are leftovers; a kernel image without
# a module tree cannot boot usefully.
if [ -d "$MODULES_DIR" ] && [ -r "$MODULES_DIR" ] && [ "${#INSTALLED_KERNELS[@]}" -gt 0 ]; then
  missing_tree=()
  for k in "${INSTALLED_KERNELS[@]}"; do [ -d "$MODULES_DIR/$k" ] || missing_tree+=("$k"); done
  if [ "${#missing_tree[@]}" -gt 0 ]; then
    finding kernels.module_trees WARNING "kernel(s) without a module tree: ${missing_tree[*]}" \
      "an image exists in $BOOT_DIR but $MODULES_DIR has no matching directory; the install may be incomplete"
  else
    finding kernels.module_trees PASS "every installed kernel has a module tree"
  fi
fi

# ================================================================ bootloader
grubenv_get() { sed -n "s/^$1=//p" "$GRUBENV" 2>/dev/null | tail -1; }

# Last GRUB_DEFAULT= from /etc/default/grub and /etc/default/grub.d/*.cfg.
grub_default_setting() {
  local f v="" line
  for f in "$GRUB_DEFAULTS" "$GRUB_DEFAULTS".d/*.cfg; do
    [ -r "$f" ] || continue
    line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?GRUB_DEFAULT=' "$f" 2>/dev/null | tail -1)"
    [ -n "$line" ] && v="${line#*GRUB_DEFAULT=}"
  done
  v="${v%%#*}"
  v="$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$v" in
    *'$'*|*'`'*) printf '__UNSAFE__\n'; return ;;
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s\n' "${v:-0}"
}

# Parse a readable grub.cfg into one line per menu object:
#   S|<index>|<title>|<id>|            a top-level submenu
#   E|<index>|<title>|<id>|<kernel>    a menu entry; index is "N" at top
#                                      level or "N>M" inside submenu N
# Titles and ids come from the single-quoted strings on the header line; the
# kernel from the first `linux ... /vmlinuz-X` inside the entry.
grub_cfg_entries() {
  awk '
    function q(s, n,  i, c, out, inq, cnt) {
      out = ""; inq = 0; cnt = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\047") { if (inq) { cnt++; if (cnt == n) return out; out = ""; inq = 0 } else inq = 1; continue }
        if (inq) out = out c
      }
      return ""
    }
    function idof(s,  p) { p = index(s, "$menuentry_id_option"); if (!p) return ""; return q(substr(s, p), 1) }
    BEGIN { top = -1; insub = 0; inentry = 0 }
    {
      l = $0; sub(/^[ \t]+/, "", l)
      if (!inentry && l ~ /^submenu /) {
        top++; sub_i = top; child = -1; insub = 1
        print "S|" top "|" q(l, 1) "|" idof(l) "|"; next }
      if (!inentry && l ~ /^menuentry /) {
        if (insub) { child++; idx = sub_i ">" child } else { top++; idx = top }
        title = q(l, 1); id = idof(l); kern = ""; inentry = 1; nest = 0; next }
      if (inentry) {
        if (l ~ /^(linux|linuxefi|linux16)[ \t]/ && match(l, /vmlinuz-[^ \t]+/)) { kern = substr(l, RSTART + 8, RLENGTH - 8); next }
        if (l ~ /\{[ \t]*$/) { nest++; next }
        if (l ~ /^\}/) { if (nest > 0) { nest--; next } print "E|" idx "|" title "|" id "|" kern; inentry = 0; next }
        next }
      if (insub && l ~ /^\}/) { insub = 0; next }
    }' "$GRUB_CFG" 2>/dev/null
}

# Resolve an entry spec (index, title, id or ">"-joined submenu path) against
# a readable grub.cfg. Prints the kernel, or "@0:<kernel>" when the spec does
# not match and GRUB would fall back to entry 0.
grub_cfg_resolve() {
  local spec="$1" kind idx title id kern first="" p1 p2 sidx=""
  local entries; entries="$(grub_cfg_entries)"
  [ -n "$entries" ] || return 0
  first="$(printf '%s\n' "$entries" | awk -F'|' '$1 == "E" && $2 == "0" { print $5; exit }')"
  [ -n "$first" ] || first="$(printf '%s\n' "$entries" | awk -F'|' '$1 == "E" { print $5; exit }')"
  case "$spec" in
    *">"*)
      p1="${spec%%>*}"; p2="${spec#*>}"
      while IFS='|' read -r kind idx title id kern; do
        [ "$kind" = S ] || continue
        if [ "$p1" = "$idx" ] || [ "$p1" = "$title" ] || { [ -n "$id" ] && [ "$p1" = "$id" ]; }; then sidx="$idx"; break; fi
      done <<<"$entries"
      [ -n "$sidx" ] || { printf '@0:%s\n' "$first"; return 0; }
      while IFS='|' read -r kind idx title id kern; do
        [ "$kind" = E ] || continue
        [ "${idx%%>*}" = "$sidx" ] && [ "$idx" != "$sidx" ] || continue
        if [ "$p2" = "${idx#*>}" ] || [ "$p2" = "$title" ] || { [ -n "$id" ] && [ "$p2" = "$id" ]; }; then
          printf '%s\n' "$kern"; return 0
        fi
      done <<<"$entries" ;;
    *)
      while IFS='|' read -r kind idx title id kern; do
        [ "$kind" = E ] || continue
        case "$idx" in *">"*) continue ;; esac
        if [ "$spec" = "$idx" ] || [ "$spec" = "$title" ] || { [ -n "$id" ] && [ "$spec" = "$id" ]; }; then
          printf '%s\n' "$kern"; return 0
        fi
      done <<<"$entries" ;;
  esac
  printf '@0:%s\n' "$first"
}

# resolve_entry SPEC -> "OK|<kernel>|<basis>" or "UNKNOWN||<reason>"
resolve_entry() {
  local spec="$1" r v newest
  newest="$(newest_kernel)"
  if [ -r "$GRUB_CFG" ]; then
    r="$(grub_cfg_resolve "${spec:-0}")"
    case "$r" in
      "")   echo "UNKNOWN||grub.cfg is readable but contains no kernel entries" ;;
      @0:)  echo "UNKNOWN||entry '${spec:0:80}' not in grub.cfg and entry 0 has no kernel" ;;
      @0:*) echo "OK|${r#@0:}|entry '${spec:0:80}' is not in grub.cfg; GRUB falls back to entry 0" ;;
      *)    echo "OK|$r|grub.cfg entry '${spec:0:80}'" ;;
    esac
    return
  fi
  # grub.cfg unreadable (root-only on many distributions): resolve what can
  # be resolved from the entry name alone, say UNKNOWN for the rest.
  case "$spec" in
    ""|0|gnulinux-simple-*)
      if [ -n "$newest" ]; then
        echo "OK|$newest|entry 0 = newest installed kernel (GRUB sorts by version; grub.cfg not readable to confirm)"
      else
        echo "UNKNOWN||no installed kernel found to resolve entry 0"
      fi
      return ;;
  esac
  v="$(printf '%s' "$spec" | grep -oE "$KVER_RE" | head -1)"
  if [ -z "$v" ]; then
    echo "UNKNOWN||entry '${spec:0:80}' needs grub.cfg to resolve and grub.cfg is not readable"
  elif kernel_installed "$v"; then
    echo "OK|$v|entry names $v, which is installed (grub.cfg not readable to confirm)"
  elif [ -n "$newest" ]; then
    echo "OK|$newest|entry names $v, which is NOT installed; GRUB falls back to entry 0 = $newest"
  else
    echo "UNKNOWN||entry names $v, which is not installed, and no fallback kernel was found"
  fi
}

detect_grub() { [ -e "$GRUB_CFG" ] || [ -e "$GRUBENV" ] || [ -e "$GRUB_DEFAULTS" ]; }
detect_sdboot() {
  local d dirs; IFS=':' read -r -a dirs <<<"$SDBOOT_DIRS"
  for d in "${dirs[@]}"; do
    if [ -e "$d/loader.conf" ] || [ -d "$d/entries" ]; then printf '%s\n' "$d"; return 0; fi
  done
  return 1
}

NEXT_STATUS="UNKNOWN"; NEXT_KERNEL=""; NEXT_BASIS=""; ONE_TIME=0
if SDB="$(detect_sdboot)"; then
  H_BOOTLOADER="systemd-boot"
  def="$(sed -n 's/^[[:space:]]*default[[:space:]]\+//p' "$SDB/loader.conf" 2>/dev/null | tail -1)"
  if [ -n "$def" ] && [ -d "$SDB/entries" ]; then
    # `default` may be a glob; take the first matching entry's linux line.
    for e in "$SDB"/entries/$def "$SDB"/entries/${def}.conf; do
      [ -r "$e" ] || continue
      k="$(sed -n 's/^[[:space:]]*linux[[:space:]]\+//p' "$e" 2>/dev/null | head -1 | grep -oE 'vmlinuz-[^ /]+' | head -1)"
      k="${k#vmlinuz-}"
      if [ -n "$k" ] && is_safe "$k"; then NEXT_STATUS=OK; NEXT_KERNEL="$k"; NEXT_BASIS="loader.conf default -> $(basename "$e")"; fi
      break
    done
  fi
  [ "$NEXT_STATUS" = OK ] || NEXT_BASIS="systemd-boot default entry could not be resolved (loader.conf default: '${def:-unset}')"
elif detect_grub; then
  H_BOOTLOADER="grub"
  next="$(grubenv_get next_entry)"
  if [ -n "$next" ]; then
    ONE_TIME=1
    IFS='|' read -r st k basis <<<"$(resolve_entry "$next")"
    NEXT_STATUS="$st"; NEXT_KERNEL="$k"; NEXT_BASIS="one-time next_entry (grub-reboot) -> $basis"
  else
    pending=""
    if [ -e "$GRUB_CFG" ]; then
      cfgm="$(stat -c %Y "$GRUB_CFG" 2>/dev/null || echo 0)"
      for f in "$GRUB_DEFAULTS" "$GRUB_DEFAULTS".d/*.cfg; do
        [ -e "$f" ] || continue
        fm="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        [ "$cfgm" -gt 0 ] && [ "$fm" -gt "$cfgm" ] && pending="$(basename "$f")"
      done
    fi
    if [ -n "$pending" ] && ! [ -r "$GRUB_CFG" ]; then
      NEXT_STATUS=UNKNOWN; NEXT_BASIS="$pending changed after grub.cfg was generated; an update-grub run may be pending, and grub.cfg is not readable"
    else
      setting="$(grub_default_setting)"
      case "$setting" in
        __UNSAFE__) NEXT_STATUS=UNKNOWN; NEXT_BASIS="GRUB_DEFAULT uses shell expansion; not evaluated" ;;
        saved)      IFS='|' read -r st k basis <<<"$(resolve_entry "$(grubenv_get saved_entry)")"
                    NEXT_STATUS="$st"; NEXT_KERNEL="$k"; NEXT_BASIS="GRUB_DEFAULT=saved -> $basis" ;;
        *)          IFS='|' read -r st k basis <<<"$(resolve_entry "$setting")"
                    NEXT_STATUS="$st"; NEXT_KERNEL="$k"; NEXT_BASIS="GRUB_DEFAULT=${setting:0:60} -> $basis" ;;
      esac
    fi
  fi
else
  H_BOOTLOADER="UNKNOWN"
  NEXT_BASIS="no GRUB or systemd-boot configuration found (other bootloaders are not understood)"
fi

if [ -n "$TARGET_OVERRIDE" ]; then
  if is_safe "$TARGET_OVERRIDE"; then
    bl_note="bootloader would pick: ${NEXT_KERNEL:-UNKNOWN} ($NEXT_BASIS)"
    NEXT_KERNEL="$TARGET_OVERRIDE"; NEXT_STATUS=OK; NEXT_BASIS="--target given on the command line"
    if ! kernel_installed "$NEXT_KERNEL"; then
      finding boot.next_kernel WARNING "target kernel $NEXT_KERNEL is not installed" "$bl_note"
    else
      finding boot.next_kernel PASS "evaluating planned boot target $NEXT_KERNEL" "$bl_note"
    fi
  else
    echo "error: --target value contains unexpected characters" >&2; exit 64
  fi
elif [ "$NEXT_STATUS" = OK ] && [ -n "$NEXT_KERNEL" ]; then
  if [ -n "$RUNNING_KERNEL" ] && [ "$NEXT_KERNEL" != "$RUNNING_KERNEL" ]; then
    finding boot.next_kernel WARNING "next boot is $NEXT_KERNEL, not the running $RUNNING_KERNEL" "$NEXT_BASIS" \
      "a reboot changes the kernel; the driver checks below are evaluated for $NEXT_KERNEL"
  else
    finding boot.next_kernel PASS "next boot: $NEXT_KERNEL" "$NEXT_BASIS"
  fi
else
  NEXT_KERNEL=""
  finding boot.next_kernel UNKNOWN "next boot kernel could not be determined" "$NEXT_BASIS" \
    "the driver checks below fall back to the newest installed kernel, which is what most bootloaders pick by default"
fi
H_NEXT_KERNEL="$NEXT_KERNEL"; H_NEXT_BASIS="$NEXT_BASIS"; [ "$ONE_TIME" = 1 ] && H_NEXT_ONE_TIME=true
EVAL_KERNEL="${NEXT_KERNEL:-$(newest_kernel)}"

# ================================================================ NVIDIA
nvidia_gpu_present() { # 0 present, 1 absent, 2 unknown
  local d v c seen=0
  [ -d "$PCI_DIR" ] && [ -r "$PCI_DIR" ] || return 2
  for d in "$PCI_DIR"/*; do
    [ -r "$d/vendor" ] && [ -r "$d/class" ] || continue
    seen=1
    v="$(cat "$d/vendor" 2>/dev/null)"; c="$(cat "$d/class" 2>/dev/null)"
    case "$v:$c" in 0x10de:0x03*) return 0 ;; esac
  done
  [ "$seen" = 1 ] && return 1 || return 2
}

kernel_module() { # $1 kernel -> path of nvidia.ko* or nothing
  [ -d "$MODULES_DIR/$1" ] || return 0
  find "$MODULES_DIR/$1" -maxdepth 6 \( -name 'nvidia.ko' -o -name 'nvidia.ko.*' \) -print 2>/dev/null | sort | head -1
}
module_version() { # $1 path -> version or "" ; "?" when modinfo unavailable
  have "$MODINFO_BIN" || { printf '?\n'; return; }
  "$MODINFO_BIN" -F version "$1" 2>/dev/null | head -1 | tr -d '[:space:]' | grep -E '^[0-9][0-9.]*$'
}
module_kind() { case "$1" in */updates/dkms/*) echo dkms ;; *) echo packaged ;; esac; }
userspace_version() {
  local d dirs; IFS=':' read -r -a dirs <<<"$NV_LIBDIRS"
  for d in "${dirs[@]}"; do
    ls -1 "$d"/libnvidia-ml.so.* 2>/dev/null | sed -n 's#.*/libnvidia-ml\.so\.\([0-9]\+\.[0-9]\+\(\.[0-9]\+\)\?\)$#\1#p' | sort -V | tail -1
  done | sort -V | tail -1
}
loaded_version() {
  if [ -r "$NV_SYS_VERSION" ]; then tr -d '[:space:]' <"$NV_SYS_VERSION" 2>/dev/null; return; fi
  [ -r "$NV_PROC_VERSION" ] || return 0
  awk 'NR==1 { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) { print $i; exit } }' "$NV_PROC_VERSION" 2>/dev/null
}
dkms_source_versions() { # nvidia module versions with DKMS source present
  local d; for d in "$DKMS_DIR"/nvidia*/*/; do [ -d "$d" ] || continue; d="${d%/}"; printf '%s\n' "${d##*/}"; done | sort -uV
}
dkms_built_for() { # $1 kernel -> versions with a built module for that kernel
  local d; for d in "$DKMS_DIR"/nvidia*/*/"$1"/*/module/; do [ -d "$d" ] || continue
    ls "$d"/nvidia.ko* >/dev/null 2>&1 || continue
    d="${d%/*/module/}"; d="${d%/*}"; printf '%s\n' "${d##*/}"; done | sort -uV
}

TARGET_KIND=""
nvidia_gpu_present; gp=$?
case $gp in
  0) H_NV_PRESENT=true ;;
  1) H_NV_PRESENT=false ;;
  2) H_NV_PRESENT="UNKNOWN" ;;
esac
H_NV_USER="$(userspace_version)"
H_NV_LOADED="$(loaded_version)"

if [ "$H_NV_PRESENT" = false ] && [ -z "$H_NV_USER" ]; then
  finding gpu.nvidia PASS "no NVIDIA GPU and no NVIDIA driver installed; driver checks not applicable"
elif [ "$H_NV_PRESENT" = false ]; then
  finding gpu.nvidia WARNING "NVIDIA userspace driver $H_NV_USER installed but no NVIDIA GPU found on PCI" \
    "harmless for booting; a leftover driver still pins kernel module packages"
else
  [ "$H_NV_PRESENT" = "UNKNOWN" ] && finding gpu.nvidia UNKNOWN "PCI device list unreadable; assuming an NVIDIA GPU may be present" \
    "driver checks below run because NVIDIA userspace is ${H_NV_USER:+installed ($H_NV_USER)}${H_NV_USER:-not detected either}"
  if [ "$H_NV_PRESENT" = true ]; then
    finding gpu.nvidia PASS "NVIDIA GPU present" "userspace driver: ${H_NV_USER:-not found}" "loaded kernel module: ${H_NV_LOADED:-none}"
  fi

  if [ -z "$H_NV_USER" ] && [ "$H_NV_PRESENT" = true ]; then
    finding gpu.driver.userspace WARNING "no NVIDIA userspace driver (libnvidia-ml) found" \
      "if the GPU is meant to be driven by nouveau or not at all, this is expected"
  fi

  # Per-kernel module inventory.
  declare -A MOD_VER MOD_KIND
  INV=()
  for k in "${INSTALLED_KERNELS[@]}"; do
    m="$(kernel_module "$k")"
    if [ -n "$m" ]; then
      MOD_VER[$k]="$(module_version "$m")"; MOD_KIND[$k]="$(module_kind "$m")"
      INV+=("$k: module ${MOD_VER[$k]:-version unreadable} (${MOD_KIND[$k]})")
    else
      MOD_VER[$k]=""; MOD_KIND[$k]="none"
      INV+=("$k: NO nvidia module")
    fi
  done
  if [ "${#INV[@]}" -gt 0 ]; then finding gpu.driver.modules PASS "per-kernel NVIDIA module inventory" "${INV[@]}"; fi
  have "$MODINFO_BIN" || finding gpu.driver.modinfo UNKNOWN "modinfo not available; module versions cannot be read" \
    "presence of a module file is still checked"

  # DKMS state: source present vs. actually built. Never assume a build.
  DKMS_SRC="$(dkms_source_versions | tr '\n' ' ')"; DKMS_SRC="${DKMS_SRC% }"
  if [ -n "$DKMS_SRC" ]; then
    dk=()
    for k in "${INSTALLED_KERNELS[@]}"; do
      b="$(dkms_built_for "$k" | tr '\n' ' ')"; b="${b% }"
      dk+=("$k: dkms built for ${b:-NOTHING}")
    done
    dk+=("dkms source versions present: $DKMS_SRC")
    if have "$DKMS_BIN"; then
      s="$("$DKMS_BIN" status 2>/dev/null | grep -i nvidia | head -8)"
      [ -n "$s" ] && while IFS= read -r l; do dk+=("dkms status: ${l:0:120}"); done <<<"$s"
    else
      dk+=("dkms command not available; built modules inferred from $DKMS_DIR")
    fi
    finding gpu.driver.dkms PASS "DKMS source present for NVIDIA" "${dk[@]}"
  fi

  # Evaluate the kernel that boots next.
  if [ -n "$EVAL_KERNEL" ]; then
    TARGET_KIND="${MOD_KIND[$EVAL_KERNEL]:-none}"
    tv="${MOD_VER[$EVAL_KERNEL]:-}"
    if [ "$TARGET_KIND" = none ]; then
      ev=("$EVAL_KERNEL has no nvidia.ko in $MODULES_DIR/$EVAL_KERNEL")
      if [ -n "$DKMS_SRC" ]; then
        ev+=("DKMS source exists ($DKMS_SRC) but no module was built for $EVAL_KERNEL; a build is not guaranteed to succeed")
      fi
      ev+=("booting $EVAL_KERNEL would bring the system up without the NVIDIA driver")
      finding gpu.driver.next_boot BLOCKED "next boot kernel $EVAL_KERNEL has NO NVIDIA module" "${ev[@]}"
    elif [ -n "$H_NV_USER" ] && [ -n "$tv" ] && [ "$tv" != "?" ] && [ "$tv" != "$H_NV_USER" ]; then
      finding gpu.driver.next_boot BLOCKED "next boot kernel $EVAL_KERNEL has module $tv but userspace is $H_NV_USER" \
        "the NVIDIA userspace library only talks to a kernel module of the same version; the GPU would not initialise"
    elif [ -z "$tv" ] || [ "$tv" = "?" ]; then
      finding gpu.driver.next_boot UNKNOWN "next boot kernel $EVAL_KERNEL has a module whose version could not be read" \
        "cannot confirm it matches userspace ${H_NV_USER:-?}"
    else
      finding gpu.driver.next_boot PASS "next boot kernel $EVAL_KERNEL has NVIDIA module $tv matching userspace" "module kind: $TARGET_KIND"
    fi
  fi

  # Running kernel vs. loaded module vs. userspace.
  if [ -n "$RUNNING_KERNEL" ] && [ -n "$H_NV_USER" ]; then
    if [ -z "$H_NV_LOADED" ]; then
      if [ -n "${MOD_VER[$RUNNING_KERNEL]:-}" ]; then
        finding gpu.driver.running WARNING "NVIDIA module installed for running kernel but not loaded"
      else
        finding gpu.driver.running WARNING "running kernel $RUNNING_KERNEL has no NVIDIA module loaded or installed" \
          "the GPU is currently undriven; this is the state a bad reboot leaves behind"
      fi
    elif [ "$H_NV_LOADED" != "$H_NV_USER" ]; then
      finding gpu.driver.running WARNING "loaded module $H_NV_LOADED differs from userspace $H_NV_USER" \
        "userspace was upgraded after boot; tools report 'driver/library version mismatch' until reboot" \
        "the next boot kernel must carry module $H_NV_USER (see gpu.driver.next_boot)"
    else
      finding gpu.driver.running PASS "loaded module $H_NV_LOADED matches userspace"
    fi
  fi

  # Fallback: another installed kernel whose module matches userspace.
  if [ -n "$EVAL_KERNEL" ] && [ "${#INSTALLED_KERNELS[@]}" -gt 1 ]; then
    good=(); stale=()
    for k in "${INSTALLED_KERNELS[@]}"; do
      [ "$k" = "$EVAL_KERNEL" ] && continue
      v="${MOD_VER[$k]:-}"
      [ "${MOD_KIND[$k]}" = none ] && continue
      if [ -z "$H_NV_USER" ] || [ "$v" = "$H_NV_USER" ] || [ "$v" = "?" ]; then good+=("$k (${v:-?})"); else stale+=("$k ($v)"); fi
    done
    if [ "${#good[@]}" -gt 0 ]; then
      finding gpu.fallback PASS "GPU-capable fallback kernel(s): ${good[*]}" \
        "keep at least one of these installed and selectable until the next boot kernel is proven"
    elif [ "${#stale[@]}" -gt 0 ]; then
      finding gpu.fallback WARNING "fallback kernels exist but their modules do not match userspace ${H_NV_USER}: ${stale[*]}" \
        "a driver upgrade made the old prebuilt modules incompatible; falling back to them boots without a working GPU" \
        "a DKMS driver (built for every installed kernel) or keeping the old userspace packages restores the fallback"
    else
      finding gpu.fallback WARNING "no other installed kernel has an NVIDIA module" \
        "if $EVAL_KERNEL fails, there is nothing GPU-capable to boot instead"
    fi
  elif [ "$BOOT_READABLE" = 0 ]; then
    finding gpu.fallback UNKNOWN "installed kernels could not be listed, so no fallback can be confirmed"
  elif [ "${#INSTALLED_KERNELS[@]}" -le 1 ]; then
    finding gpu.fallback WARNING "only one kernel installed; no fallback kernel exists"
  fi

  # Secure Boot: a DKMS-built module must be signed with an enrolled key.
  if [ -d "$EFI_DIR" ]; then
    sb="UNKNOWN"
    if have "$MOKUTIL_BIN"; then
      o="$("$MOKUTIL_BIN" --sb-state 2>/dev/null)"
      case "$o" in *enabled*) sb=enabled ;; *disabled*) sb=disabled ;; esac
    fi
    ld="$(cat "$LOCKDOWN_FILE" 2>/dev/null | grep -oE '\[[a-z]+\]' | tr -d '[]')"
    if [ "$sb" = enabled ] && [ "$TARGET_KIND" = dkms ]; then
      finding boot.secure_boot WARNING "Secure Boot enabled and the next boot NVIDIA module is DKMS-built" \
        "an unsigned DKMS module is refused by the kernel; it must be signed with a MOK-enrolled key (not verifiable from here)" \
        "kernel lockdown: ${ld:-unknown}"
    elif [ "$sb" = UNKNOWN ]; then
      finding boot.secure_boot UNKNOWN "EFI system; Secure Boot state unreadable (mokutil unavailable)" "kernel lockdown: ${ld:-unknown}"
    else
      finding boot.secure_boot PASS "Secure Boot $sb" "kernel lockdown: ${ld:-unknown}"
    fi
  else
    finding boot.secure_boot PASS "legacy BIOS boot; Secure Boot not applicable"
  fi
fi

# ================================================================ packages (dpkg/apt hosts only)
if [ "$HAS_DPKG" = 1 ]; then
  if have "$APT_MARK_BIN"; then
    holds="$("$APT_MARK_BIN" showhold 2>/dev/null)"
    rel="$(printf '%s\n' "$holds" | grep -E '^(linux-|nvidia-|libnvidia-)' | tr '\n' ' ')"; rel="${rel% }"
    nv_held=0; printf '%s\n' "$holds" | grep -qE '^(nvidia-|linux-modules-nvidia-|libnvidia-)' && nv_held=1
    metas="$("$DPKG_QUERY_BIN" -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-image-generic*' 'linux-generic*' 'linux-image-*-hwe-*' 'linux-image-amd64' 'linux-image-arm64' 2>/dev/null | awk 'substr($2,2,1) == "i" {print $1}')"
    unheld_meta=()
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      printf '%s\n' "$holds" | grep -qx "$m" || unheld_meta+=("$m")
    done <<<"$metas"
    if [ "$nv_held" = 1 ] && [ "${#unheld_meta[@]}" -gt 0 ]; then
      finding packages.holds WARNING "NVIDIA packages are held but kernel meta-package(s) are not: ${unheld_meta[*]}" \
        "held: ${rel:-none}" \
        "a kernel meta-package that keeps moving installs new kernels while the held driver cannot follow; the newest kernel then has no module"
    elif [ -n "$rel" ]; then
      finding packages.holds PASS "kernel/driver holds: $rel"
    else
      finding packages.holds PASS "no kernel or driver packages held"
    fi
  else
    finding packages.holds UNKNOWN "apt-mark not available; holds not checked"
  fi

  # Driver package consistency: broken states, or two driver versions at once.
  # dpkg status abbreviation: column 1 = desired action, column 2 = state;
  # 'i' installed (so "ii" and held "hi" are fine), 'n'/'c' never or no
  # longer installed, anything else (H U F W t) is an interrupted transaction.
  st="$("$DPKG_QUERY_BIN" -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' 'nvidia-*' 'libnvidia-*' 'linux-modules-nvidia-*' 2>/dev/null)"
  if [ -n "$st" ]; then
    broken="$(printf '%s\n' "$st" | awk 'substr($1,2,1) ~ /[HUFWt]/ {print $2 " (" $1 ")"}' | tr '\n' ' ')"
    # Only packages whose version IS the driver version; linux-modules-nvidia-*
    # packages carry the kernel's version and are checked via modinfo instead.
    vers="$(printf '%s\n' "$st" | awk 'substr($1,2,1) == "i" && $2 ~ /^(nvidia-driver-|nvidia-kernel-common-|nvidia-utils-|libnvidia-compute-)/ {print $3}' \
            | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -uV | tr '\n' ' ')"
    vers="${vers% }"
    nvers="$(printf '%s\n' "$vers" | tr ' ' '\n' | grep -c .)"
    if [ -n "${broken% }" ]; then
      finding packages.state WARNING "NVIDIA packages in a non-installed state: ${broken% }" \
        "finish or roll back the interrupted transaction before rebooting"
    elif [ "$nvers" -gt 1 ]; then
      finding packages.state WARNING "more than one NVIDIA driver version installed: $vers" \
        "prebuilt kernel modules and userspace from different versions cannot work together"
    else
      finding packages.state PASS "NVIDIA packages consistent${vers:+ (version $vers)}"
    fi
  fi

  # apt simulation: what would the next upgrade (or the given install) do to
  # kernels and drivers? -s only. Output parsed, never acted on.
  if [ "$SIMULATE" = 1 ]; then
    if have "$APT_GET_BIN"; then
      if [ "${#SIM_INSTALL[@]}" -gt 0 ]; then
        sim_label="apt-get -s install --no-install-recommends ${SIM_INSTALL[*]}"
        sim="$("$APT_GET_BIN" -s -q -o Debug::NoLocking=1 install --no-install-recommends -- "${SIM_INSTALL[@]}" 2>&1)"; rc=$?
      else
        sim_label="apt-get -s upgrade"
        sim="$("$APT_GET_BIN" -s -q -o Debug::NoLocking=1 upgrade 2>&1)"; rc=$?
      fi
      if [ $rc -ne 0 ]; then
        finding packages.simulation UNKNOWN "$sim_label failed (exit $rc)" \
          "$(printf '%s\n' "$sim" | grep -E '^E:|^W:' | head -3 | tr '\n' ';' | cut -c1-300)" \
          "package metadata may be missing or corrupt; run apt-get update (with privileges) and retry"
      else
        inst="$(printf '%s\n' "$sim" | awk '$1 == "Inst" {print $2}')"
        remv="$(printf '%s\n' "$sim" | awk '$1 == "Remv" {print $2}')"
        summary="$(printf '%s\n' "$sim" | grep -E '^[0-9]+ upgraded, ' | tail -1)"
        ev=("${summary:-no transaction summary line}")
        bad_remv="$(printf '%s\n' "$remv" | grep -E '^(linux-image-|linux-modules-nvidia-|nvidia-(dkms|driver|kernel|firmware)|libnvidia-)' | tr '\n' ' ')"
        new_kernels="$(printf '%s\n' "$inst" | sed -n 's/^linux-image-\([0-9][^ ]*\)$/\1/p')"
        orphan_kernels=()
        while IFS= read -r nk; do
          [ -n "$nk" ] || continue
          printf '%s\n' "$inst" | grep -qE "^linux-modules-nvidia-[^ ]*-$nk$" && continue
          [ -n "${DKMS_SRC:-}" ] && continue
          orphan_kernels+=("$nk")
        done <<<"$new_kernels"
        user_bump="$(printf '%s\n' "$sim" | awk '$1 == "Inst" && $2 ~ /^(nvidia-driver-|libnvidia-compute-)/ && $0 ~ /\(/ {print $2}' | head -1)"
        sev_st=PASS
        if [ -n "${bad_remv% }" ]; then
          sev_st=WARNING; ev+=("REMOVES kernel/driver packages: ${bad_remv% }")
        fi
        if [ "${#orphan_kernels[@]}" -gt 0 ] && { [ "$H_NV_PRESENT" = true ] || [ -n "$H_NV_USER" ]; }; then
          sev_st=WARNING; ev+=("installs kernel(s) ${orphan_kernels[*]} with no matching linux-modules-nvidia package and no DKMS source: they would boot without the NVIDIA driver")
        fi
        if [ -n "$user_bump" ]; then
          kept="$(printf '%s\n' "${st:-}" | awk 'substr($1,2,1) == "i" && $2 ~ /^linux-modules-nvidia-/ {print $2}' | grep -vxF -f <(printf '%s\n' "$inst") | tr '\n' ' ')"
          if [ -n "${kept% }" ]; then
            sev_st=WARNING; ev+=("upgrades NVIDIA userspace ($user_bump) while these prebuilt modules stay at the old version: ${kept% }; those kernels lose a working driver")
          fi
        fi
        [ "$sev_st" = PASS ] && ev+=("no kernel or NVIDIA driver package is removed, orphaned or version-split by this transaction")
        ev+=("a clean simulation is not proof that a DKMS module will build; verify with 'dkms status' after installing, before rebooting")
        finding packages.simulation "$sev_st" "$sim_label: $(printf '%s' "$inst" | grep -c .) install/upgrade action(s), $(printf '%s' "$remv" | grep -c .) removal(s)" "${ev[@]}"
      fi
    else
      finding packages.simulation UNKNOWN "apt-get not available; upgrade simulation skipped"
    fi
  fi
else
  finding packages.holds UNKNOWN "not a dpkg/apt system; package hold and simulation checks are not implemented for this distribution" \
    "kernel, bootloader and module checks above still apply"
fi

# ================================================================ reboot marker
IFS=':' read -r -a markers <<<"$REBOOT_MARKERS"
for m in "${markers[@]}"; do
  if [ -e "$m" ]; then
    finding boot.reboot_required PASS "a reboot is pending ($m)" "the findings above describe what that reboot would do"
    break
  fi
done

# ================================================================ report
overall=PASS; worst=0
for s in "${F_STATUS[@]}"; do v="$(sev "$s")"; [ "$v" -gt "$worst" ] && { worst=$v; overall="$s"; }; done
case "$overall" in PASS) rc=0 ;; WARNING) rc=1 ;; BLOCKED) rc=2 ;; UNKNOWN) rc=3 ;; esac

json_str() { # escape for JSON; control characters other than \t \n \r are dropped
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037' | sed 's/\t/\\t/g; s/\r/\\r/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
  printf '"%s"' "$s"
}
json_list() { local first=1 x; printf '['; for x in "$@"; do [ $first = 1 ] || printf ','; first=0; json_str "$x"; done; printf ']'; }

if [ "$JSON" = 1 ]; then
  printf '{"schema":"ai-system-map/boot-safety/1","generated":%s,"overall":%s,"exit_code":%d,' \
    "$(json_str "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")" "$(json_str "$overall")" "$rc"
  printf '"host":{"os":%s,"bootloader":%s,"running_kernel":%s,"installed_kernels":%s,' \
    "$(json_str "$H_OS")" "$(json_str "$H_BOOTLOADER")" "$(json_str "${RUNNING_KERNEL:-UNKNOWN}")" "$(json_list "${INSTALLED_KERNELS[@]}")"
  printf '"next_boot":{"kernel":%s,"basis":%s,"one_time":%s},' \
    "$(json_str "${H_NEXT_KERNEL:-UNKNOWN}")" "$(json_str "$H_NEXT_BASIS")" "$H_NEXT_ONE_TIME"
  case "$H_NV_PRESENT" in true|false) nvp="$H_NV_PRESENT" ;; *) nvp='"UNKNOWN"' ;; esac
  printf '"gpu":{"nvidia_present":%s,"userspace_version":%s,"loaded_module_version":%s}},' \
    "$nvp" "$(json_str "${H_NV_USER:-}")" "$(json_str "${H_NV_LOADED:-}")"
  printf '"findings":['
  for i in "${!F_ID[@]}"; do
    [ "$i" -gt 0 ] && printf ','
    IFS=$'\x1f' read -r -a evs <<<"${F_EVIDENCE[$i]}"
    printf '{"id":%s,"status":%s,"summary":%s,"evidence":%s}' \
      "$(json_str "${F_ID[$i]}")" "$(json_str "${F_STATUS[$i]}")" "$(json_str "${F_SUMMARY[$i]}")" "$(json_list "${evs[@]}")"
  done
  printf ']}\n'
  exit $rc
fi

echo "AI System Map — boot safety preflight (Safe Update Guard)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Read-only evidence. Nothing was installed, built, changed or rebooted."
echo
printf 'os:             %s\n' "$H_OS"
printf 'bootloader:     %s\n' "$H_BOOTLOADER"
printf 'running kernel: %s\n' "${RUNNING_KERNEL:-UNKNOWN}"
printf 'next boot:      %s\n' "${H_NEXT_KERNEL:-UNKNOWN}"
[ "$H_NV_PRESENT" = true ] && printf 'nvidia:         userspace %s, loaded %s\n' "${H_NV_USER:-none}" "${H_NV_LOADED:-none}"
echo
echo "== FINDINGS =="
for i in "${!F_ID[@]}"; do
  printf '[%-7s] %s: %s\n' "${F_STATUS[$i]}" "${F_ID[$i]}" "${F_SUMMARY[$i]}"
  if [ -n "${F_EVIDENCE[$i]}" ]; then
    IFS=$'\x1f' read -r -a evs <<<"${F_EVIDENCE[$i]}"
    for e in "${evs[@]}"; do printf '          - %s\n' "$e"; done
  fi
done
echo
echo "== OVERALL: $overall =="
case "$overall" in
  BLOCKED) cat <<'EOF'
Do not reboot into the flagged kernel as it stands. Safe options, none of
which this script performs: install the matching driver module for that
kernel (prebuilt package, or DKMS followed by a verified build), or point the
bootloader at a kernel that has one, or hold the kernel meta-package so new
kernels stop arriving ahead of their driver. Re-run this check afterwards.
EOF
  ;;
  WARNING) echo "Review the WARNING lines before upgrading or rebooting." ;;
  UNKNOWN) echo "Some checks could not be verified from this account. Re-run with more privileges or supply --target." ;;
  PASS)    echo "No kernel/driver mismatch found for the next boot." ;;
esac
exit $rc
