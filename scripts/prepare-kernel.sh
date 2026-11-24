#!/usr/bin/env bash
# Patch the OPPO tree, align its release string with the shipped firmware and
# merge the DroidSpaces config fragments. Stops before compiling so a broken
# configuration is reported in a few minutes instead of an hour.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${SRC_DIR:-$ROOT_DIR/kernel-src}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
BASE_CONFIG="${BASE_CONFIG:-$ROOT_DIR/configs/pjh110-device.config}"
EXPECTED_RELEASE="${EXPECTED_RELEASE:-5.10.226-android12-9-o-g18972ebc96a3}"
SOURCE_SUBLEVEL="${SOURCE_SUBLEVEL:-209}"

export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT:-arm-linux-gnueabi-}"

if [ ! -f "$SRC_DIR/Makefile" ]; then
  echo "ERROR: kernel source not found at $SRC_DIR" >&2
  exit 1
fi

cd "$SRC_DIR"

# kernel-src/ sits inside this git repository on the runner, so the tree's
# scripts/setlocalversion finds a git repo, sees HEAD is not a tagged commit
# and appends "+" to the release. The stock vermagic has no "+", and one
# stray character there makes every vendor module refuse to load.
echo "==> Disabling the setlocalversion '+' suffix"
python3 - scripts/setlocalversion <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()
needle = 'res="$res${scm:++}"'
if needle in src:
    open(path, "w").write(src.replace(needle, 'res="$res"'))
    print("    patched " + path)
else:
    print("    already clean")
PY
if grep -qF '${scm:++}' scripts/setlocalversion; then
  echo "ERROR: scripts/setlocalversion still appends '+' to the release" >&2
  exit 1
fi

echo "==> Applying DroidSpaces GKI kABI patches"
# The patches must land, otherwise CONFIG_SYSVIPC/CONFIG_POSIX_MQUEUE shift
# task_struct and user_struct and the stock vendor modules stop loading.
apply_kabi_patch() {
  local file="$1" marker="$2" name="$3"
  if grep -qF "$marker" "$file"; then
    echo "    already applied: $name"
    return
  fi
  echo "    applying: $name"
  patch -p1 --forward --no-backup-if-mismatch <"$ROOT_DIR/patches/$name"
  if ! grep -qF "$marker" "$file"; then
    echo "ERROR: $name did not modify $file as expected" >&2
    exit 1
  fi
}

apply_kabi_patch include/linux/sched.h \
  'ANDROID_KABI_USE(6, struct sysv_sem sysvsem)' \
  0001-sched-kabi-sysvipc.patch
apply_kabi_patch include/linux/sched/user.h \
  'ANDROID_KABI_USE(1, unsigned long mq_bytes)' \
  0002-user-kabi-posix-mqueue.patch

# The public OPPO branch is 5.10.209 while the shipped 870 firmware runs
# 5.10.226. The GKI KMI is stable inside a 5.10 android12 branch, and the
# release string has to match or every vendor module fails vermagic.
echo "==> Aligning kernel release with ${EXPECTED_RELEASE}"
if grep -q "^SUBLEVEL = ${SOURCE_SUBLEVEL}$" Makefile; then
  sed -i "s/^SUBLEVEL = ${SOURCE_SUBLEVEL}$/SUBLEVEL = 226/" Makefile
fi
grep -q '^SUBLEVEL = 226$' Makefile || {
  echo "ERROR: unexpected kernel version in Makefile" >&2
  exit 1
}

echo "==> Merging config fragments"
mkdir -p "$OUT_DIR"
cp "$BASE_CONFIG" "$OUT_DIR/.config"
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
"$SRC_DIR/scripts/kconfig/merge_config.sh" -m -O "$OUT_DIR" \
  "$OUT_DIR/.config" \
  "$ROOT_DIR/configs/droidspaces.fragment" \
  "$ROOT_DIR/configs/performance.fragment"

