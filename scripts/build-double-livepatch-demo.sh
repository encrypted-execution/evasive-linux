#!/usr/bin/env bash
#
# scripts/build-double-livepatch-demo.sh — Demo 02.
#
# Build a vanilla Linux 6.6.30 kernel with CONFIG_LIVEPATCH, build two
# out-of-tree livepatch modules (livepatches/lp1.ko, livepatches/lp2.ko)
# that each replace cmdline_proc_show with a distinct copy, and
# assemble an initramfs whose init script loads both modules in
# sequence and proves that lp1's and lp2's replacement functions land
# at *different* kernel virtual addresses.
#
# Output:
#   build/bzImage
#   build/lp1.ko, build/lp2.ko
#   build/rootfs-double.cpio.gz
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

echo "=== Step 1: build kbuild container (if missing) ==="
if ! docker image inspect evasive-linux-kbuild >/dev/null 2>&1; then
    docker buildx build --load \
        -t evasive-linux-kbuild \
        -f docker/Dockerfile.kbuild .
else
    echo "  evasive-linux-kbuild image present"
fi

mkdir -p build

cat > tmp-driver-double.sh <<'INSIDE'
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
grep -E "^CONFIG_(LIVEPATCH|DYNAMIC_FTRACE|UNWINDER_ORC)" .config

echo "=== Building bzImage ==="
make -j"$(nproc)" bzImage 2>&1 | tail -3
# `make modules` (not modules_prepare) populates Module.symvers with
# every EXPORT_SYMBOL entry, which the out-of-tree build below needs
# in order to resolve seq_printf and friends.
make -j"$(nproc)" modules 2>&1 | tail -3

cp arch/x86/boot/bzImage /work/build/bzImage
echo "  bzImage: $(ls -la /work/build/bzImage | awk '{print $5}') bytes"

echo "================================================="
echo "=== Build out-of-tree livepatch modules ==="
echo "================================================="
# /work/livepatches/{lp1.c,lp2.c,Makefile}.
make -C /opt/linux M=/work/livepatches modules 2>&1 | tail -5
ls -la /work/livepatches/lp1.ko /work/livepatches/lp2.ko
cp /work/livepatches/lp1.ko /work/build/lp1.ko
cp /work/livepatches/lp2.ko /work/build/lp2.ko
# Clean intermediate kbuild output from the bind mount so the next
# build (host side) doesn't see root-owned debris.
make -C /opt/linux M=/work/livepatches clean >/dev/null 2>&1 || true

echo "================================================="
echo "=== Build busybox (static) ==="
echo "================================================="
cd /opt/busybox
make distclean >/dev/null 2>&1 || true
make defconfig >/dev/null
sed -i 's|^# CONFIG_STATIC.*|CONFIG_STATIC=y|' .config
for cfg in CONFIG_FEATURE_WTMP CONFIG_FEATURE_UTMP CONFIG_TC; do
    sed -i "s|^${cfg}=y|# ${cfg} is not set|" .config
done
make -j"$(nproc)" >/dev/null 2>&1
cp busybox /work/build/busybox
echo "  busybox: $(ls -la /work/build/busybox | awk '{print $5}') bytes"

echo "================================================="
echo "=== Assemble initramfs with double-patch demo init ==="
echo "================================================="
ROOT=/tmp/rootfs-double
rm -rf "${ROOT}"
mkdir -p "${ROOT}"/{bin,sbin,etc,proc,sys,dev,tmp,root,lib/modules}
cp /work/build/busybox "${ROOT}/bin/busybox"
for a in ash sh ls cat mount echo poweroff init insmod rmmod sleep ln dmesg grep awk head tail printf; do
    ln -sf busybox "${ROOT}/bin/${a}"
done
cp /work/build/lp1.ko "${ROOT}/lib/modules/lp1.ko"
cp /work/build/lp2.ko "${ROOT}/lib/modules/lp2.ko"

cat > "${ROOT}/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox mount -t devtmpfs none /dev 2>/dev/null

