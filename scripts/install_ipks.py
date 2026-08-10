#!/usr/bin/env python3
import argparse
import io
import os
import pathlib
import re
import subprocess
import tarfile
import tempfile


def read_ar(data):
    offset = 8
    members = {}
    while offset + 60 <= len(data):
        header = data[offset:offset + 60]
        name = header[:16].decode("ascii").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        start = offset + 60
        members[name] = data[start:start + size]
        offset = start + size + (size % 2)
    return members


def read_ipk(path):
    data = path.read_bytes()
    if data.startswith(b"!<arch>\n"):
        return read_ar(data)

    members = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
            for item in archive.getmembers():
                if not item.isfile():
                    continue
                name = pathlib.PurePosixPath(item.name).name
                if name.startswith(("control.tar", "data.tar", "debian-binary")):
                    members[name] = archive.extractfile(item).read()
    except tarfile.TarError as error:
        raise ValueError(f"{path} is not a supported IPK archive") from error

    if not any(name.startswith("control.tar") for name in members):
        raise ValueError(f"{path} has no control archive")
    if not any(name.startswith("data.tar") for name in members):
        raise ValueError(f"{path} has no data archive")
    return members


def extract_tar(blob, name, destination):
    if name.endswith(".zst"):
        with tempfile.NamedTemporaryFile(suffix=".tar.zst") as temp:
            temp.write(blob)
            temp.flush()
            listing = subprocess.run(
                ["tar", "--zstd", "-tf", temp.name],
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.splitlines()
            subprocess.run(
                ["tar", "--zstd", "-xpf", temp.name, "-C", str(destination)],
                check=True,
            )
        return listing
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:*") as archive:
        listing = [item.name for item in archive.getmembers()]
        archive.extractall(destination)
        return listing


def parse_control(text):
    fields = {}
    current = None
    for line in text.splitlines():
        if line[:1].isspace() and current:
            fields[current] += " " + line.strip()
        elif ":" in line:
            current, value = line.split(":", 1)
            fields[current] = value.strip()
    return fields


def control_from_ipk(path):
    members = read_ipk(path)
    control_name = next(name for name in members if name.startswith("control.tar"))
    blob = members[control_name]
    if control_name.endswith(".zst"):
        with tempfile.TemporaryDirectory() as temp:
            extract_tar(blob, control_name, pathlib.Path(temp))
            text = pathlib.Path(temp, "control").read_text(errors="replace")
    else:
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:*") as archive:
            member = next(item for item in archive.getmembers()
                          if pathlib.PurePosixPath(item.name).name == "control")
            text = archive.extractfile(member).read().decode(errors="replace")
    return parse_control(text), text


def installed_from_status(path):
    if not path.exists():
        return set()
    return set(re.findall(r"^Package:\s*(\S+)", path.read_text(errors="replace"),
                          flags=re.MULTILINE))


def dependency_choices(value):
    if not value:
        return []
    result = []
    for group in value.split(","):
        choices = []
        for item in group.split("|"):
            name = re.sub(r"\s*\(.*?\)\s*", "", item).strip()
            if name:
                choices.append(name)
        if choices:
            result.append(choices)
    return result


def remove_package(root, status_path, package):
    info_dir = root / "usr/lib/opkg/info"
    list_path = info_dir / f"{package}.list"
    if list_path.exists():
        for entry in list_path.read_text(errors="replace").splitlines():
            relative = entry.lstrip("/")
            if not relative:
                continue
            path = root / relative
            if path.is_symlink() or path.is_file():
                path.unlink()
        list_path.unlink()

    for path in info_dir.glob(f"{package}.*"):
        if path.is_symlink() or path.is_file():
            path.unlink()

    paragraphs = status_path.read_text(errors="replace").split("\n\n")
    kept = [
        paragraph for paragraph in paragraphs
        if not re.search(
            rf"^Package:\s*{re.escape(package)}\s*$",
            paragraph,
            flags=re.MULTILINE,
        )
    ]
    status_path.write_text(
        "\n\n".join(paragraph for paragraph in kept if paragraph.strip()) + "\n",
        encoding="utf-8",
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipk-root", type=pathlib.Path, required=True)
    parser.add_argument("--base-status", type=pathlib.Path, required=True)
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--remove-package", action="append", default=[])
    parser.add_argument("packages", nargs="+")
    args = parser.parse_args()

    args.root.mkdir(parents=True, exist_ok=True)
    status_path = args.root / "usr/lib/opkg/status"
    status_path.parent.mkdir(parents=True, exist_ok=True)
    status_path.write_bytes(args.base_status.read_bytes())
    for package in args.remove_package:
        remove_package(args.root, status_path, package)

    package_files = {}
    controls = {}
    raw_controls = {}
    providers = {}
    for path in args.ipk_root.rglob("*.ipk"):
        try:
            fields, raw = control_from_ipk(path)
        except (KeyError, StopIteration, ValueError, tarfile.TarError) as error:
            print(f"skip unreadable package\t{path.name}\t{error}")
            continue
        name = fields.get("Package")
        if not name:
            continue
        package_files[name] = path
        controls[name] = fields
        raw_controls[name] = raw
        providers.setdefault(name, name)
        for provided in fields.get("Provides", "").split(","):
            provided = re.sub(r"\s*\(.*?\)\s*", "", provided).strip()
            if provided:
                providers.setdefault(provided, name)

    installed = installed_from_status(status_path)
    selected = []
    visiting = set()

    def select(name):
        if name in installed or name in selected:
            return
        actual = providers.get(name, name)
        if actual in installed or actual in selected:
            return
        if actual in visiting:
            return
        if actual not in controls:
            raise RuntimeError(f"missing dependency package: {name}")
        visiting.add(actual)
        for choices in dependency_choices(controls[actual].get("Depends")):
            choice = next((item for item in choices
                           if item in installed or item in providers), choices[0])
            select(choice)
        visiting.remove(actual)
        selected.append(actual)

    for package in args.packages:
        select(package)

    info_dir = args.root / "usr/lib/opkg/info"
    info_dir.mkdir(parents=True, exist_ok=True)
    with status_path.open("a", encoding="utf-8") as status:
        for name in selected:
            path = package_files[name]
            members = read_ipk(path)
            data_name = next(item for item in members if item.startswith("data.tar"))
            files = extract_tar(members[data_name], data_name, args.root)
            control = raw_controls[name].rstrip()
            if not re.search(r"^Status:", control, flags=re.MULTILINE):
                control += "\nStatus: install user installed"
            status.write("\n" + control + "\n")
            (info_dir / f"{name}.control").write_text(
                control + "\n", encoding="utf-8"
            )
            installed_files = []
            for item in files:
                normalized = "/" + item.lstrip("./")
                if normalized != "/" and not normalized.endswith("/"):
                    installed_files.append(normalized)
            (info_dir / f"{name}.list").write_text(
                "\n".join(installed_files) + "\n", encoding="utf-8"
            )
            print(f"{name}\t{path.name}")

    rc_dir = args.root / "etc/rc.d"
    if rc_dir.exists():
        for path in rc_dir.glob("*passwall*"):
            path.unlink()

    defaults = args.root / "etc/uci-defaults/99-passwall-disabled"
    defaults.parent.mkdir(parents=True, exist_ok=True)
    defaults.write_text(
        "#!/bin/sh\n"
        "uci -q set passwall.@global[0].enabled='0'\n"
        "uci -q commit passwall\n"
        "/etc/init.d/passwall disable >/dev/null 2>&1 || true\n"
        "exit 0\n",
        encoding="ascii",
    )
    os.chmod(defaults, 0o755)

    manifest = args.root.parent / "passwall-packages.txt"
    manifest.write_text("\n".join(selected) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
