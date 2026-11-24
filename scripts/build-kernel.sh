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

if [ "${PREPARED:-0}" != "1" ]; then
  bash "$ROOT_DIR/scripts/prepare-kernel.sh"
fi

echo "==> Building kernel images with ${JOBS} job slot(s)"
cd "$SRC_DIR"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-github}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-actions}"

make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 -j"$JOBS" Image
make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 -j"$JOBS" Image.gz
if ! make O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 -j"$JOBS" Image.lz4; then
  echo "WARNING: Image.lz4 target failed, continuing without it" >&2
fi

echo "==> Collecting artifacts"
mkdir -p "$ARTIFACT_DIR"
cp "$OUT_DIR/arch/arm64/boot/Image" "$ARTIFACT_DIR/"
cp "$OUT_DIR/arch/arm64/boot/Image.gz" "$ARTIFACT_DIR/"
if [ -f "$OUT_DIR/arch/arm64/boot/Image.lz4" ]; then
  cp "$OUT_DIR/arch/arm64/boot/Image.lz4" "$ARTIFACT_DIR/"
fi
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
ls -lh "$ARTIFACT_DIR"
