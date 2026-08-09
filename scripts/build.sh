#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
"$repo_root/scripts/build-passwall.sh"
"$repo_root/scripts/repack-firmware.sh"

