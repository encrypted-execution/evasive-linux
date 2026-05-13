# evasive-linux

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Status: research](https://img.shields.io/badge/Status-research-yellow.svg)](#status)

A Linux distribution whose **running kernel rearranges its own code in
memory on a continuous schedule**. Every few seconds, every few minutes,
or at every syscall return — the layout in `.text` is different. Pointers
captured by an attacker yesterday don't dereference into anything useful
today. Pointers captured a moment ago can be made into honey-traps that
trip an alarm the instant any control flow attempts to use them.

Sibling project to
[encrypted-linux](https://github.com/encrypted-execution/encrypted-linux).
Where encrypted-linux is a **build-time** scrambling Linux (different
calling convention, different syscall numbers, different `/proc` schema,
different errno values — all baked at compile time), evasive-linux adds
the missing axis: **runtime motion**. The same image. Different memory
every cycle.

## Status

**Two demos working end-to-end in QEMU.**

### Demo 01 — single livepatch

Vanilla Linux 6.6.30 + `CONFIG_LIVEPATCH` + the kernel's own
`samples/livepatch/livepatch-sample.ko`. Loads the patch, shows
`/proc/cmdline` change from the real boot cmdline to
`this has been live patched`, disables, observes the revert, `rmmod`s.

```bash
bash scripts/build-livepatch-demo.sh   # ~10 min
bash scripts/run-qemu.sh
```

### Demo 02 — two livepatches at distinct addresses

The foundational property required for continuous code re-randomization:
each consecutive livepatch places its replacement function at a
*different* kernel virtual address. Two out-of-tree modules
(`livepatches/lp1.c`, `livepatches/lp2.c`) each replace
`cmdline_proc_show` and print their own function pointer via `pr_info`.

```bash
bash scripts/build-double-livepatch-demo.sh   # ~10 min
INITRD=build/rootfs-double.cpio.gz bash scripts/run-qemu.sh
```

Captured boot output:

```
[2] insmod lp1.ko ...
    /proc/cmdline now:    evasive-linux lp1 — patch #1
    lp1 placement (from dmesg): ffffffffa0000032

[3] insmod lp2.ko (atomic-replace) ...
    /proc/cmdline now:    evasive-linux lp2 — patch #2
    lp2 placement (from dmesg): ffffffffa0006032
    lp1 sysfs (auto-disabled by atomic-replace): enabled=

[4] Verdict:
    lp1: ffffffffa0000032
    lp2: ffffffffa0006032
    -> DISTINCT addresses. Each livepatch placed its replacement
       function at a different location in the module address space.
```

The repository also holds three research/prior-art dossiers
(`research/00`, `01`, `02`) that establish the project thesis.

## The thesis in one minute

The Linux kernel already has all the plumbing required for in-place,
per-function code replacement: it ships with `CONFIG_LIVEPATCH`,
ftrace-based redirection at every function's `__fentry__` site, an
"atomic replace" mode that supersedes prior patches in a single
transition, and a per-task consistency model that guarantees no thread
is mid-execution in a function being swapped. This infrastructure was
designed to ship CVE fixes without rebooting. It can also be used as a
**moving-target transport** that replaces a function with itself — same
semantics, different machine code, different memory address — on a loop.

While the layout is moving, the dead bodies of the old functions remain
mapped in `.text`. They are unreached by any legitimate caller because
ftrace now routes around them. They are also **the perfect honey
surface.** Fill them with `INT3` and any pre-randomization gadget
pointer that survived in an attacker's working memory becomes a trap.
Fill them with deceptive lookalike gadgets and the attacker's ROP-chain
search tool happily picks up bait that, on use, branches to an attack
logger. The defender gets two compounded effects from one mechanism:
**rerandomization invalidates stale pointers; honey-poisoning catches
their use.**

## What's in the literature

Not this. See [`research/01-continuous-rerandomization-prior-art.md`](research/01-continuous-rerandomization-prior-art.md)
for the full survey. Highlights:

- **Continuous code rerandomization in userspace** is well-explored
  (Shuffler OSDI'16, TASR CCS'15, Readactor S&P'15, CodeArmor EuroS&P'17,
  RuntimeASLR NDSS'16). None of these are for the kernel.
- **Kernel rerandomization** is sparse. Mainline Linux KASLR is base-only
  and fixed at boot. FGKASLR (function-granular, Accardi 2020) reorders
  at boot but has been stuck out-of-tree for six years. Adelie (ASPLOS'22)
  is the only published continuous-KASLR system for Linux — and it
  handles modules only, not the kernel core, and uses bespoke module
  remapping rather than livepatch.
- **Livepatch as MTD vehicle**: no published academic work proposes
  using `CONFIG_LIVEPATCH` as the transport for continuous code movement
  without a CVE attached. The maintainer mailing list
  (`live-patching@vger.kernel.org`) has never discussed it.
- **Post-patch dead code as honey surface**: HoneyGadget (Yang et al. 2019)
  inserts decoys at build time and detects via Intel LBR sampling — not
  the same construction. The position paper *Booby Trapping Software*
  (Crane, Larsen, Brunthaler, Franz, NSPW 2013) is the conceptual
  framework that legitimizes the idea, predating livepatch.

Two angles in this repo's research dossiers appear to be **genuinely
unexplored in print**:

1. Using upstream livepatch as a non-CVE MTD transport.
2. Turning post-relocation dead function bodies into INT3 / UD2 /
   decoy-gadget tripwires.

## Repository layout

```
evasive-linux/
├── LICENSE                          # Apache-2.0
├── README.md                        # this file
└── research/
    ├── 00-linux-livepatch-internals.md
    ├── 01-continuous-rerandomization-prior-art.md
    └── 02-honeytrap-old-code-prior-art.md
```

## Relationship to encrypted-linux

| Axis | encrypted-linux | evasive-linux |
|---|---|---|
| When | Build time | Runtime |
| Granularity | Every contract (syscall, ABI, errno, /proc, EI_OSABI, struct) | Function code layout |
| Cardinality | Per-build (one dialect per image) | Per-N-seconds (many layouts per boot) |
| Defense | Stale tooling can't compile or run | Stale pointers can't dereference |
| Telemetry | None (silent rejection) | Yes (honey-trap on poisoned dead code) |
| Seed source | `./seed` file (HMAC-SHA256 labels) | RDRAND / fresh entropy per cycle, optionally chained to the encrypted-linux master seed |

Both projects share the
[Encrypted Execution](https://www.encrypted-execution.com) thesis:
**diversify every contract that an attacker depends on, at every layer
where you can afford to.** encrypted-linux diversifies in space.
evasive-linux diversifies in time. Stacked, they get you both.

## Open questions

The research dossiers close with concrete unknowns. The five that will
shape the first prototype:

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

See [`research/00-linux-livepatch-internals.md`](research/00-linux-livepatch-internals.md)
for the full list.

## License & patents

Apache-2.0. See [`LICENSE`](LICENSE).

This project is downstream of the
[Encrypted Execution paper](https://www.encrypted-execution.com)
(Gore 2025) and inherits the public-domain pledge of
USPTO 10,733,303 made by the author.
