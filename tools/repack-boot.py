#!/usr/bin/env python3
"""Swap the kernel inside an OPPO PJH110 boot.img (header v4, 4 KiB pages).

    python3 tools/repack-boot.py --stock boot_a.img --kernel Image.gz \
        --out boot-droidspaces.img

Layout measured on PJH110_15.0.0.870:

    page 0                 header ("ANDROID!", header_version 4)
    page 1 .. 1+kpages     kernel, gzip
    .. + rpages            ramdisk, lz4 legacy
    page-aligned           AVB vbmeta blob, then zeros, footer in the last
                           64 bytes of the partition

This tree writes kernel_size at +8 and ramdisk_size at +12 (the AOSP layout
puts kernel_addr at +12), and leaves page_size at +36 zero, so the offsets are
derived from the image itself instead of trusting the header.

The AVB blob is copied over with its footer re-pointed at the new layout. It
is a signature over the *stock* boot image, so verification of the result will
fail - that is unavoidable without the signing key, and the device already
boots unlocked (oplusboot.verifiedbootstate=orange).
"""
import argparse
import hashlib
import struct
import sys

PAGE = 4096
RAMDISK_MAGICS = (
    b"\x1f\x8b",  # gzip
    b"\x02\x21\x4c\x18",  # lz4 legacy frame
    b"\x04\x22\x4d\x18",  # lz4 frame
    b"070701",  # cpio newc
    b"070702",  # cpio crc
    b"\xfd7zXZ\x00",  # xz
)


def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def align(value):
    return (value + PAGE - 1) // PAGE * PAGE


def find_ramdisk(img, start):
    for off in range(start, min(start + PAGE, len(img))):
        if any(img.startswith(m, off) for m in RAMDISK_MAGICS):
            return off
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stock", required=True)
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    img = open(args.stock, "rb").read()
    if img[:8] != b"ANDROID!":
        sys.exit("stock image is not an Android boot image")
    if u32(img, 40) != 4:
        sys.exit(f"unexpected header version {u32(img, 40)}")

    kernel_size = u32(img, 8)
    ramdisk_size = u32(img, 12)
    ramdisk_off = align(PAGE + kernel_size)
    real_off = find_ramdisk(img, ramdisk_off)
    if real_off is None:
        sys.exit("could not locate the ramdisk")
    ramdisk = img[real_off:real_off + ramdisk_size]
    # mkbootimg leaves one 4 KiB "boot signature" block between the ramdisk
    # and the AVB data on header v3/v4; keep whatever is in there.
    gap_start = align(real_off + ramdisk_size)
    avb_off = None
    for off in range(gap_start, gap_start + 4 * PAGE, PAGE):
        if img[off:off + 4] == b"AVB0":
            avb_off = off
            break
    if avb_off is None:
        sys.exit("no AVB blob found after the ramdisk")
    gap = img[gap_start:avb_off]
    vbmeta_size = struct.unpack_from(">Q", img, len(img) - 64 + 28)[0]
    vbmeta = img[avb_off:avb_off + vbmeta_size]
    print(f"stock: kernel={kernel_size} ramdisk={ramdisk_size} "
          f"ramdisk@{real_off} gap={len(gap)} avb@{avb_off} "
          f"vbmeta={vbmeta_size} partition={len(img)}")

    kernel = open(args.kernel, "rb").read()
    if kernel.startswith(b"ANDROID!"):
        sys.exit("--kernel looks like a boot image, not a kernel.gz")

    header = bytearray(img[:PAGE])
    struct.pack_into("<I", header, 8, len(kernel))
    struct.pack_into("<I", header, 12, len(ramdisk))
    new_id = hashlib.sha1()
    new_id.update(kernel + struct.pack("<I", len(kernel)))
    new_id.update(ramdisk + struct.pack("<I", len(ramdisk)))
    header[576:576 + 20] = new_id.digest()

    def pad(data):
        return data + b"\x00" * (align(len(data)) - len(data))

    body = bytes(header) + pad(kernel) + pad(ramdisk) + gap
    new_avb_off = len(body)
    out = bytearray(body + vbmeta)
    out.extend(b"\x00" * (len(img) - 64 - len(out)))
    footer = bytearray(img[-64:])
    struct.pack_into(">Q", footer, 12, new_avb_off)  # original_image_size
    struct.pack_into(">Q", footer, 20, new_avb_off)  # vbmeta_offset
    out.extend(footer)
    assert len(out) == len(img), (len(out), len(img))
    open(args.out, "wb").write(out)

    check = open(args.out, "rb").read()
    assert u32(check, 8) == len(kernel)
    assert u32(check, 12) == len(ramdisk)
    assert find_ramdisk(check, align(PAGE + len(kernel))) == align(PAGE + len(kernel))
    assert check[new_avb_off:new_avb_off + 4] == b"AVB0"
    assert check[align(align(PAGE + len(kernel)) + len(ramdisk)):
                 align(align(PAGE + len(kernel)) + len(ramdisk)) + len(gap)] == gap
    print(f"wrote {args.out}: kernel={len(kernel)} ramdisk={len(ramdisk)} "
          f"ramdisk@{align(PAGE + len(kernel))} avb@{new_avb_off} "
          f"partition={len(out)}")


if __name__ == "__main__":
    main()
