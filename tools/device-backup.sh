#!/system/bin/sh
# Dump the partitions that matter for a kernel-only modification on PJH110.
#
# Run on the phone as root:
#   adb push tools/device-backup.sh /data/local/tmp/bk.sh
#   adb shell su -c "sh /data/local/tmp/bk.sh /data/local/tmp/bk"
# then pull /data/local/tmp/bk to the PC and verify SHA256SUMS.
#
# Deliberately excluded: userdata, super, metadata, md1img_*, expdb,
# oplusreserve*, logo, splash_odm, and the other firmware blobs that come
# back with a stock ROM flash.
set -e

OUT="${1:-/data/local/tmp/bk}"
mkdir -p "$OUT"

PARTITIONS="
boot_a boot_b
init_boot_a init_boot_b
vendor_boot_a vendor_boot_b
dtbo_a dtbo_b
vbmeta_a vbmeta_b
vbmeta_system_a vbmeta_system_b
vbmeta_vendor_a vbmeta_vendor_b
persist
nvram nvdata nvcfg
protect1 protect2
seccfg frp otp proinfo ocdt sec1
para misc param boot_para
flashinfo
preloader_raw_a preloader_raw_b
lk_a lk_b
"

cd "$OUT"
for p in $PARTITIONS; do
  src="/dev/block/by-name/$p"
  if [ ! -e "$src" ]; then
    echo "SKIP $p (no such partition)"
    continue
  fi
  echo "==> $p"
  dd if="$src" of="$p.img" bs=1048576 2>&1 | tail -n 1
done

sha256sum ./*.img >SHA256SUMS
echo
du -sh "$OUT"
