# Top-level convenience Makefile for evasive-linux.
#
# Wraps the build/run scripts so anyone landing on the repo can just
# type `make demo-03` and watch the full thesis run end-to-end.

.DEFAULT_GOAL := help

.PHONY: help demo-01 demo-02 demo-03 \
        build-01 build-02 build-03 \
        boot-01 boot-02 boot-03 \
        clean distclean

help:
	@echo "evasive-linux — make targets"
	@echo ""
	@echo "  Build + boot (recommended):"
	@echo "    make demo-01      Single livepatch end-to-end"
	@echo "    make demo-02      Two livepatches, distinct addresses"
	@echo "    make demo-03      Continuous rerand + honey-traps (full thesis)"
	@echo ""
	@echo "  Build only:"
	@echo "    make build-01     Build kernel + sample livepatch + initramfs"
	@echo "    make build-02     Build kernel + lp1/lp2 + initramfs"
	@echo "    make build-03     Build kernel + lp_01..lp_05 + attacker + initramfs"
	@echo ""
	@echo "  Boot a previously-built demo:"
	@echo "    make boot-01      Boot demo 01 in QEMU"
	@echo "    make boot-02      Boot demo 02 in QEMU"
	@echo "    make boot-03      Boot demo 03 in QEMU"
	@echo ""
	@echo "  Housekeeping:"
	@echo "    make clean        Remove build/ outputs and log files"
	@echo "    make distclean    clean + remove evasive-linux-kbuild docker image"

demo-01: build-01 boot-01
demo-02: build-02 boot-02
demo-03: build-03 boot-03

build-01:
	bash scripts/build-livepatch-demo.sh

build-02:
	bash scripts/build-double-livepatch-demo.sh

build-03:
	bash scripts/build-continuous-demo.sh

boot-01:
	bash scripts/run-qemu.sh

boot-02:
	INITRD=build/rootfs-double.cpio.gz bash scripts/run-qemu.sh

boot-03:
	TIMEOUT=180 INITRD=build/rootfs-continuous.cpio.gz bash scripts/run-qemu.sh

clean:
	rm -rf build/ tmp-*.sh *.log livepatches/lp_0?.c
	rm -f livepatches/*.o livepatches/*.ko livepatches/.*.cmd
	rm -f livepatches/*.mod livepatches/*.mod.c
	rm -f livepatches/Module.symvers livepatches/modules.order
	rm -rf livepatches/.tmp_versions/

distclean: clean
	-docker image rm evasive-linux-kbuild 2>/dev/null
