#!/usr/bin/env bash
#
# scripts/run-qemu.sh — boot the evasive-linux demo image. The init
# script inside the initramfs runs the demo and powers off.
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

TIMEOUT="${TIMEOUT:-90}"
MEM="${MEM:-2G}"

# Pick gtimeout on macOS, timeout on Linux.
if command -v gtimeout >/dev/null 2>&1; then
    TO=gtimeout
elif command -v timeout >/dev/null 2>&1; then
    TO=timeout
else
    echo "Neither gtimeout nor timeout found. Install coreutils." >&2
    exit 1
fi

exec "${TO}" "${TIMEOUT}" qemu-system-x86_64 \
    -m "${MEM}" \
    -kernel build/bzImage \
    -initrd build/rootfs.cpio.gz \
    -append "console=ttyS0 panic=5 loglevel=3" \
    -nographic -no-reboot -accel tcg
