#!/usr/bin/env python3
import argparse
import pathlib
import struct

PEB_SIZE = 0x20000
EC_MAGIC = 0x55424923
VID_MAGIC = 0x55424921
VOLUME_NAMES = {
    0: "kernel.bin",
    1: "rootfs.squashfs",
    2: "rootfs_data.bin",
}


def be32(data, offset):
    return struct.unpack_from(">I", data, offset)[0]


def be64(data, offset):
    return struct.unpack_from(">Q", data, offset)[0]


def trim_volume(volume_id, data):
    if volume_id == 0 and data[:4] == b"\xd0\x0d\xfe\xed":
        size = be32(data, 4)
        if size <= len(data):
            return data[:size]
    if volume_id == 1 and data[:4] == b"hsqs" and len(data) >= 48:
        size = struct.unpack_from("<Q", data, 40)[0]
        if size <= len(data):
            return data[:size]
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()

    image = args.image.read_bytes()
    args.output.mkdir(parents=True, exist_ok=True)
    selected = {}

    for peb_offset in range(0, len(image) - PEB_SIZE + 1, PEB_SIZE):
        if be32(image, peb_offset) != EC_MAGIC:
            continue
        vid_offset = be32(image, peb_offset + 16)
        data_offset = be32(image, peb_offset + 20)
        vid = peb_offset + vid_offset
        if be32(image, vid) != VID_MAGIC:
            continue

        volume_id = be32(image, vid + 8)
        logical_number = be32(image, vid + 12)
        data_pad = be32(image, vid + 28)
        sequence = be64(image, vid + 32)
        if volume_id >= 0x7FFFEFFF:
            continue

        key = (volume_id, logical_number)
        entry = (
            sequence,
            peb_offset + data_offset,
            PEB_SIZE - data_offset - data_pad,
        )
        if key not in selected or selected[key][0] < sequence:
            selected[key] = entry

    volume_ids = sorted({key[0] for key in selected})
    for volume_id in volume_ids:
        chunks = []
        for key in sorted(k for k in selected if k[0] == volume_id):
            _, offset, length = selected[key]
            chunks.append(image[offset:offset + length])
        data = trim_volume(volume_id, b"".join(chunks))
        name = VOLUME_NAMES.get(volume_id, f"volume-{volume_id}.bin")
        (args.output / name).write_bytes(data)
        print(f"{name}\t{len(data)}")


if __name__ == "__main__":
    main()

