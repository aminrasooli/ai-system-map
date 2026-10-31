#!/usr/bin/env bash
# check-home-exposure.sh — read-only check: can another local account read
# credential-shaped files inside a home directory that looks private?
#
# A home directory with mode 0750 or 0700 looks private. It stops being
# private when anything grants another principal the execute (traverse) bit
# on it:
#
#   - the "other" execute bit (mode 0751, 0755, ...),
#   - an owning group that has members besides the owner,
#   - a named POSIX ACL entry, such as one added so that a separate service
#     or AI-agent account can reach a single tool or work directory.
#
# Once a principal can traverse the home, every world-readable file below
# world-traversable directories is readable by that principal, including
# .env files, private keys and application databases that were only "safe"
# because the home directory was closed.
#
# This script COLLECTS EVIDENCE. It never prints file contents, never
# changes a permission, and never escalates. Paths and modes are printed so
# the owner can tighten them. When something cannot be determined, it says
# UNKNOWN.
#
# Usage: check-home-exposure.sh [--home DIR] [--max N]
#
# Exit codes:
#   0  PRIVATE, or TRAVERSABLE with no credential-shaped file reachable
#   1  EXPOSED: at least one credential-shaped file is reachable
#   2  UNKNOWN: the directory or its ACL could not be evaluated
#   64 usage error

set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n== %s ==\n' "$1"; }

HOME_DIR="${HOME:-}"
MAX=50

while [ $# -gt 0 ]; do
  case "$1" in
    --home) HOME_DIR="${2:-}"; shift 2 ;;
    --max)  MAX="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

case "$MAX" in ''|*[!0-9]*) echo "--max needs a number" >&2; exit 64 ;; esac

echo "AI System Map — home directory exposure check"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Read-only. File contents are never read or printed."

if [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ]; then
  echo
  echo "VERDICT: UNKNOWN — no readable directory given"
  exit 2
fi
HOME_DIR="$(cd "$HOME_DIR" 2>/dev/null && pwd -P)" || { echo "VERDICT: UNKNOWN — cannot enter directory"; exit 2; }

section "DIRECTORY"
mode="$(stat -c '%a' "$HOME_DIR" 2>/dev/null || echo '?')"
owner="$(stat -c '%U' "$HOME_DIR" 2>/dev/null || echo '?')"
group="$(stat -c '%G' "$HOME_DIR" 2>/dev/null || echo '?')"
printf 'path:   %s\nmode:   %s\nowner:  %s\ngroup:  %s\n' "$HOME_DIR" "$mode" "$owner" "$group"
if [ "$mode" = "?" ]; then
  echo
  echo "VERDICT: UNKNOWN — cannot stat directory"
  exit 2
fi

# Octal digits of the mode (last three).
m="${mode: -3}"
g_digit="${m:1:1}"
o_digit="${m:2:1}"

principals=()   # human-readable list of who can traverse besides the owner
unknown=0

section "WHO ELSE CAN TRAVERSE IT"

# Inside a user namespace, accounts outside the id map are invisible to
# stat/getfacl, so a grant to them cannot be seen from here.
if [ -r /proc/self/uid_map ] && ! awk '$1==0 && $2==0 && $3==4294967295 {f=1} END {exit !f}' /proc/self/uid_map; then
  echo "note:         running inside a user namespace; ids outside its map are not visible"
fi

# 1. other
if [ $(( o_digit & 1 )) -eq 1 ]; then
  principals+=("every local account (other has execute)")
  echo "other:        execute bit SET -> every local account can traverse"
else
  echo "other:        no execute bit"
fi

# 2. owning group with members besides the owner
if [ $(( g_digit & 1 )) -eq 1 ] && [ "$group" != "?" ]; then
  if have getent; then
    members="$(getent group "$group" 2>/dev/null | cut -d: -f4)"
    others="$(printf '%s' "$members" | tr ',' '\n' | grep -vxF -- "$owner" | grep -c . || true)"
    if [ "${others:-0}" -gt 0 ]; then
      principals+=("members of group '$group' ($others besides the owner)")
      echo "group:        '$group' has execute and $others member(s) besides the owner"
    else
      echo "group:        '$group' has execute; no listed members besides the owner"
      echo "              (accounts whose PRIMARY group is '$group' are not listed by getent)"
    fi
  else
    echo "group:        '$group' has execute; membership UNKNOWN (getent missing)"
    unknown=1
  fi
else
  echo "group:        no execute bit, or group unknown"
fi

