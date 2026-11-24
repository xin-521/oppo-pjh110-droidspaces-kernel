#!/usr/bin/env bash
# Fetch the OPPO kernel tree and the vendor/module tree it symlinks into.
#
# The public OPPO kernel tree keeps its vendor drivers outside the kernel
# repo and links them back in, e.g.
#   kernel/oplus_cpu            -> ../../vendor/oplus/kernel/cpu
#   drivers/soc/oplus/hans      -> ../../../../vendor/oplus/kernel/hans
# A plain tarball keeps those symlinks but they dangle, so the first thing
# that touches them dies:
#   init/Kconfig:858: can't open file "kernel/oplus_cpu/sched/Kconfig"
# Placing the module repo at $ROOT_DIR/vendor satisfies every one of them.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${SRC_DIR:-$ROOT_DIR/kernel-src}"
MODULES_DIR="${MODULES_DIR:-$ROOT_DIR/kernel-modules}"
KERNEL_REPO="${KERNEL_REPO:-oppo-source/android_kernel_oppo_mt6896}"
KERNEL_COMMIT="${KERNEL_COMMIT:-65da65bd3ececbd209a03c1357175ba6f2efb12e}"
MODULES_REPO="${MODULES_REPO:-oppo-source/android_kernel_modules_oppo_mt6896}"
MODULES_BRANCH="${MODULES_BRANCH:-oppo/mt6896_v_15.0.0_reno11}"

if [ ! -f "$SRC_DIR/Makefile" ]; then
  echo "==> Downloading ${KERNEL_REPO}@${KERNEL_COMMIT}"
  rm -rf "$SRC_DIR"
  mkdir -p "$SRC_DIR"
  curl -fL --retry 5 --retry-delay 5 \
    "https://codeload.github.com/${KERNEL_REPO}/tar.gz/${KERNEL_COMMIT}" \
    -o /tmp/oppo-kernel.tar.gz
  tar -xzf /tmp/oppo-kernel.tar.gz -C "$SRC_DIR" --strip-components=1
  rm -f /tmp/oppo-kernel.tar.gz
fi

if [ ! -d "$MODULES_DIR/vendor/oplus/kernel" ]; then
  echo "==> Downloading ${MODULES_REPO} (${MODULES_BRANCH})"
  rm -rf "$MODULES_DIR"
  git clone --depth 1 --single-branch --branch "$MODULES_BRANCH" \
    "https://github.com/${MODULES_REPO}.git" "$MODULES_DIR"
fi

# Every vendor symlink in the kernel tree walks up to the parent of
# kernel-src/, which is exactly $ROOT_DIR.
ln -sfn "$MODULES_DIR/vendor" "$ROOT_DIR/vendor"

echo "==> Checking vendor symlinks"
broken=0
checked=0
while IFS= read -r link; do
  target="$(readlink "$link")"
  case "$target" in
    *vendor/*) ;;
    *) continue ;;
  esac
  checked=$((checked + 1))
  if [ ! -e "$link" ]; then
    echo "    BROKEN: ${link#"$ROOT_DIR"/} -> $target"
    broken=$((broken + 1))
  fi
done < <(find "$SRC_DIR" -type l)

echo "    ${checked} vendor symlinks checked, ${broken} broken"
if [ "$broken" -ne 0 ]; then
  echo "ERROR: vendor tree does not satisfy the kernel symlinks" >&2
  exit 1
fi

du -sh "$SRC_DIR" "$MODULES_DIR"
