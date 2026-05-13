# evasive-linux

[![CI](https://github.com/encrypted-execution/evasive-linux/actions/workflows/ci.yml/badge.svg)](https://github.com/encrypted-execution/evasive-linux/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A Linux distribution whose **running kernel rearranges its own code in
memory on a continuous schedule**. Every cycle, the layout in `.text`
is different. Pointers an attacker captured a moment ago can be made
into honey-traps that log the instant any control flow attempts to use
them.

Sibling project to
[encrypted-linux](https://github.com/encrypted-execution/encrypted-linux).
Where encrypted-linux is a *build-time* scrambling Linux,
evasive-linux adds the missing axis: **runtime motion**. The same
image. A different `.text` every cycle.

---

## TL;DR — see it work in one command

```bash
git clone https://github.com/encrypted-execution/evasive-linux
cd evasive-linux
make demo-03            # build kernel + 5 patches + attacker, boot in QEMU
```

If you see the line `evasive-linux HONEY-TRAP: superseded patch 02 hit
at …` in the QEMU output, the thesis just ran end-to-end on your
machine.

The first build is ~15 minutes and ~5 GB of intermediate state. Once
the Docker image is cached, subsequent runs are faster.

---

## What this repository does

| Demo | What it proves | One-liner | ~Time |
|---|---|---|---|
| [01](#demo-01--single-livepatch) | A vanilla, self-compiled Linux kernel can be live-patched once and the patch can be cleanly reverted. | `make demo-01` | ~10 min |
| [02](#demo-02--two-livepatches-at-distinct-addresses) | Two consecutive livepatches place their replacement functions at *different* kernel addresses — the precondition for continuous rerandomization. | `make demo-02` | ~10 min |
| [03 + 03b](#demo-03--03b--continuous-rerandomization--honey-traps) | A kernel built with every randomization knob enabled streams five livepatch generations atomic-replacing each other, each one arming a `kprobe`-based honey-trap at its predecessor's now-superseded address. An attacker module deliberately invokes the first generation's stale pointer; the trap fires and the kernel logs the intrusion with caller info. | `make demo-03` | ~15 min |

---

## Prerequisites

- **Docker** with buildx (`docker buildx version` should print something).
  Docker Desktop on macOS works; on Linux you want a recent `docker-ce`
  or `podman` with a docker-cli shim.
- **QEMU** for x86_64 (`qemu-system-x86_64`). On Ubuntu/Debian:
  `sudo apt-get install qemu-system-x86`. On macOS: `brew install qemu
  coreutils` (coreutils gives you `gtimeout`).
- **~5 GB of free disk** for the build container's intermediate state.
- **~15 minutes** for the first cold build. Subsequent runs reuse the
  cached Docker image and are faster.

The demos run on Linux/amd64 native (CI), Linux/arm64 (Rosetta or
QEMU-user-mode), and macOS arm64 (Docker Desktop's Rosetta layer).

---

## Demo 01 — single livepatch

Vanilla Linux 6.6.30 + `CONFIG_LIVEPATCH` + the kernel's own
`samples/livepatch/livepatch-sample.ko`. The initramfs's `/init` loads
the patch, shows `/proc/cmdline` change from the real boot cmdline to
`this has been live patched`, disables, observes the revert, and
`rmmod`s.

```bash
make demo-01

# or, explicitly:
bash scripts/build-livepatch-demo.sh
bash scripts/run-qemu.sh
```

Expected output (abridged):

```
[1] Baseline /proc/cmdline:    console=ttyS0 panic=5 loglevel=7 no_hash_pointers
[2] Loading livepatch-sample.ko ...
    -> insmod exit 0
    livepatch sysfs:  livepatch_sample
    transition=0      enabled=1
[3] Patched /proc/cmdline:     this has been live patched
[4] Disabling the livepatch ...
[5] Reverted /proc/cmdline:    console=ttyS0 panic=5 loglevel=7 no_hash_pointers
[6] Unloading patch module ...
    -> rmmod exit 0
```

## Demo 02 — two livepatches at distinct addresses

The foundational property continuous rerandomization requires: each
consecutive livepatch places its replacement function at a *different*
kernel virtual address. Two out-of-tree modules
(`livepatches/lp1.c`, `livepatches/lp2.c`) each replace
`cmdline_proc_show` and print their own function pointer via
`pr_info`. lp2 loads with `.replace = true` (atomic-replace) so it
supersedes lp1 in a single transition.

```bash
make demo-02
```

Expected output (abridged):

```
[2] insmod lp1.ko ...
    /proc/cmdline now:    evasive-linux lp1 — patch #1
    lp1 placement (from dmesg): ffffffffa0000032

[3] insmod lp2.ko (atomic-replace) ...
    /proc/cmdline now:    evasive-linux lp2 — patch #2
    lp2 placement (from dmesg): ffffffffa0006032

[4] Verdict:
    lp1: ffffffffa0000032
    lp2: ffffffffa0006032
    -> DISTINCT addresses.
```

## Demo 03 + 03b — continuous rerandomization + honey-traps

The full thesis. A kernel built with **every randomization knob
enabled**:

- `RANDOMIZE_BASE` — kernel base KASLR
- `RANDOMIZE_MEMORY` — direct-map / vmalloc / vmemmap base randomization
- `VMAP_STACK` — virtually mapped kernel stacks
- `RANDOMIZE_KSTACK_OFFSET` — per-syscall kernel-stack offset
- `STACKPROTECTOR_STRONG` — stack canaries
- `SLAB_FREELIST_RANDOM`, `SHUFFLE_PAGE_ALLOCATOR` — allocator entropy
- `RANDSTRUCT_FULL` — full GCC-plugin struct-layout randomization

On top of it, five livepatch generations (`lp_01.ko` … `lp_05.ko`)
generated from a template (`livepatches/lp_template.c`) atomic-replace
each other in sequence. Each new generation arms a **kprobe-based
honey-trap** at the previous generation's now-superseded function
address. A final `attacker.ko` (kthread-isolated) deliberately invokes
the very first generation's stale pointer — the trap fires, the
intrusion is logged, with the caller identified.

```bash
make demo-03
```

Expected output (abridged):

```
kprobes: kprobe jump-optimization is enabled. All kprobes are optimized if possible.

[Gen 01] insmod lp_01.ko (no honey-trap on first generation)
         placement: ffffffffa0000023

[Gen 02] insmod lp_02.ko poison_addr=0xffffffffa0000023
         placement: ffffffffa0007023
         trap:      HONEY-TRAP armed at ffffffffa0000023

[Gen 03] insmod lp_03.ko poison_addr=0xffffffffa0007023
         placement: ffffffffa0010023
         trap:      HONEY-TRAP armed at ffffffffa0007023

[Gen 04] insmod lp_04.ko poison_addr=0xffffffffa0010023
         placement: ffffffffa0019023
         trap:      HONEY-TRAP armed at ffffffffa0010023

[Gen 05] insmod lp_05.ko poison_addr=0xffffffffa0019023
         placement: ffffffffa0020023
         trap:      HONEY-TRAP armed at ffffffffa0019023

Loading attacker.ko addr=0xffffffffa0000023
  attacker: dispatching call to ffffffffa0000023 ...
  evasive-linux HONEY-TRAP: superseded patch 02 hit at ffffffffa0000027 (caller=evasive_lp_01_cmdline_show+0x5/0x18 [lp_01])
```

That last line is the thesis running end-to-end: code that the
attacker remembered from a previous generation is no longer where the
kernel routes anyone legitimate. When the attacker reaches for that
stale address, the kernel logs the event with the caller identified.
**Every cycle leaves a tripwire.**

---

## The thesis in one minute

The Linux kernel already has all the plumbing required for in-place,
per-function code replacement: it ships with `CONFIG_LIVEPATCH`,
ftrace-based redirection at every function's `__fentry__` site, an
"atomic replace" mode that supersedes prior patches in a single
transition, and a per-task consistency model that guarantees no
thread is mid-execution in a function being swapped. This
infrastructure was designed to ship CVE fixes without rebooting. It
can also be used as a **moving-target transport** that replaces a
function with itself — same semantics, different machine code,
different memory address — on a loop.

While the layout is moving, the dead bodies of the old functions
remain mapped in `.text`. They are unreached by any legitimate caller
because ftrace now routes around them. They are also **the perfect
honey surface.** Fill them with `INT3` and any pre-randomization
gadget pointer that survived in an attacker's working memory becomes
a trap. The defender gets two compounded effects from one mechanism:
**rerandomization invalidates stale pointers; honey-poisoning catches
their use.**

---

## What's in the literature

Not this. See [`research/01-continuous-rerandomization-prior-art.md`](research/01-continuous-rerandomization-prior-art.md)
for the full survey. Highlights:

- **Continuous code rerandomization in userspace** is well-explored
  (Shuffler OSDI'16, TASR CCS'15, Readactor S&P'15, CodeArmor
  EuroS&P'17, RuntimeASLR NDSS'16). None of these are for the kernel.
- **Kernel rerandomization** is sparse. Mainline Linux KASLR is
  base-only and fixed at boot. FGKASLR (function-granular, Accardi
  2020) reorders at boot but has been stuck out-of-tree for six
  years. Adelie (ASPLOS'22) is the only published continuous-KASLR
  system for Linux — and it handles modules only, not the kernel
  core, and uses bespoke module remapping rather than livepatch.
- **Livepatch as MTD vehicle**: no published academic work proposes
  using `CONFIG_LIVEPATCH` as the transport for continuous code
  movement without a CVE attached. The maintainer mailing list
  (`live-patching@vger.kernel.org`) has never discussed it.
- **Post-patch dead code as honey surface**: HoneyGadget (Yang et al.
  2019) inserts decoys at build time and detects via Intel LBR
  sampling — not the same construction. The position paper *Booby
  Trapping Software* (Crane, Larsen, Brunthaler, Franz, NSPW 2013) is
  the conceptual framework that legitimizes the idea, predating
  livepatch.

Two angles appear to be **genuinely unexplored in print**:

1. Using upstream livepatch as a non-CVE MTD transport.
2. Turning post-relocation dead function bodies into INT3 / UD2 /
   decoy-gadget tripwires.

Three dossiers under [`research/`](research/) develop these threads:

- [`00-linux-livepatch-internals.md`](research/00-linux-livepatch-internals.md) — how livepatch works, how to enable it on a vanilla kernel, hard parts, open questions.
- [`01-continuous-rerandomization-prior-art.md`](research/01-continuous-rerandomization-prior-art.md) — academic survey.
- [`02-honeytrap-old-code-prior-art.md`](research/02-honeytrap-old-code-prior-art.md) — the deception-defense angle.

---

## Repository layout

```
evasive-linux/
├── README.md                        # this file
├── LICENSE                          # Apache-2.0
├── CONTRIBUTING.md                  # how to add a demo / file a PR
├── SECURITY.md                      # how to report findings
├── Makefile                         # make demo-01 / 02 / 03 / clean / distclean
├── .github/workflows/ci.yml         # builds + boots all three demos in QEMU
├── docker/
│   └── Dockerfile.kbuild            # ubuntu:24.04 + kernel/busybox sources + gcc-13-plugin-dev
├── kernel/
│   ├── livepatch.config             # CONFIG_LIVEPATCH, KPROBES, ftrace, ORC unwinder
│   └── randomize.config             # KASLR + RANDSTRUCT_FULL + every other knob
├── livepatches/
│   ├── Makefile                     # obj-m += lp1 lp2 lp_01..05 attacker
│   ├── lp1.c, lp2.c                 # demo 02 — two named replacements
│   ├── lp_template.c                # demo 03 — @NN@/@MSG@-templated source
│   └── attacker.c                   # demo 03b — kthread-isolated stale-pointer dispatcher
├── scripts/
│   ├── build-livepatch-demo.sh      # demo 01 orchestrator
│   ├── build-double-livepatch-demo.sh   # demo 02
│   ├── build-continuous-demo.sh     # demo 03 (kernel + 5 patches + attacker)
│   └── run-qemu.sh                  # boot helper; env: KERNEL, INITRD, APPEND, TIMEOUT, MEM
└── research/
    ├── 00-linux-livepatch-internals.md
    ├── 01-continuous-rerandomization-prior-art.md
    └── 02-honeytrap-old-code-prior-art.md
```

---

## Relationship to encrypted-linux

| Axis | encrypted-linux | evasive-linux |
|---|---|---|
| When | Build time | Runtime |
| Granularity | Every contract (syscall, ABI, errno, /proc, EI_OSABI, struct) | Function code layout |
| Cardinality | Per-build (one dialect per image) | Per-cycle (many layouts per boot) |
| Defense | Stale tooling can't compile or run | Stale pointers can't dereference |
| Telemetry | None (silent rejection) | Yes (honey-trap on poisoned dead code) |
| Seed source | `./seed` file (HMAC-SHA256 labels) | Kernel PRNG per cycle, optionally chained to the encrypted-linux master seed |

Both projects share the
[Encrypted Execution](https://www.encrypted-execution.com) thesis:
**diversify every contract that an attacker depends on, at every
layer where you can afford to.** encrypted-linux diversifies in
space. evasive-linux diversifies in time. Stacked, they get you both.

---

## Open questions

The research dossiers close with concrete unknowns. The five that
will shape the next prototype:

1. **Achievable cadence.** What's the floor on `klp_enable_patch →
   klp_complete_transition` round-trip on a quiescent x86_64 system?
   Hypothesis: 1–10 s due to consistency-model convergence.
2. **Coverage.** What fraction of `vmlinux` functions are
   re-randomizable after subtracting tail-called, inlined-everywhere,
   perpetually-sleeping-on-stack, and kprobe/eBPF-attached ones?
3. **Scale.** Livepatch was designed for `N ≈ 10` CVE fixes per
   transition; this project wants `N ≈ thousands`. Does atomic-replace
   scale linearly or quadratically?
4. **Honey-trap mechanics.** Can `text_poke_bp` carpet-bomb a full
   function body with `0xCC`, or only single instructions? What's the
   cost of the alternative (CR0.WP toggle, private mm + CR3 switch)?
5. **Information-leak hardening.** Without `lockdown=confidentiality`,
   `/proc/kallsyms`, `/proc/kcore`, perf, and ftrace expose the new
   layout immediately. What's the minimum hardening posture for the
   defense to retain any value?

See [`research/00-linux-livepatch-internals.md`](research/00-linux-livepatch-internals.md) §
"Closing: open questions for evasive-linux" for the full list.

---

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). The short version: typo
fixes, new demos, and prior-art additions are all welcome.

## Reporting issues, vulnerabilities, or bypasses

See [`SECURITY.md`](SECURITY.md).

## License & patents

Apache-2.0. See [`LICENSE`](LICENSE).

This project is downstream of the
[Encrypted Execution paper](https://www.encrypted-execution.com)
(Gore 2025) and inherits the public-domain pledge of
USPTO 10,733,303 made by the author.
