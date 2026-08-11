#!/usr/bin/env python3
import pathlib
import sys


MARKER = "function set_apply_on_parse(map)\n\tif not map then return end\n"
PATCH = (
    "\tif map.config ~= appname then return end\n"
    "\tlocal old_on_after_commit = map.on_after_commit\n"
    "\tmap.on_after_commit = function(self)\n"
    "\t\tif old_on_after_commit then old_on_after_commit(self) end\n"
    '\t\tlocal enabled = self:get("@global[0]", "enabled")\n'
    '\t\tlocal action = enabled == "1" and "enable" or "disable"\n'
    '\t\tsys.call("/etc/init.d/passwall " .. action .. " >/dev/null 2>&1")\n'
    "\tend\n"
)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} API_LUA", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    content = path.read_text()

    if content.count("old_on_after_commit") == 1:
        return 0
    if content.count("old_on_after_commit") != 0:
        print("unexpected duplicate PassWall autostart hooks", file=sys.stderr)
        return 1
    if content.count(MARKER) != 1:
        print("PassWall apply hook marker is missing or ambiguous", file=sys.stderr)
        return 1

    path.write_text(content.replace(MARKER, MARKER + PATCH, 1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