"$SRC_DIR/scripts/config" --file "$OUT_DIR/.config" \
  --set-str LOCALVERSION "${EXPECTED_RELEASE#5.10.226}"
"$SRC_DIR/scripts/config" --file "$OUT_DIR/.config" --disable LOCALVERSION_AUTO
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig

echo "==> Verifying final configuration"
missing=""
check_y() {
  grep -q "^CONFIG_$1=y$" "$OUT_DIR/.config" || missing="${missing} CONFIG_$1"
}

# DroidSpaces required + recommended (droidspaces.org/docs/kernel-configuration)
for opt in \
  SYSCTL SYSVIPC POSIX_MQUEUE NAMESPACES IPC_NS PID_NS UTS_NS USER_NS \
  SECCOMP SECCOMP_FILTER DEVTMPFS CGROUPS CGROUP_DEVICE CGROUP_SCHED \
  FAIR_GROUP_SCHED CGROUP_FREEZER CGROUP_NET_PRIO CGROUP_CPUACCT \
  MEMCG MEMCG_SWAP TMPFS_XATTR TMPFS_POSIX_ACL OVERLAY_FS FUSE_FS TUN \
  BLK_DEV_LOOP EXT4_FS FW_LOADER FW_LOADER_USER_HELPER FW_LOADER_COMPRESS \
  NET_NS VETH BRIDGE BRIDGE_NETFILTER NETFILTER NETFILTER_ADVANCED \
  NF_CONNTRACK NF_NAT NF_TABLES IP_NF_IPTABLES IP_NF_FILTER IP_NF_NAT \
  IP_NF_TARGET_MASQUERADE IP_NF_TARGET_REJECT IP6_NF_IPTABLES IP6_NF_FILTER \
  IP6_NF_MANGLE IP6_NF_NAT IP6_NF_TARGET_MASQUERADE IP6_NF_TARGET_REJECT \
  IPV6 IPV6_MULTIPLE_TABLES IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES \
  MACVLAN NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_TARGET_MASQUERADE \
  NETFILTER_XT_TARGET_TCPMSS NETFILTER_XT_MATCH_COMMENT \
  NETFILTER_XT_MATCH_CONNTRACK NETFILTER_XT_MATCH_STATE \
  NETFILTER_XT_MATCH_RECENT NETFILTER_XT_MATCH_LIMIT \
  NETFILTER_XT_TARGET_LOG IP_SET NETFILTER_XT_SET \
  SQUASHFS MODULES MODVERSIONS PREEMPT KASAN UBSAN CFI_CLANG
do
  check_y "$opt"
done

grep -qx "CONFIG_LOCALVERSION=\"${EXPECTED_RELEASE#5.10.226}\"" "$OUT_DIR/.config" ||
  missing="${missing} CONFIG_LOCALVERSION"

# Must stay off: they resize scheduler/cgroup structures and change the CRC of
# thousands of exported symbols, which bootloops a stock-module device.
for opt in CFS_BANDWIDTH CGROUP_PIDS LOCALVERSION_AUTO; do
  if grep -q "^CONFIG_$opt=y$" "$OUT_DIR/.config"; then
    missing="${missing} !CONFIG_$opt"
  fi
done

kver="$(awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3} /^EXTRAVERSION =/{e=$3} END{print v"."p"."s e}' Makefile)"
localver="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$OUT_DIR/.config")"
release="${kver}${localver}"
echo "    kernel release: ${release}"
if [ "$release" != "$EXPECTED_RELEASE" ]; then
  missing="${missing} release(${release}!=${EXPECTED_RELEASE})"
fi

if [ -n "$missing" ]; then
  echo "ERROR: unmet kernel configuration requirements:" >&2
  for item in $missing; do
    echo "    - $item" >&2
  done
  echo "Inspect $OUT_DIR/.config, or check whether a new symbol needs a dependency." >&2
  exit 1
fi

echo "    all DroidSpaces requirements satisfied"
