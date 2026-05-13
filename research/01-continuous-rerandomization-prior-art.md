# Continuous Code Rerandomization: Prior Art Survey

*Research dossier — compiled 2026-05-12*

Background scan for an `evasive-linux` style Linux distribution that extends the build-time scrambling done by `encrypted-linux` with a runtime (per-execution / per-N-minutes) axis using the Linux livepatch subsystem as the transport. This document catalogs what is published, what is deployed, and what is unexplored.

The headline finding: **using livepatch as a non-CVE MTD transport** and **turning post-relocation old address ranges into honey-gadget traps** are both genuinely unexplored surfaces in the academic literature. Adelie (ASPLOS '22) is the closest competitor but only covers modules, not the monolithic kernel core.

---

## 1. The Academic Line on Continuous / Periodic Rerandomization

### 1.1 Userspace (the canonical lineage)

| System | Venue | Granularity | Trigger | Overhead | Status |
|---|---|---|---|---|---|
| Stabilizer [Curtsinger & Berger, ASPLOS'13] | ASPLOS 2013 | function, stack frame, heap | timer (re-rand of code, stack, heap) | < 7% median | research benchmark, **not** a defense |
| Marlin [Gupta et al., NSS'13 / TDSC'15] | NSS 2013 | function shuffle in ELF | per-load | moderate | one-shot, not continuous |
| Oxymoron [Backes & Nürnberger, USENIX Sec'14] | USENIX Sec 2014 | instruction-level w/ shared-library code sharing preserved | load time | low | broken by JIT-ROP variants |
| Isomeron [Davi et al., NDSS'15] | NDSS 2015 | dual-replica, per-call-site coin flip | every indirect call | ~19% | prototype |
| Readactor [Crane et al., S&P'15] | IEEE S&P 2015 | function, XOM-backed code-pointer hiding | load-time + trampolines | ~6% SPEC | prototype, hardware-assisted (EPT execute-only) |
| TASR [Bigelow et al., CCS'15] | CCS 2015 | function-level remap | every I/O syscall pair (output-then-input boundary) | ~2.1% | MIT Lincoln Lab, FLC tech-transfer award 2024 |
| Heisenbyte [Tang et al., CCS'15] | CCS 2015 | destructive code reads | per disclosure | moderate | broken by zombie gadgets |
| Remix [Chen, Wang, Whalley, Lu — CODASPY'16] | CODASPY 2016 | basic-block shuffle within function | on demand | low | userspace + module experiments |
| RuntimeASLR [Lu, Lee, Nürnberger, Backes — NDSS'16] | NDSS 2016 | pointer-tracked address-space remap of *child* after fork | per fork() | none on hot path (Pin-based parent) | targets BlindROP/clone-probing |
| Shuffler [Williams-King et al., OSDI'16] | OSDI 2016 | function permutation in same address space, async shuffle thread | every 20–50 ms | 14.9% SPEC @ 50 ms | canonical reference; userspace x86-64; defeats ROP, JIT-ROP, BROP |
| CodeArmor [Chen, Bos, Giuffrida — EuroS&P'17] | EuroS&P 2017 | full code-space virtualization, honey gadgets, periodic remap | continuous | 6.9% SPEC / 14.5% server | binary-only, no source needed |
| Defeating Zombie Gadgets [Werner, Snow, et al., ESSoS'17] | ESSoS 2017 | rerandomize when disclosure detected | reactive | low | direct response to Snow's zombie-gadget attack |
| Smokestack [Aga & Austin, CGO'19] | CGO 2019 | per-invocation stack-variable permutation | every function entry | ~22% | defense vs. DOP (Data-Oriented Programming) |
| CoDaRR [Rajasekaran et al., AsiaCCS'20] | AsiaCCS 2020 | continuous **data**-space randomization (DSR masks) | on-demand or ≤ 2 s | moderate | first dynamic DSR; orthogonal to code rerand |

**Seminal insight, paper-by-paper (compressed):**

- **TASR**: Don't randomize on a timer — randomize on I/O. Disclosure is only dangerous when its result *crosses a trust boundary*; rerandomize between an output and the next input and any leaked layout is stale.
- **Shuffler**: Shuffle continuously, fast, in-process, with an asynchronous mutator thread that swaps two code copies atomically. Imposes a deadline on the attacker measured in milliseconds. Userspace only; required heavy binary rewriting (egalito).
- **Isomeron**: Coin-flip between two semantically identical replicas at every function call — the attacker can't predict which replica will execute next, so a chain of gadgets fails probabilistically.
- **Remix**: Shuffle basic blocks *within* a function to dodge the function-pointer-fixup problem that kills naive function-level rerand. Importantly, Remix explicitly targets **kernel modules** as well as userspace, but is research-grade only.
- **RuntimeASLR**: Address-tag tracking via Pin so the post-fork child has a remapped address space even though it inherited parent state. Specifically defeats BlindROP-style clone probing.

**Why almost none of this is deployed:** every system above either (a) needs heavy compiler cooperation or binary rewriting (Shuffler, Stabilizer, Readactor, Oxymoron, TASR, CodeArmor), (b) has overhead that production won't tolerate (Isomeron, Smokestack), (c) breaks legitimate uses of code addresses (function pointers in callbacks, JITs, signal trampolines), or (d) was killed by a follow-up attack paper (Oxymoron broken by Snow's JIT-ROP variants; Heisenbyte broken by zombie gadgets [Snow S&P'16]).

**Critical measurement paper**: Ahmed et al., *Methodologies for Quantifying (Re-)randomization Security and Timing under JIT-ROP*, CCS 2020. Empirically derives upper bounds on rerand intervals under JIT-ROP. Finding: instruction-level rerand can defeat Turing-complete gadget chaining; function/BB-level cannot. Re-rand intervals under ~1.5–2.4 s are too slow against current JIT-ROP exploits. **Implication for evasive-linux: function-level rerand at livepatch cadence (~seconds) is on the slow edge of the useful regime.**

## 2. Kernel-Specific Rerandomization

This is the sparse part of the literature.

- **KASLR (mainline Linux)**: base-only, fixed at boot. Bypassed by:
  - Double page-fault timing [Hund et al. S&P'13]
  - Prefetch side channel [Gruss et al. CCS'16]
  - Intel TSX-based DrK attack [Jang CCS'16]
  - Meltdown (2018)
  - EntryBleed / CVE-2022-4543 against KPTI [Liu HASP'23]

  Effective entropy: ~9 bits on x86_64 Linux because of the 1 GiB KASLR region. Universally considered "speed bump only."

- **FGKASLR (Function-Granular KASLR)**: Proposed by Kristen Carlson Accardi (Intel) in 2020. Reorders kernel functions at boot. Reached v10 patchset Feb 2022. **Status as of 2026: still out-of-tree**, never merged to mainline. Cost: ~3% vmlinux size, ~15% bzImage size, runtime variable. Still a one-shot at boot — does not address continuous rerand.

- **Giuffrida, Kuijsten, Tanenbaum, "Enhanced OS Security Through Efficient and Fine-grained ASR," USENIX Sec'12**: First **comprehensive** kernel rerand strategy. Targets MINIX 3 microkernel. ~5% steady-state overhead but ~50% if rerand every 1 s, ~10% at 5 s. The microkernel architecture is essential — re-randomizing a monolithic Linux kernel was an open problem after this.

- **Adelie [Nikoleris et al., ASPLOS'22]**: **The closest existing work to what evasive-linux is proposing.** Continuous KASLR for Linux *kernel modules* using PIC model + stack rerand + address encryption. Targets the monolithic-Linux problem head-on but only handles modules, not the kernel core. Demonstrates that continuous KASLR in a monolithic kernel is feasible and roughly affordable.

- **kMVX [Österlund et al., ASPLOS'19]**: Not rerand — runs multiple **diversified** kernels in parallel under N-variant execution to detect info leaks. Different defense axis but addresses the same threat.

- **kRX [Pomonis et al., TOPS'19]**: kernel execute-only memory to thwart JIT-ROP. Complementary, not rerand.

- **"Preventing Kernel Code-Reuse Attacks Through Disclosure-Resistant Code Diversification" [Pomonis et al., CNS'16]**: kernel-side diversification (KHide) with code hiding. Build-time + load-time, not continuous.

- **Livepatch-as-MTD-vehicle**: **No prior published academic work uses CONFIG_LIVEPATCH, kpatch, or kGraft as a continuous code-movement transport.** Livepatch's design (ftrace-based per-function redirection, klp_object/klp_func with stack consistency model) is in fact well-suited to it, but the literature has not made this connection in publication. **This is evasive-linux's novel contribution surface.**

## 3. Industry / Practitioner Perspective

- **Red Hat kpatch**: Strictly CVE-fix oriented in all public documentation and patch-author guides. No published MTD experimentation.
- **SUSE kGraft**: Same — security patches only; doc explicitly discourages data-structure changes. No MTD discussion located.
- **Canonical Livepatch Service**: Security-only; some bug-fix support per CLI flags, no MTD/rerand mentions.
- **Oracle Ksplice**: CVE patching, plus interesting extensions — patches glibc/openssl in userland and the Xen hypervisor + qemu. Never marketed as MTD, but Ksplice is the most expansive in scope.
- **Amazon Linux** kernel live patching documents bug fixes as in scope but no rerand.
- **Google LLpatch**: LLVM-IR based livepatch generator. Internal infra tooling; no public MTD framing.
- **grsecurity / PaX**: closest in *spirit*.
  - **RANDKSTACK**: re-randomizes per-task kernel stack on **every syscall**. **This is *the* shipping continuous-rerand mechanism inside the kernel today.**
  - **KERNSEAL**: hides/seals kernel data; not code rerand.
  - **RAP**: type-based CFI + per-task/per-syscall rotating return-address encryption key. Structurally MTD applied to return addresses, not code.

  None reshuffle text on a schedule; PaX has historically said they considered it but rejected it on cost grounds.
- **Polyverse Polyscripted / Polymorphic Linux**: prior commercial product in the same neighborhood; build-time per-instance binary diversification but not continuous rerand at runtime in a kernel.
- **Morpheus [Gallagher et al., ASPLOS'19]**: hardware secure processor that "churns" pointer encryption every 50 ms. Survived DARPA FETT bug bounty against 500+ researchers. ~1% overhead. **Closest commercial-grade demonstration that 50 ms churn is practically affordable** — although in custom silicon, not software.

## 4. Code Honeypots / Deceptive Defense in Code

See companion dossier `02-honeytrap-old-code-prior-art.md` for the deep treatment of this angle. Brief summary here:

- **HoneyGadget [Yang et al., 2019]**: inserts honey gadgets into unreachable code regions; any execution = ROP detection. ~7.6% overhead. Userspace only.
- **CodeArmor** uses honey gadgets pervasively as a *substrate* alongside code-space virtualization — combines deception + rerand.
- **Three Decades of Deception Techniques in Active Cyber Defense** (arXiv 2104.03594) — survey covers honey-X across the stack, including honey-code, but the code-deception subarea remains thin.
- **Specifically: "turn relocated-from-old addresses into traps"** — this idea is essentially unpublished. A clean novel angle worth claiming.
- DARPA programs: **MEERKATS** (cloud MTD), **MIRAGE** (deceptive systems), **CRASH** (clean-slate trustworthy hosts → produced Morpheus and CHERI). Don't appear to have produced specific kernel-livepatch-MTD outputs.

## 5. Adjacent MTD Ideas Worth Knowing

- Jajodia et al., **Moving Target Defense I** (Springer 2011) and **II** (2013): foundational edited volumes. Mostly network-level / configuration MTD, less code-level. Establishes terminology of "shifting attack surface," "asymmetric uncertainty."
- **NSA MTD Initiative** (~2011–2015): government framing rather than concrete kernel systems.
- **Microsoft**: no public published continuous-code-rerand effort. Closest: ASLR improvements in Win10/Win11 (HighEntropyVA, CFG, XFG). Microsoft Research's "Finding Diversity in Remote Code Injection Exploits" (2009) frames the problem but doesn't propose continuous rerand.
- **N-variant systems / multi-variant execution**: Cox et al. (USENIX Sec'06), Volckaert et al., kMVX, ReMon. Orthogonal axis: run diversified replicas concurrently rather than rerandomize one.
- **Instruction-Set Randomization** (Kc, Keromytis, Prevelakis CCS'03; revived by Sinha et al. 2017): scramble instruction encoding; high overhead without HW.

## 6. Critical Reception — Honest Arguments Against

1. **The Snow critique (S&P'13, S&P'16):** If the attacker has *any* memory-disclosure primitive, JIT-ROP can re-bootstrap the gadget chain within a single request. Continuous rerand only helps if the rerand interval ≤ attacker's leak-and-build time. Ahmed et al. CCS'20 measured this: function-level rerand must complete in < ~2 s; instruction-level rerand can plausibly stay ahead. **Implication for evasive-linux:** livepatch-driven rerand at function granularity is on the slow edge of the useful regime; basic-block or block-permutation granularity inside livepatch payloads may be required.

2. **"More leak primitives don't help" critique:** continuous rerand is leak-resistant only insofar as the rerand thread itself doesn't expose its randomness source. Adelie, Shuffler, and Morpheus all have explicit threat models excluding leaks of the rerand metadata; KASLR-bypassing side channels (EntryBleed, prefetch) directly contradict this assumption in production kernels.

3. **Performance cost in the kernel:** ftrace-based livepatch indirection adds ~percent already; cascading rerand on top induces additional I-cache invalidation, iTLB flushes, and IPI shootdowns. Giuffrida'12 showed 50% overhead at 1 Hz rerand in a microkernel; monolithic Linux is worse. Adelie's modules-only restriction is partly a concession to this.

4. **Cache/TLB pressure:** Every reshuffle is a self-induced cold-start. Shuffler's mitigation (two live code copies, atomic switch) doubles iTLB working set. In a kernel running on every CPU, synchronized IPIs are required — livepatch already implements the consistency model (`klp_check_stack`) but rerand frequency at 5 minutes is fine, at 5 seconds is not.

5. **Function-pointer aliasing and DKMS / kernel modules:** kernel callbacks (file_operations, net_device_ops, syscall table) are full of function pointers stashed in long-lived data structures. Naive rerand corrupts every such pointer. Shuffler-style indirection vector or Remix-style intra-function BB shuffling is required to dodge this. Livepatch's klp_relocations and ftrace handler give a natural hook point, but every reshuffle must reconcile every stored function pointer — **the central engineering challenge.**

6. **Interaction with eBPF JIT and BPF trampolines:** modern Linux now JIT-compiles BPF programs and patches in kfunc trampolines. Any rerand mechanism must coordinate with `bpf_jit_alloc_exec` and friends — under-discussed in the literature because most rerand work predates this.

7. **The disclosure boundary argument (TASR):** rerandomizing on a *trust event* (output, context switch, syscall return) gives much stronger guarantees per CPU cycle than rerandomizing on a timer. For kernel work this maps cleanly to syscall-return or context-switch — **a much better trigger than wall-clock minutes.**

## 7. What is Deployed vs Published vs Unexplored

| Status | Items |
|---|---|
| **Deployed, stable** | mainline KASLR (base-only); grsecurity RANDKSTACK + RAP; Morpheus (silicon prototype, not commodity); livepatch/kpatch/kGraft/Ksplice — but **only for CVE fixes** |
| **Published, prototype, not deployed** | Shuffler, TASR, Readactor, Isomeron, Oxymoron, CodeArmor, Remix, RuntimeASLR, Stabilizer, Smokestack, CoDaRR, kMVX, kRX, HoneyGadget, Adelie, Giuffrida'12 MINIX rerand |
| **Published but in mainline limbo** | FGKASLR (out-of-tree since 2020, never merged) |
| **Unexplored / novel surface for evasive-linux** | (a) using livepatch as the MTD transport with no CVE attached — no paper located; (b) periodic rerand of the **monolithic Linux kernel core** (Adelie only does modules); (c) turning a function's *previous* address range into a honey-gadget trap post-relocation; (d) coupling build-time scrambling (encrypted-linux) with runtime livepatch-driven rerand as a layered defense; (e) per-syscall livepatch-style function swap (RAP rotates a key per-syscall — nobody rotates the *function body* per-syscall) |

## 8. Sources

- Williams-King et al., Shuffler — [OSDI'16 PDF](https://www.usenix.org/system/files/conference/osdi16/osdi16-williams-king.pdf)
- Bigelow et al., TASR — [CCS'15 PDF](https://web.mit.edu/ha22286/www/papers/CCS15_2.pdf)
- Lu et al., RuntimeASLR — [NDSS'16 PDF](https://www.ndss-symposium.org/wp-content/uploads/2017/09/how-make-aslr-win-clone-wars-runtime-re-randomization.pdf)
- Chen et al., Remix — [CODASPY'16 PDF](https://www.cs.fsu.edu/~whalley/papers/codaspy16.pdf)
- Davi et al., Isomeron — [NDSS'15 PDF](https://www.ndss-symposium.org/wp-content/uploads/2017/09/05_3_2.pdf)
- Backes & Nürnberger, Oxymoron — [USENIX Sec'14 PDF](https://www.usenix.org/system/files/conference/usenixsecurity14/sec14-paper-backes.pdf)
- Crane et al., Readactor — [S&P'15 PDF](https://www.ieee-security.org/TC/SP2015/papers-archived/6949a763.pdf)
- Chen, Bos, Giuffrida, CodeArmor — [EuroS&P'17](https://ieeexplore.ieee.org/document/7962000/)
- Giuffrida, Kuijsten, Tanenbaum (MINIX rerand) — [USENIX Sec'12 PDF](https://www.usenix.org/system/files/conference/usenixsecurity12/sec12-final181.pdf)
- Nikoleris et al., Adelie — [arXiv 2201.08378](https://arxiv.org/abs/2201.08378), [ASPLOS'22](https://dl.acm.org/doi/10.1145/3503222.3507779), [GitHub](https://github.com/adelie-kaslr)
- Ahmed et al., Methodologies for Quantifying Rerandomization — [arXiv 1910.03034](https://arxiv.org/abs/1910.03034)
- Snow et al., Zombie Gadgets — [S&P'16 PDF](https://fabianmonrose.github.io/papers/snow16b.pdf)
- Werner et al., Defeating Zombie Gadgets — [ESSoS'17 PDF](https://dandylife.net/docs/rerand.essos17.pdf)
- Gallagher et al., Morpheus — [ASPLOS'19](https://dl.acm.org/doi/10.1145/3297858.3304037)
- Curtsinger & Berger, Stabilizer — [ASPLOS'13 PDF](https://people.cs.umass.edu/~emery/pubs/stabilizer-asplos13.pdf)
- Österlund et al., kMVX — [ASPLOS'19 PDF](https://download.vusec.net/papers/kmvx_asplos19.pdf)
- Yang et al., HoneyGadget — [Springer](https://link.springer.com/chapter/10.1007/978-3-030-34637-9_9)
- Rajasekaran et al., CoDaRR — [AsiaCCS'20 PDF](https://people.cs.kuleuven.be/~stijn.volckaert/papers/2020_AsiaCCS_CoDaRR.pdf)
- Jang et al., DrK / Intel-TSX KASLR break — [CCS'16 PDF](https://taesoo.kim/pubs/2016/jang:drk-ccs.pdf)
- Liu et al., EntryBleed — [HASP'23 PDF](https://people.csail.mit.edu/mengjia/data/2023.HASP.EntryBleed.pdf)
- PaX RANDKSTACK — [pax.grsecurity.net](https://pax.grsecurity.net/docs/randkstack.txt)
- FGKASLR v10 patchset — [lore.kernel.org](https://lore.kernel.org/lkml/20220209185752.1226407-1-alexandr.lobakin@intel.com/)
- Linux livepatch docs — [docs.kernel.org/livepatch](https://docs.kernel.org/livepatch/livepatch.html)

---

### Summary

The literature has a well-developed userspace rerand line (TASR, Shuffler, RuntimeASLR, Isomeron, Readactor, CodeArmor, Stabilizer) but a strikingly thin kernel line: Giuffrida'12 on microkernels, kMVX/kRX as orthogonal defenses, and **Adelie (ASPLOS'22) as the only published continuous-KASLR system for Linux — restricted to modules, not core**. The two ideas evasive-linux is built on — (1) using livepatch as a non-CVE MTD transport, and (2) turning the post-relocation old address range into honey-gadget traps — both appear genuinely unexplored in print. The strongest critical thread to address is the Snow / Ahmed CCS'20 lower-bound: function-level rerand at intervals > ~2 s is largely defeated by JIT-ROP given a memory disclosure primitive, so a livepatch-driven rerand cadence and granularity have to be designed against that empirical bound. PaX RANDKSTACK (per-syscall stack reshuffle) is the only continuous-rerand mechanism *shipping* inside Linux kernels today and is a useful precedent and benchmark.
