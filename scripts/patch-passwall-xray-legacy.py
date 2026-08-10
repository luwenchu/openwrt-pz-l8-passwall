#!/usr/bin/env python3
import pathlib
import sys


CALL = (
    "\tif $XRAY_BIN version 2>/dev/null | head -n1 | grep -q '^Xray 1\\.'; then\n"
    '\t\tlua /usr/share/passwall/xray_legacy_compat.lua "$config_file" "$node"\n'
    "\tfi\n"
)
MARKER = '\tlua $UTIL_XRAY gen_config "${_json_arg}" > $config_file\n'


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} APP_SH", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    content = path.read_text()

    if content.count("xray_legacy_compat.lua") == 1:
        return 0
    if content.count("xray_legacy_compat.lua") != 0:
        print("unexpected duplicate Xray compatibility calls", file=sys.stderr)
        return 1
    if content.count(MARKER) != 1:
        print("PassWall Xray config-generation marker is missing or ambiguous", file=sys.stderr)
        return 1

    path.write_text(content.replace(MARKER, MARKER + CALL, 1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
