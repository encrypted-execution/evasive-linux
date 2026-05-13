#!/usr/bin/env bash
#
# scripts/build-continuous-demo.sh — Demo 03 + 03b.
#
# A kernel built with every randomization knob we can flip (KASLR,
# RANDSTRUCT_FULL, VMAP_STACK, RANDOMIZE_KSTACK_OFFSET, slab freelist
# randomization), plus a stream of 5 livepatch generations that
# atomic-replace each other on a userspace cadence — and each
# generation arms a kprobe-based honey-trap at the previous generation's
# now-superseded function address. Finally an "attacker" module
# deliberately dispatches a call to the very first generation's old
# address, tripping the honey-trap and proving the loop.
#
# Output:
#   build/bzImage                    (kernel)
#   build/lp_{01..05}.ko             (livepatch generations)
#   build/attacker.ko                (stale-pointer attacker)
#   build/rootfs-continuous.cpio.gz  (initramfs)
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# If the docker image predates the gcc-13-plugin-dev addition, force a
# rebuild. Detect by checking whether the image has the plugin headers.
NEED_REBUILD=0
if docker image inspect evasive-linux-kbuild >/dev/null 2>&1; then
    if ! docker run --rm --user root evasive-linux-kbuild \
            bash -c '[ -d /usr/lib/gcc/x86_64-linux-gnu/13/plugin ]' \
            >/dev/null 2>&1; then
        echo "  evasive-linux-kbuild image lacks gcc-13-plugin-dev; rebuilding"
        NEED_REBUILD=1
    fi
fi
if [ "${NEED_REBUILD}" = "1" ] || \
   ! docker image inspect evasive-linux-kbuild >/dev/null 2>&1; then
    docker buildx build --load \
        -t evasive-linux-kbuild \
        -f docker/Dockerfile.kbuild .
else
    echo "  evasive-linux-kbuild image present (with plugin support)"
fi

mkdir -p build

cat > tmp-driver-continuous.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail
cd /work

echo "================================================="
echo "=== Build kernel: livepatch + every randomization ==="
echo "================================================="
cd /opt/linux
make mrproper >/dev/null 2>&1 || true
make tinyconfig >/dev/null
cat /work/kernel/livepatch.config  >> .config
cat /work/kernel/randomize.config  >> .config

# Materialize a per-build randstruct seed (64 hex chars) so RANDSTRUCT_FULL
# has something deterministic to key its struct shuffles on.
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' \
    > scripts/gcc-plugins/randstruct.seed
echo "  randstruct seed: $(head -c 16 scripts/gcc-plugins/randstruct.seed)..."

make olddefconfig >/dev/null
# RANDSTRUCT_NONE is auto-selected from a choice group; clobber it.
if ! grep -q "^CONFIG_RANDSTRUCT_FULL=y" .config; then
    scripts/config --disable RANDSTRUCT_NONE
    scripts/config --enable  RANDSTRUCT_FULL
    # `yes "" | make oldconfig` SIGPIPEs `yes` when make finishes; under
    # pipefail that propagates exit 141. Suppress, then re-run
    # olddefconfig as a clean re-resolution.
    (yes "" | make oldconfig >/dev/null 2>&1) || true
    make olddefconfig >/dev/null 2>&1 || true
fi

echo "Effective randomization config:"
grep -E "^CONFIG_(LIVEPATCH|RANDOMIZE_BASE|RANDOMIZE_MEMORY|VMAP_STACK|RANDOMIZE_KSTACK|RANDSTRUCT|SLAB_FREELIST|SHUFFLE_PAGE)" .config

echo "=== Building bzImage + modules ==="
make -j"$(nproc)" bzImage  2>&1 | tail -3
make -j"$(nproc)" modules  2>&1 | tail -3
cp arch/x86/boot/bzImage /work/build/bzImage
echo "  bzImage: $(ls -la /work/build/bzImage | awk '{print $5}') bytes"

echo "================================================="
echo "=== Generate lp_01.c .. lp_05.c from template ==="
echo "================================================="
cd /work/livepatches
for nn in 01 02 03 04 05; do
    sed -e "s/@NN@/${nn}/g" -e "s/@MSG@/generation ${nn}/g" \
        lp_template.c > lp_${nn}.c
done
ls lp_*.c

echo "================================================="
echo "=== Build out-of-tree livepatch modules ==="
echo "================================================="
make -C /opt/linux M=/work/livepatches modules 2>&1 | tail -10
ls -la lp_01.ko lp_02.ko lp_03.ko lp_04.ko lp_05.ko attacker.ko
cp lp_01.ko lp_02.ko lp_03.ko lp_04.ko lp_05.ko attacker.ko /work/build/
# Clean intermediate kbuild output so future host-side runs don't
# trip over root-owned files in the bind mount.
make -C /opt/linux M=/work/livepatches clean >/dev/null 2>&1 || true
# Also remove the generated .c files so they're not committed.
rm -f /work/livepatches/lp_0?.c

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
echo "=== Assemble initramfs ==="
echo "================================================="
ROOT=/tmp/rootfs-continuous
rm -rf "${ROOT}"
mkdir -p "${ROOT}"/{bin,sbin,etc,proc,sys,dev,tmp,root,lib/modules}
cp /work/build/busybox "${ROOT}/bin/busybox"
for a in ash sh ls cat mount echo poweroff init insmod rmmod sleep ln dmesg grep awk head tail printf cut sort; do
    ln -sf busybox "${ROOT}/bin/${a}"