echo
echo "============================================================="
echo "  evasive-linux demo 02 — two livepatches, distinct addresses"
echo "============================================================="
echo

echo "[1] Baseline /proc/cmdline:"
echo -n "    "
/bin/busybox cat /proc/cmdline
echo

echo "[2] insmod lp1.ko ..."
/bin/busybox insmod /lib/modules/lp1.ko
/bin/busybox sleep 1
echo "    /proc/cmdline now:"
echo -n "      "
/bin/busybox cat /proc/cmdline
LP1_ADDR=$(/bin/busybox dmesg | /bin/busybox grep -E 'evasive-linux lp1: new_func at' \
           | /bin/busybox tail -1 | /bin/busybox awk '{print $NF}')
echo "    lp1 placement (from dmesg): ${LP1_ADDR}"
echo "    lp1 sysfs:"
echo "      enabled=$(/bin/busybox cat /sys/kernel/livepatch/lp1/enabled 2>/dev/null)"
echo

echo "[3] insmod lp2.ko (atomic-replace) ..."
/bin/busybox insmod /lib/modules/lp2.ko
/bin/busybox sleep 1
echo "    /proc/cmdline now:"
echo -n "      "
/bin/busybox cat /proc/cmdline
LP2_ADDR=$(/bin/busybox dmesg | /bin/busybox grep -E 'evasive-linux lp2: new_func at' \
           | /bin/busybox tail -1 | /bin/busybox awk '{print $NF}')
echo "    lp2 placement (from dmesg): ${LP2_ADDR}"
echo "    lp1 sysfs (auto-disabled by atomic-replace):"
echo "      enabled=$(/bin/busybox cat /sys/kernel/livepatch/lp1/enabled 2>/dev/null)"
echo "    lp2 sysfs:"
echo "      enabled=$(/bin/busybox cat /sys/kernel/livepatch/lp2/enabled 2>/dev/null)"
echo

echo "[4] Verdict:"
echo "    lp1: ${LP1_ADDR}"
echo "    lp2: ${LP2_ADDR}"
if [ -n "${LP1_ADDR}" ] && [ -n "${LP2_ADDR}" ] && [ "${LP1_ADDR}" != "${LP2_ADDR}" ]; then
    echo "    -> DISTINCT addresses. Each livepatch placed its replacement"
    echo "       function at a different location in the module address"
    echo "       space. Foundation for continuous code re-randomization."
else
    echo "    -> WARN: addresses were equal or empty. Verify no_hash_pointers"
    echo "       is on the kernel cmdline (and that pr_info output reached dmesg)."
fi
echo

echo "[5] Cleanup: rmmod lp1 (already disabled by atomic-replace) ..."
/bin/busybox rmmod lp1 2>&1
echo "[5a] Disable lp2 ..."
echo 0 > /sys/kernel/livepatch/lp2/enabled
/bin/busybox sleep 3
echo "[5b] rmmod lp2 ..."
/bin/busybox rmmod lp2 2>&1
echo
echo "============================================================="
echo "  Demo complete. Triggering emergency reboot (sysrq b) — QEMU"
echo "  -no-reboot will intercept and exit cleanly."
echo "============================================================="
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo b > /proc/sysrq-trigger
/bin/busybox poweroff -f
INIT
chmod +x "${ROOT}/init"
ln -sf /init "${ROOT}/sbin/init"

cd "${ROOT}"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null \
    | gzip -9 > /work/build/rootfs-double.cpio.gz
echo "  rootfs-double.cpio.gz: $(ls -la /work/build/rootfs-double.cpio.gz | awk '{print $5}') bytes"
INSIDE
chmod +x tmp-driver-double.sh

docker run --rm --user root \
    -v "$PWD":/work \
    evasive-linux-kbuild \
    bash /work/tmp-driver-double.sh

rm -f tmp-driver-double.sh
echo
echo "Artifacts:"
ls -la build/bzImage build/lp1.ko build/lp2.ko build/rootfs-double.cpio.gz
echo
echo "Boot the demo:"
echo "    INITRD=build/rootfs-double.cpio.gz bash scripts/run-qemu.sh"
