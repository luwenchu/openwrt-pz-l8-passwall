#!/usr/bin/env python3
import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} NFTABLES_SH", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    content = path.read_text()
    reject_count = content.count("counter reject")

    if reject_count == 0:
        if "counter drop" not in content:
            print("PassWall nftables script has no supported blocking action", file=sys.stderr)
            return 1
        return 0

    path.write_text(content.replace("counter reject", "counter drop"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