done
cp /work/build/lp_01.ko /work/build/lp_02.ko /work/build/lp_03.ko \
   /work/build/lp_04.ko /work/build/lp_05.ko /work/build/attacker.ko \
   "${ROOT}/lib/modules/"

cat > "${ROOT}/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox mount -t devtmpfs none /dev 2>/dev/null

echo
echo "==============================================================="
echo "  evasive-linux demo 03 + 03b"
echo "  Continuous in-kernel rerandomization + honey-traps"
echo "==============================================================="
echo

# Confirm the boot was randomized — KASLR base + module-region randomization.
echo "[ENV] Kernel layout entropy:"
KBASE=$(/bin/busybox dmesg | /bin/busybox grep -i "Kernel Offset\|KASLR\|randomize" \
        | /bin/busybox head -3)
if [ -n "${KBASE}" ]; then
    echo "${KBASE}" | /bin/busybox sed 's|^|      |'
else
    echo "      (KASLR/randomization log lines below console loglevel; dmesg has them)"
fi
echo "      Randstruct + KASLR + KSTACK_OFFSET + slab-shuffle active per build config."
echo

echo "==============================================================="
echo "  Stream 5 livepatch generations, each honey-trapping the last"
echo "==============================================================="
PREV=0
FIRST_ADDR=""
for nn in 01 02 03 04 05; do
    echo
    if [ "${PREV}" = "0" ]; then
        PARAM_ARG=""
        echo "[Gen ${nn}] insmod lp_${nn}.ko (no honey-trap on first generation) ..."
    else
        # Kernel ulong module-param parser wants 0x-prefixed hex.
        PARAM_ARG="poison_addr=0x${PREV}"
        echo "[Gen ${nn}] insmod lp_${nn}.ko ${PARAM_ARG} ..."
    fi
    /bin/busybox insmod /lib/modules/lp_${nn}.ko ${PARAM_ARG}
    /bin/busybox sleep 1
    echo "         /proc/cmdline:"
    echo -n "           "
    /bin/busybox cat /proc/cmdline
    CUR=$(/bin/busybox dmesg | /bin/busybox grep "evasive-linux lp_${nn}: new_func" \
          | /bin/busybox tail -1 | /bin/busybox awk '{print $NF}')
    echo "         placement: ${CUR}"
    if [ "${PREV}" != "0" ]; then
        TRAP=$(/bin/busybox dmesg \
               | /bin/busybox grep "evasive-linux lp_${nn}: HONEY-TRAP armed" \
               | /bin/busybox tail -1)
        echo "         trap:      ${TRAP##*: }"
    fi
    if [ -z "${FIRST_ADDR}" ]; then FIRST_ADDR=${CUR}; fi
    PREV=${CUR}
done

echo
echo "==============================================================="
echo "  Stream summary"
echo "==============================================================="
echo "All 5 placements:"
/bin/busybox dmesg | /bin/busybox grep "evasive-linux lp_.*: new_func" \
    | /bin/busybox sed 's|^|  |'
echo
echo "Armed honey-traps (one per generation transition):"
/bin/busybox dmesg | /bin/busybox grep "HONEY-TRAP armed" \
    | /bin/busybox sed 's|^|  |'

echo
echo "==============================================================="
echo "  Demo 03b — fire the honey-trap"
echo "==============================================================="
echo "Loading attacker.ko addr=0x${FIRST_ADDR}"
echo "(invokes lp_01's superseded function; lp_02 armed a kprobe there)"
/bin/busybox insmod /lib/modules/attacker.ko addr=0x${FIRST_ADDR} 2>&1
/bin/busybox sleep 2
echo
echo "Honey-trap log entries:"
/bin/busybox dmesg | /bin/busybox grep -E "HONEY-TRAP: superseded|attacker:" \
    | /bin/busybox sed 's|^|  |'

echo
echo "==============================================================="
echo "  Cleanup"
echo "==============================================================="
echo 0 > /sys/kernel/livepatch/lp_05/enabled
/bin/busybox sleep 3
for nn in 05 04 03 02 01; do
    /bin/busybox rmmod lp_${nn} 2>&1 \
        | /bin/busybox sed "s|^|  rmmod lp_${nn}: |"
done
# attacker module can stay loaded — its kthread is long done; rmmod
# cleans up.
/bin/busybox rmmod attacker 2>&1 | /bin/busybox sed 's|^|  rmmod attacker: |'

echo
echo "==============================================================="
echo "  Demo complete. Triggering emergency reboot (sysrq b) — QEMU"
echo "  -no-reboot will intercept and exit cleanly."
echo "==============================================================="
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo b > /proc/sysrq-trigger
/bin/busybox poweroff -f
INIT
chmod +x "${ROOT}/init"
ln -sf /init "${ROOT}/sbin/init"

cd "${ROOT}"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null \
    | gzip -9 > /work/build/rootfs-continuous.cpio.gz
echo "  rootfs-continuous.cpio.gz: $(ls -la /work/build/rootfs-continuous.cpio.gz | awk '{print $5}') bytes"
INSIDE
chmod +x tmp-driver-continuous.sh

docker run --rm --user root \
    -v "$PWD":/work \
    evasive-linux-kbuild \
    bash /work/tmp-driver-continuous.sh

rm -f tmp-driver-continuous.sh
echo
echo "Artifacts:"
ls -la build/bzImage build/lp_*.ko build/attacker.ko \
       build/rootfs-continuous.cpio.gz
echo
echo "Boot the demo:"
echo "    INITRD=build/rootfs-continuous.cpio.gz bash scripts/run-qemu.sh"
