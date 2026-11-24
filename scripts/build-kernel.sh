#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${SRC_DIR:-$ROOT_DIR/kernel-src}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/artifacts}"
JOBS="${JOBS:-$(nproc)}"

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

echo "==> Applying DroidSpaces kABI patches"
if ! grep -q 'ANDROID_KABI_USE(6, struct sysv_sem sysvsem)' include/linux/sched.h; then
  git apply --verbose "$ROOT_DIR/patches/0001-sched-kabi-sysvipc.patch"
fi
if ! grep -q 'ANDROID_KABI_USE(1, unsigned long mq_bytes)' include/linux/sched/user.h; then
  git apply --verbose "$ROOT_DIR/patches/0002-user-kabi-posix-mqueue.patch"
fi

# The public OPPO branch is 5.10.209, but the installed 870 firmware ships
# 5.10.226 vendor modules. The GKI KMI is stable within 5.10, and matching the
# release string is required so the stock modules pass the vermagic check.
echo "==> Aligning kernel release with stock 5.10.226 vermagic"
if grep -q '^SUBLEVEL = 209$' Makefile; then
  sed -i 's/^SUBLEVEL = 209$/SUBLEVEL = 226/' Makefile
fi
grep -q '^SUBLEVEL = 226$' Makefile || {
  echo "ERROR: unexpected kernel version in Makefile" >&2
  exit 1
}

echo "==> Preparing config"
mkdir -p "$OUT_DIR"
cp "$ROOT_DIR/configs/pjh110-device.config" "$OUT_DIR/.config"

make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
"$SRC_DIR/scripts/kconfig/merge_config.sh" -m -O "$OUT_DIR" \
  "$OUT_DIR/.config" \
  "$ROOT_DIR/configs/droidspaces.fragment" \
  "$ROOT_DIR/configs/performance.fragment"
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig

# Exact vermagic of the installed PJH110_15.0.0.870 kernel.
"$SRC_DIR/scripts/config" --file "$OUT_DIR/.config" \
  --set-str LOCALVERSION "-android12-9-o-g18972ebc96a3"
"$SRC_DIR/scripts/config" --file "$OUT_DIR/.config" --disable LOCALVERSION_AUTO
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig

check_y() {
  grep -q "^CONFIG_$1=y$" "$OUT_DIR/.config" || {
    echo "ERROR: required option CONFIG_$1 is not enabled" >&2
    exit 1
  }
}

check_not_set() {
  if grep -q "^CONFIG_$1=y$" "$OUT_DIR/.config"; then
    echo "ERROR: CONFIG_$1 must stay disabled on this GKI build" >&2
    exit 1
  fi
}

echo "==> Verifying DroidSpaces requirements"
for opt in \
  SYSVIPC POSIX_MQUEUE IPC_NS PID_NS UTS_NS USER_NS \
  SECCOMP SECCOMP_FILTER DEVTMPFS CGROUP_DEVICE \
  NET_NS VETH BRIDGE BRIDGE_NETFILTER NF_TABLES \
  MACVLAN IP6_NF_NAT IP6_NF_TARGET_MASQUERADE \
  NETFILTER_XT_MATCH_ADDRTYPE IP_SET NETFILTER_XT_SET \
  TMPFS_XATTR TMPFS_POSIX_ACL \
  MODULES MODVERSIONS PREEMPT KASAN UBSAN
do
  check_y "$opt"
done

check_not_set CFS_BANDWIDTH
check_not_set CGROUP_PIDS

echo "==> Building Image.lz4 with $(nproc) job slot(s)"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-github}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-actions}"
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 -j"$JOBS" Image.lz4

echo "==> Collecting artifacts"
mkdir -p "$ARTIFACT_DIR"
cp "$OUT_DIR/arch/arm64/boot/Image.lz4" "$ARTIFACT_DIR/"
cp "$OUT_DIR/arch/arm64/boot/Image" "$ARTIFACT_DIR/"
cp "$OUT_DIR/System.map" "$ARTIFACT_DIR/"
cp "$OUT_DIR/.config" "$ARTIFACT_DIR/config"
if [ -f "$OUT_DIR/Module.symvers" ]; then
  cp "$OUT_DIR/Module.symvers" "$ARTIFACT_DIR/"
fi

cat >"$ARTIFACT_DIR/build-info.txt" <<EOF
source_repo=oppo-source/android_kernel_oppo_mt6896
source_branch=oppo/mt6896_v_15.0.0_reno11
source_commit=65da65bd3ececbd209a03c1357175ba6f2efb12e
source_sublevel=209
vermagic=5.10.226-android12-9-o-g18972ebc96a3
device=OPPO PJH110 (Reno11 5G, MT6896)
droidspaces_sysvipc_kabi=patched
droidspaces_posix_mqueue_kabi=patched
CFS_BANDWIDTH=disabled
CGROUP_PIDS=disabled
EOF

echo "==> Done"