# 3. POSIX ACL entries
if have getfacl; then
  acl="$(getfacl -n -p -- "$HOME_DIR" 2>/dev/null)" || acl=""
  if [ -z "$acl" ]; then
    echo "acl:          UNKNOWN (getfacl failed)"
    unknown=1
  else
    mask="$(printf '%s\n' "$acl" | awk -F: '$1=="mask" {print $3; exit}')"
    has_mask=0; [ -n "$mask" ] && has_mask=1
    [ -n "$mask" ] || mask="rwx"
    named="$(printf '%s\n' "$acl" | awk -F: '($1=="user"||$1=="group") && $2!="" {print $1":"$2":"$3}')"
    if [ -z "$named" ] && [ "$has_mask" -eq 1 ]; then
      # A mask without any visible named entry is either a leftover from a
      # removed entry, or an entry for an id this process cannot see: inside
      # a user namespace (container, sandbox) unmapped ids are dropped from
      # getfacl output. Do not report PRIVATE on that evidence.
      echo "acl:          a mask entry exists but no named entry is visible -> UNKNOWN"
      echo "              (entries for ids not mapped in this namespace are hidden;"
      echo "               re-run 'getfacl -n' from a normal host shell)"
      unknown=1
    elif [ -z "$named" ]; then
      echo "acl:          no named user/group entries"
    else
      while IFS=: read -r kind id perms; do
        perms="${perms%%[[:space:]]*}"
        # effective = entry AND mask; only the execute bit matters for traversal
        if [ "${perms:2:1}" = "x" ] && [ "${mask:2:1}" = "x" ]; then
          name="$id"
          if have getent; then
            db=passwd; [ "$kind" = "group" ] && db=group
            resolved="$(getent "$db" "$id" 2>/dev/null | cut -d: -f1)"
            [ -n "$resolved" ] && name="$resolved ($id)"
          fi
          principals+=("ACL $kind $name")
          echo "acl:          $kind $name can traverse (entry $perms, mask $mask)"
        else
          echo "acl:          $kind $id present without effective execute (entry $perms, mask $mask)"
        fi
      done <<EOF
$named
EOF
    fi
    if printf '%s\n' "$acl" | grep -q '^default:'; then
      echo "acl:          default ACL entries present (they apply to newly created files)"
    fi
  fi
else
  # Without getfacl, a '+' after the mode in ls means an ACL exists.
  if ls -ld -- "$HOME_DIR" 2>/dev/null | awk '{print $1}' | grep -q '+$'; then
    echo "acl:          an ACL is present but getfacl is not installed -> UNKNOWN"
    unknown=1
  else
    echo "acl:          none indicated (getfacl not installed; ls shows no '+')"
  fi
fi

section "CREDENTIAL-SHAPED FILES REACHABLE THROUGH WORLD-READABLE PATHS"

if [ "${#principals[@]}" -eq 0 ]; then
  echo "skipped: no principal besides the owner can traverse the directory"
  echo
  if [ "$unknown" -eq 1 ]; then
    echo "VERDICT: UNKNOWN — part of the access model could not be determined"
    exit 2
  fi
  echo "VERDICT: PRIVATE"
  exit 0
fi

echo "Walk rule: descend only into directories with the 'other' execute bit,"
echo "report regular files with the 'other' read bit. This is a LOWER BOUND"
echo "for group and ACL principals, which may reach more than 'other' can."
echo "Skipped for speed: .git node_modules .cache .npm .cargo .rustup"
echo "                   venv .venv site-packages __pycache__ snap"
echo

# Name patterns that usually hold credentials or private data. Templates
# (*.example, *.sample, *.template, *.dist) and public keys are excluded.
hits="$(
  find "$HOME_DIR" -xdev -mindepth 1 \
    \( -type d \( ! -perm -o+x -o -name .git -o -name node_modules -o -name .cache \
        -o -name .npm -o -name .cargo -o -name .rustup -o -name venv -o -name .venv \
        -o -name site-packages -o -name __pycache__ -o -name snap \) -prune \) \
    -o -type f -perm -o+r -size +0 \( \
        -name '.env' -o -name '.env.*' -o -name '*.env' \
        -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' -o -name '*.kdbx' \
        -o -name 'id_rsa' -o -name 'id_dsa' -o -name 'id_ecdsa' -o -name 'id_ed25519' \
        -o -name '.netrc' -o -name '.pgpass' -o -name '.git-credentials' -o -name '.msmtprc' \
        -o -name '.npmrc' -o -name '.pypirc' -o -name 'credentials' -o -name 'credentials.json' \
        -o -name 'kubeconfig' -o -name '*.kubeconfig' \
        -o -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \
      \) \
    ! -name '*.example' ! -name '*.sample' ! -name '*.template' ! -name '*.dist' \
    -printf '%m\t%P\n' 2>/dev/null | sort -k2
)"

if [ -z "$hits" ]; then
  echo "none found"
  echo
  if [ "$unknown" -eq 1 ]; then
    echo "VERDICT: UNKNOWN — part of the access model could not be determined"
    exit 2
  fi
  echo "VERDICT: TRAVERSABLE — no credential-shaped file is reachable"
  echo "Traversable by:"
  for p in "${principals[@]}"; do echo "  - $p"; done
  exit 0
fi

count="$(printf '%s\n' "$hits" | grep -c .)"
printf '%s\n' "$hits" | head -n "$MAX" | while IFS="$(printf '\t')" read -r fmode rel; do
  printf '  %-4s %s/%s\n' "$fmode" "$HOME_DIR" "$rel"
done
if [ "$count" -gt "$MAX" ]; then
  echo "  ... and $(( count - MAX )) more (raise --max to list them)"
fi

echo
echo "VERDICT: EXPOSED — $count credential-shaped file(s) readable by:"
for p in "${principals[@]}"; do echo "  - $p"; done
echo
echo "Remediation options (the owner decides; this script changes nothing):"
echo "  - remove the 'other' bits on the files or their directories"
echo "    (chmod o-rwx), after checking no other account must read them;"
echo "  - narrow the grant: give the extra account its own directory"
echo "    outside the home instead of a traverse ACL on the home itself;"
echo "  - remove the ACL entry when it is no longer needed (setfacl -x)."
exit 1
