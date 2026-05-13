#!/usr/bin/env bash
#
# scripts/build-livepatch-demo.sh — build a vanilla Linux 6.6.30 kernel
# with CONFIG_LIVEPATCH enabled, build the canonical
# samples/livepatch/livepatch-sample.ko, build a busybox initramfs that
# auto-demonstrates one full livepatch cycle on boot.
#
# Output:
#   build/bzImage                — kernel
#   build/livepatch-sample.ko    — out-of-initramfs copy for inspection
#   build/rootfs.cpio.gz         — initramfs (busybox + .ko + demo init)
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

echo "=== Step 1: build kbuild container (if missing) ==="
if ! docker image inspect evasive-linux-kbuild >/dev/null 2>&1; then
    # --load so the image lands in the daemon image store (not just the
    # buildx OCI cache) — otherwise `docker run` further down can't see
    # it under Docker Desktop with containerd image store enabled.
    docker buildx build --load \
        -t evasive-linux-kbuild \
        -f docker/Dockerfile.kbuild .
else
    echo "  evasive-linux-kbuild image present"
fi

mkdir -p build

# The driver script that runs INSIDE the container.
cat > tmp-driver.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail
cd /work

echo "================================================="
echo "=== Build kernel with CONFIG_LIVEPATCH ==="
echo "================================================="

cd /opt/linux
make mrproper >/dev/null 2>&1 || true
make tinyconfig >/dev/null
cat /work/kernel/livepatch.config >> .config
make olddefconfig >/dev/null

echo "Effective livepatch config:"
grep -E "^CONFIG_(LIVEPATCH|DYNAMIC_FTRACE|UNWINDER_ORC|SAMPLE_LIVEPATCH)" .config

echo "=== Building bzImage + modules ==="
# vmlinux + bzImage first.
make -j"$(nproc)" bzImage 2>&1 | tail -3
# The livepatch sample as a module.
make -j"$(nproc)" modules 2>&1 | tail -3

cp arch/x86/boot/bzImage /work/build/bzImage
# Find and extract the livepatch sample.
LP_KO=$(find samples/livepatch -name 'livepatch-sample.ko' | head -1)
if [ -z "${LP_KO}" ]; then
    echo "ERROR: livepatch-sample.ko not found after build"
    find samples -name '*.ko' || true
    exit 1
fi
cp "${LP_KO}" /work/build/livepatch-sample.ko
echo "  bzImage:               $(ls -la /work/build/bzImage    | awk '{print $5}') bytes"
echo "  livepatch-sample.ko:   $(ls -la /work/build/livepatch-sample.ko | awk '{print $5}') bytes"

echo "================================================="
echo "=== Build busybox (static, glibc) ==="
echo "================================================="
cd /opt/busybox
make distclean >/dev/null 2>&1 || true
make defconfig >/dev/null
sed -i 's|^# CONFIG_STATIC.*|CONFIG_STATIC=y|' .config
# Disable features that pull in TLS/utmp/wtmp/tc deps.
for cfg in CONFIG_FEATURE_WTMP CONFIG_FEATURE_UTMP CONFIG_TC; do
    sed -i "s|^${cfg}=y|# ${cfg} is not set|" .config
done
make -j"$(nproc)" >/dev/null 2>&1
cp busybox /work/build/busybox
echo "  busybox: $(ls -la /work/build/busybox | awk '{print $5}') bytes (static)"

echo "================================================="
echo "=== Assemble initramfs with demo init ==="
echo "================================================="
ROOT=/tmp/rootfs
rm -rf "${ROOT}"
mkdir -p "${ROOT}"/{bin,sbin,etc,proc,sys,dev,tmp,root,lib/modules}
cp /work/build/busybox "${ROOT}/bin/busybox"
for a in ash sh ls cat mount echo poweroff init insmod rmmod sleep ln; do
    ln -sf busybox "${ROOT}/bin/${a}"
done
cp /work/build/livepatch-sample.ko "${ROOT}/lib/modules/livepatch-sample.ko"

cat > "${ROOT}/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox mount -t devtmpfs none /dev 2>/dev/null

echo
echo "============================================================="
echo "  evasive-linux demo 01 — single livepatch"
echo "============================================================="
echo
echo "[1] Baseline /proc/cmdline (kernel's own cmdline_proc_show):"
echo -n "    "
/bin/busybox cat /proc/cmdline
echo
echo "[2] Loading livepatch-sample.ko ..."
/bin/busybox insmod /lib/modules/livepatch-sample.ko
echo "    -> insmod exit $?"
echo "    livepatch sysfs:"
/bin/busybox ls /sys/kernel/livepatch/ 2>/dev/null \
    | /bin/busybox sed 's|^|      |'
echo "    transition state:"
/bin/busybox cat /sys/kernel/livepatch/livepatch_sample/transition 2>/dev/null \
    | /bin/busybox sed 's|^|      transition=|'
/bin/busybox cat /sys/kernel/livepatch/livepatch_sample/enabled 2>/dev/null \
    | /bin/busybox sed 's|^|      enabled=|'
echo
echo "[3] Patched /proc/cmdline (cmdline_proc_show is now livepatch_cmdline_proc_show):"
echo -n "    "
/bin/busybox cat /proc/cmdline
echo
echo "[4] Disabling the livepatch (echo 0 > .../enabled) ..."
echo 0 > /sys/kernel/livepatch/livepatch_sample/enabled
# The transition file behavior under busybox cat on this kernel is
# flaky (sometimes returns -EIO between sample/disable). Step 5's
# /proc/cmdline read is the ground-truth check that the revert worked,
# so we just sleep a fixed window here rather than poll.
/bin/busybox sleep 3
echo "    -> slept 3s for transition to converge; verifying in [5]"
echo
echo "[5] Reverted /proc/cmdline (should match step 1):"
echo -n "    "
/bin/busybox cat /proc/cmdline
echo
echo "[6] Unloading patch module ..."
/bin/busybox rmmod livepatch_sample
echo "    -> rmmod exit $?"
echo
echo "============================================================="
echo "  Demo complete. Poweroff."
echo "============================================================="
/bin/busybox poweroff -f
INIT
chmod +x "${ROOT}/init"
ln -sf /init "${ROOT}/sbin/init"

cd "${ROOT}"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null \
    | gzip -9 > /work/build/rootfs.cpio.gz
echo "  rootfs.cpio.gz: $(ls -la /work/build/rootfs.cpio.gz | awk '{print $5}') bytes"
INSIDE
chmod +x tmp-driver.sh

# Note: no --platform flag. The image is linux/amd64; on arm64 macOS hosts
# Docker Desktop's Rosetta layer handles emulation. Explicitly passing
# --platform linux/amd64 fails on Docker Desktop with the containerd
# image store because the image is in single-arch format that doesn't
# satisfy the platform selector.
docker run --rm --user root \
    -v "$PWD":/work \
    evasive-linux-kbuild \
    bash /work/tmp-driver.sh

rm -f tmp-driver.sh
echo
echo "Artifacts:"
ls -la build/bzImage build/rootfs.cpio.gz build/livepatch-sample.ko build/busybox
echo
echo "Boot the demo:"
echo "    bash scripts/run-qemu.sh"
