#!/usr/bin/env python3

import argparse
import gzip
import pathlib
import re
import struct
import zlib


FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


def be32(data, offset):
    return struct.unpack_from(">I", data, offset)[0]


def align4(value):
    return (value + 3) & ~3


def cstring(data, offset):
    end = data.find(b"\0", offset)
    if end < 0:
        raise ValueError("unterminated FDT string")
    return data[offset:end].decode("ascii")


def parse_fit(path):
    data = pathlib.Path(path).read_bytes()
    if len(data) < 40 or be32(data, 0) != FDT_MAGIC:
        raise ValueError("input is not an FDT/FIT image")

    total_size = be32(data, 4)
    struct_offset = be32(data, 8)
    strings_offset = be32(data, 12)
    strings_size = be32(data, 32)
    struct_size = be32(data, 36)

    if total_size > len(data):
        raise ValueError("FDT total size exceeds input size")
    if struct_offset + struct_size > total_size:
        raise ValueError("FDT structure block exceeds total size")
    if strings_offset + strings_size > total_size:
        raise ValueError("FDT strings block exceeds total size")

    position = struct_offset
    struct_end = struct_offset + struct_size
    stack = []
    properties = {}

    while position < struct_end:
        token = be32(data, position)
        position += 4

        if token == FDT_BEGIN_NODE:
            name = cstring(data, position)
            position = align4(position + len(name) + 1)
            stack.append(name)
            continue

        if token == FDT_END_NODE:
            if not stack:
                raise ValueError("unexpected FDT_END_NODE")
            stack.pop()
            continue

        if token == FDT_PROP:
            length = be32(data, position)
            name_offset = be32(data, position + 4)
            position += 8
            if position + length > struct_end:
                raise ValueError("FDT property exceeds structure block")
            name = cstring(data, strings_offset + name_offset)
            path_name = "/" + "/".join(part for part in stack if part)
            properties.setdefault(path_name, {})[name] = data[
                position : position + length
            ]
            position = align4(position + length)
            continue

        if token == FDT_NOP:
            continue

        if token == FDT_END:
            break

        raise ValueError(f"unknown FDT token 0x{token:08x}")

    return properties


def text_property(properties, path, name):
    value = properties.get(path, {}).get(name)
    if value is None:
        return None
    return value.rstrip(b"\0").decode("ascii")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    parser.add_argument("output_directory")
    args = parser.parse_args()

    properties = parse_fit(args.image)
    output = pathlib.Path(args.output_directory)
    output.mkdir(parents=True, exist_ok=True)

    image_paths = sorted(
        path
        for path in properties
        if path.startswith("/images/")
        and path.count("/") == 2
        and "data" in properties[path]
    )
    if not image_paths:
        raise ValueError("FIT contains no inline image data")

    for path in image_paths:
        node = path.rsplit("/", 1)[1]
        if not re.fullmatch(r"[A-Za-z0-9._@+-]+", node):
            raise ValueError(f"unsafe FIT image node name: {node}")

        payload = properties[path]["data"]
        hash_path = f"{path}/hash@1"
        algorithm = text_property(properties, hash_path, "algo")
        expected = properties.get(hash_path, {}).get("value")
        if algorithm != "crc32" or expected is None or len(expected) != 4:
            raise ValueError(f"{node} is missing a CRC32 hash")

        actual_crc = zlib.crc32(payload) & 0xFFFFFFFF
        expected_crc = struct.unpack(">I", expected)[0]
        if actual_crc != expected_crc:
            raise ValueError(
                f"{node} CRC32 mismatch: {actual_crc:08x} != {expected_crc:08x}"
            )

        image_type = text_property(properties, path, "type") or "unknown"
        compression = text_property(properties, path, "compression") or "none"
        if compression == "none":
            extracted = payload
        elif compression == "gzip":
            extracted = gzip.decompress(payload)
        else:
            raise ValueError(f"{node} uses unsupported compression: {compression}")

        destination = output / f"{node}.bin"
        destination.write_bytes(extracted)
        print(
            f"{node}\t{len(payload)}\t{len(extracted)}\t"
            f"{image_type}\t{compression}\t{actual_crc:08x}"
        )


if __name__ == "__main__":
    main()
