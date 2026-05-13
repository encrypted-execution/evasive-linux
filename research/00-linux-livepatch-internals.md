# Livepatch as MTD Transport for evasive-linux

*Research dossier — compiled 2026-05-12*

This document captures how Linux's livepatch subsystem works, how to enable it on a vanilla self-compiled kernel, and what the public literature looks like for the project's core thesis: using livepatch as the transport mechanism for *continuous in-kernel code re-randomization*.

The headline finding: **the specific idea of using upstream livepatch as the transport for continuous in-place kernel code re-randomization appears to be novel in the public literature.** Adelie (ASPLOS '22) is the closest competitor and only covers modules (not vmlinux), uses bespoke module-remapping rather than livepatch, and runs at seconds-scale cadence. The honeytrap-on-stale-function-body construction is also unexplored.

---

## 1. How Linux livepatch actually works

### 1.1 Module layout

A livepatch is a regular `.ko` kernel module. It declares a `struct klp_patch` containing one or more `struct klp_object` (one per target binary: `vmlinux` itself plus any patched modules), each holding `struct klp_func` entries that name the function to patch (`old_name`), the replacement (`new_func`), and optionally `old_sympos` to disambiguate static symbols of the same name. The module's `init` calls `klp_enable_patch()`; the rest is bookkeeping.

### 1.2 Redirection: ftrace, not text-poking

Livepatch deliberately does **not** overwrite the prologue of the old function with a `jmp`. Instead it leans entirely on the dynamic-ftrace infrastructure. Every kernel function compiled with `-pg -mfentry` (x86_64) or `-fpatchable-function-entry` (arm64) has a NOP slot at function entry that ftrace can rewrite atomically to a `call __fentry__` trampoline. When livepatch wants to redirect `foo`, it registers a `klp_ftrace_handler` against `foo`'s fentry site; the handler rewrites the saved instruction pointer in `pt_regs` to point at `new_foo`, then returns. The CPU then "returns" from the trampoline into the new function.

Mechanism implications:

- The **old function body is left intact in `.text`**. Only the entry NOP becomes an ftrace call. This is the seed of the honeytrap idea (§4).
- The redirection is atomic from a single-CPU view because the entry instruction is a single aligned write; cross-CPU consistency is provided by an IPI (`text_poke_sync`/`text_poke_bp` machinery).
- Multiple patches stack on one function via `func_stack` in `struct klp_ops`; the topmost wins and the universal ftrace handler selects it.

### 1.3 Consistency model: the hybrid that landed in 4.12

Three historical positions:

- **kpatch (Red Hat, 2014)**: stop_machine, walk every task's stack, abort if any task is inside a function being patched. Atomic but high-latency and fragile (one stuck kernel thread aborts).
- **kGraft (SUSE, 2014)**: per-task `TIF_PATCH_PENDING`; a task switches to patched code only at a syscall/IRQ/sleep boundary. Old and new can coexist arbitrarily long.
- **Unified / hybrid (Josh Poimboeuf, merged in 4.12, March 2017)**: kGraft's per-task gating plus kpatch's stack walking as an accelerator. On `klp_enable_patch`, every task gets `TIF_PATCH_PENDING`. A periodic worker tries `klp_try_switch_task()`: it does a *reliable stacktrace* of each task and, if none of the patched functions appear on the stack, flips `task->patch_state = KLP_PATCHED` and clears the flag. Stuck tasks transition naturally when they next return through a syscall barrier. When the last task switches, `klp_complete_transition()` runs.

The "reliable stacktrace" requirement is why livepatch needs `CONFIG_HAVE_RELIABLE_STACKTRACE` and, on x86_64, ORC unwind tables (`CONFIG_UNWINDER_ORC`).

### 1.4 Symbol resolution across the kernel boundary

A livepatch module needs to reference symbols not exported from `vmlinux`, including *static* symbols. The module loader can't do that directly. The livepatch toolchain therefore emits special relocations in a `.klp.rela.{objname}.{section}` section and a parallel `.klp.sym.{objname}.{symname},{sympos}` symbol table. At `klp_enable_patch` time, `klp_resolve_symbols()` (in `kernel/livepatch/core.c`) walks the target object's kallsyms, picks the `sympos`-th occurrence of each requested name, and patches the relocation entries. Same machinery handles late-loaded patched modules: relocations are deferred until the target appears in `MODULE_STATE_COMING`.

### 1.5 Lifecycle

```
insmod patch.ko
  → klp_enable_patch()
      → klp_init_patch_early / klp_init_patch
      → klp_resolve_symbols (apply klp-relas)
      → klp_init_object_loaded for each object
      → klp_start_transition  (set TIF_PATCH_PENDING on all tasks)
      → klp_try_complete_transition (periodic kworker)
      → klp_complete_transition (all tasks converged)
sysfs flips /sys/kernel/livepatch/<name>/enabled to 1
... patch active ...
echo 0 > /sys/kernel/livepatch/<name>/enabled
  → reverse transition (same dance, opposite direction)
rmmod patch  (only legal after disabled + transition done)
```

Atomic replace (`.replace = true`, added 2018) allows a new cumulative patch to logically supersede *every* previous patch in a single transition. After it completes, the older patch modules can be `rmmod`'d. **This is the single most relevant feature for evasive-linux:** it gives a clean "swap the layout" primitive.

---

## 2. Enabling livepatch on a vanilla self-compiled kernel

Required kconfigs (x86_64 reference set, observed against 6.12+):

```
CONFIG_LIVEPATCH=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_DYNAMIC_FTRACE_WITH_REGS=y      # or _WITH_ARGS on newer kernels
CONFIG_HAVE_RELIABLE_STACKTRACE=y      # auto-selected on x86_64+ORC
CONFIG_UNWINDER_ORC=y                  # do NOT use FRAME_POINTER unwinder
CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_KALLSYMS_ALL=y                  # needed for static-symbol lookup
CONFIG_MODULES=y
CONFIG_SYSFS=y
```

Toolchain requirements:

- GCC must support `-mfentry` and `-mrecord-mcount` (any GCC ≥ 4.6; modern kernels insist).
- For klp-build (Linux 6.19+) additionally `-ffunction-sections -fdata-sections` and an objtool that understands `klp diff`.
- `-flive-patching=inline-clone` (GCC 8+) disables IPA optimizations that break per-function patching. **Critical for evasive-linux**: without it, GCC may inline aggressively or do interprocedural cloning, and "swap function X" semantics break silently.

Architecture support (as of mainline ~6.12):

| Arch | Status |
|---|---|
| **x86_64** | Fully supported, primary target |
| **ppc64le, s390x** | Supported |
| **arm64** | Landed in 6.x; uses `-fpatchable-function-entry=4,2`; reliable stacktrace present |
| **arm32, riscv, others** | Not supported (no reliable stacktrace) |

For evasive-linux: **x86_64 first, arm64 stretch goal**.

Hardening interactions:

- `RANDSTRUCT_FULL` — orthogonal at the function-redirection level (livepatch redirects code, randstruct shuffles data layout). But: a livepatch module built against a *different* randstruct seed than the running kernel will read the wrong struct offsets. **The randstruct seed must match between the running kernel build and every livepatch module.** This is the encrypted-linux seed-management problem already solved upstream.
- `CONFIG_DEBUG_INFO_BTF` — required by some tooling (klp-build, pahole).
- `CONFIG_X86_KERNEL_IBT` (Intel CET) — livepatch trampoline targets must be `endbr64`-prefixed; modern kernels handle this, but custom-generated modules must as well.
- `CONFIG_RETPOLINE`, `CONFIG_MITIGATIONS=y` — compatible.
- `CONFIG_FORTIFY_SOURCE`, KASAN, KCSAN — all compatible.

---

## 3. Continuous re-randomization as MTD: prior art

**The specific idea — using the upstream livepatch subsystem as a transport for continuous code re-randomization (not tied to a CVE fix) — appears to be unexplored in the public literature.** No paper, no LKML thread, no Linux Plumbers talk proposes it. Adjacent work that must be cited and contrasted:

**Shuffler** (Williams-King et al., OSDI 2016) — userspace, x86_64 Linux. Re-randomizes binary + libraries on a millisecond cadence (50–200 ms shown), 7.99% steady-state overhead at one-shot, ~15% at 50 ms cadence. The shuffling thread runs asynchronously. Uses egalito-style binary rewriting. Canonical reference for "continuous code re-randomization works at millisecond cadence in userspace." No kernel analog exists from this group.

**Adelie** (Nikolaev et al., ASPLOS 2022) — **closest existing work to evasive-linux**. Continuous KASLR *for Linux drivers* (modules), built by converting kernel modules to PIC, then periodically remapping them anywhere in the 64-bit VA space. Explicitly does **not** re-randomize `vmlinux` itself, and does **not** use livepatch — uses module load/unload plumbing. Argues that PIC kernel is a prerequisite. Re-randomization period: seconds. Stack re-randomization and address encryption bolted on.

**Linux Kernel Module Continuous Address Space Re-Randomization** (Nadeem, Virginia Tech MS thesis 2020) — Adelie precursor. Same group.

**Rave** (Blackburn et al., MTD '22 workshop) — re-randomizes program state for *userspace containers* using CRIU + userfaultfd. Pages lazily served on-fault and re-randomized between dump and restore. Userspace only.

**Timely Rerandomization** (Bigelow et al., CCS 2015) — re-randomizes program memory after each output that could leak addresses. Userspace; conceptually predates Shuffler.

**Selfrando** (Crane, Larsen et al., PETs 2016) — load-time randomization for Tor Browser. No kernel follow-up published.

**PaX / grsecurity** — `RANDKSTACK` randomizes the kernel stack pointer on syscall return, but this is *stack-pointer entropy*, not code re-randomization. PaX has no continuous-code-rerandomization feature for the kernel. `KERNEXEC` and `RAP` are orthogonal.

**kpatch / kGraft authors on MTD** — no evidence the maintainers (Seth Jennings, Josh Poimboeuf, Joe Lawrence / Jiri Kosina, Vojtech Pavlik) ever discussed re-randomization as a use case. The `live-patching@vger.kernel.org` archive is focused on CVE-fix correctness.

**Unikernels** (Mirage, IncludeOS) — toyed with re-randomization via VM restart, but that's hypervisor-mediated re-init, not in-place re-patching.

**Net assessment**: the *idea* of using livepatch's redirection mechanism as a code-mobility transport is novel as far as the public record shows. Adelie is the most direct competitor; evasive-linux can credibly position as "Adelie, but for vmlinux not just modules, using livepatch as the transport instead of bespoke module remapping." This is a defensible novel contribution.

---

## 4. The honeytrap angle

Livepatch leaves the old function body intact in `.text` (only the entry NOP becomes a trampoline call). The body remains executable. This is, as suspected, a honeytrap surface.

Prior art on the *concept* of code-trap honeypots:

- **ROPscan** (Polychronakis, Malware '11) — speculatively executes suspected gadget chains to detect them. Detection, not deception.
- **kBouncer** (Pappas, USENIX Security '13) — uses Intel LBR to verify returns. Detection.
- **ROPNN** (Li et al., 2018) — deep-learning ROP detection. Detection.
- **Trapdoor** (Shan et al., CCS 2020) — honeypots for adversarial ML, not memory-corruption exploits; but the conceptual framing is identical.

**No prior art** was found for the specific construction: *after redirecting a function via livepatch, deliberately fill the old body with `INT3` or `UD2` (or with synthesized gadget chains that branch into a logger) to detect attackers who jumped to the pre-randomization address.* The closest is grsecurity's `KERNEXEC`, which removes W from kernel pages but doesn't booby-trap stale code.

Three concrete designs for evasive-linux:

1. **INT3 carpet**: after `klp_complete_transition`, overwrite the old function body with `0xCC` and trap to a `do_int3` handler that logs the faulting RIP. Cheap, no false positives if no legitimate caller reaches there. Requires writable `.text` momentarily (CR0.WP toggle or `text_poke_bp`).
2. **UD2 + custom #UD handler**: same idea, but `#UD` is a synchronous, never-legitimate fault in kernel code paths and gives cleaner forensics.
3. **Synthetic gadget bait**: fill old bodies with sequences that *look* like useful gadgets (`pop rdi; ret`, `mov cr3, rax; ret`) but actually branch to an attack logger. Cost: bigger memory footprint, risk of an attacker reading the bait and ignoring it. Benefit: catches attackers in the *exploitation* phase, not just the leak phase.

All three benefit from the fact that re-randomization makes the stale gadget pointer worthless even if the attacker doesn't trip the trap — the trap is bonus telemetry.

The honeytrap angle is meaningfully novel. The combination "rerandomized + trapped stale code = attack detector with strong oracle (any hit is malicious)" is publishable on its own.

---

## 5. Limitations and counterarguments

**Why continuous-rerandomization-via-livepatch hasn't been done — the hard parts:**

1. **Transition latency floor**. The unified consistency model converges "usually in a few seconds" per the docs. The lower bound is `(longest-sleeping-kernel-thread-wakeup) + IPI cost`. Long-sleeping tasks (`kthreadd`, idle workers) can hold up convergence indefinitely; livepatch has `/sys/kernel/livepatch/<name>/force` exactly to deal with this. **Continuous re-randomization at sub-minute cadence is plausible; at sub-second it is probably not.** Adelie reports seconds-scale.

2. **Inlining defeats per-function granularity**. If `foo` got inlined into 30 callers, redirecting `foo` does nothing — the 30 callers contain expanded copies. `-flive-patching=inline-clone` mitigates by emitting non-inlined fallbacks, at non-trivial size and perf cost. kpatch-build / klp-build handle this by computing the *transitive caller closure* of any changed function and patching all of them.

3. **Tail-call optimization**. A tail call (`jmp foo` instead of `call foo`) skips the fentry NOP entirely. ftrace won't intercept it. The new function will *not* be called. Must disable TCO globally (`-fno-optimize-sibling-calls`) for any function that may be re-randomized — measurable perf cost.

4. **static_key / jump_label / alternatives**. These are special sections patched at boot (and on module load) based on CPU features or runtime branch toggles. They contain absolute or relative addresses into `.text`. If re-randomization moves code, all these encoded addresses become stale. Solution: each re-randomization must walk `__jump_table` and `.altinstructions` and re-emit them. Non-trivial.

5. **paravirt / pv_ops**. Function-pointer indirection through `pv_ops` table works fine (re-point), but inline-patched pv_ops sites require the same `__alt_instructions` walk.

6. **kprobes / eBPF / fprobes attached to patched functions**. From the livepatch docs: kprobes and livepatch on the same function are mutually exclusive via `FTRACE_OPS_FL_IPMODIFY`. First registration wins. Operationally: re-randomization must temporarily evict and reinstall debugging probes, or skip functions that have probes.

7. **Per-CPU and per-task state in patched functions**. Function-local statics are fine (they live in `.bss` / `.data`, not `.text`, and survive). But if `foo` holds locks, refcounts, or RCU read-side critical sections across a yield point, the consistency model must guarantee no task is *inside* `foo` at switchover. That's exactly what the stack walk enforces. Hot, long-running functions (scheduler, RCU, IRQ handlers) are essentially unpatchable. **Expect ~5–15% of `vmlinux` by function count to be in the "never re-randomizable" set.**

8. **Memory cost**. Every re-randomization generates a new module. Naive implementation leaks the old `.text` until rmmod. Atomic-replace + rmmod-old gives O(1) memory, but every cycle pays for new module allocation, BTF, kallsyms churn.

9. **Information leak via `/proc/kallsyms`, `/sys/kernel/livepatch/`, perf, ftrace**. Re-randomization is pointless if these leak the new layout. Must lock these down to root and accept that root-equivalent exploits defeat the scheme.

10. **The reason this hasn't been built is probably (5)+(6)+(9) combined**: the engineering tax of keeping `__jump_table`, `.altinstructions`, kprobes, eBPF, ftrace, perf, and BTF all consistent on every re-randomization cycle is substantial, and the threat model (attacker who has a memory disclosure but not yet code execution) is narrower than the cost.

---

## 6. Tooling landscape

- **kpatch / kpatch-build** (Red Hat, github.com/dynup/kpatch) — the original. As of 2024 marked **deprecated** in favor of klp-build. Mechanism: compile kernel with and without the patch using `-ffunction-sections -fdata-sections`, diff the object files at the section level, link the changed sections into a livepatch module. Carried RHEL livepatching for a decade.

- **kGraft** (SUSE) — merged into upstream livepatch in 4.0; SUSE uses upstream livepatch + their own klp-ccp.

- **klp-ccp** (SUSE, github.com/SUSE/klp-ccp) — "Closure Compute Pass." Source-level tool: given a patch and a kernel source tree, computes the transitive closure of changed functions (callers needing re-patching due to inlining, statics, etc.) and emits a compileable livepatch source.

- **klp-build** (SUSE, github.com/SUSE/klp-build, merged into Linux 6.19 as an objtool subcommand) — successor to kpatch-build. Works on `vmlinux.o` instead of individual `.o`s, supports LTO and IBT, uses objtool's CFG analysis. ~3K lines smaller than kpatch-build, no out-of-tree hacks. **This is the tool evasive-linux should target.**

- **klp-convert** (RH, Joe Lawrence et al.) — handles klp-relocation rewriting for unexported / static symbols. Subsumed by klp-build / objtool.

- **Ubuntu Livepatch Service** / Canonical — proprietary delivery infrastructure on top of upstream livepatch; nothing technically novel underneath. The snapd-based deployment pipeline is interesting as an MTD delivery model.

- **Oracle Ksplice** — predates everything; proprietary; uses a stop-machine model with full-system quiescence. Mostly historical interest.

- **Xen Livepatch** (`xen/livepatch`) — separate codebase for the hypervisor itself. Worth a look as a less-encumbered reference implementation; smaller, cleaner.

---

## Closing: open questions for evasive-linux

Concrete unknowns this project must resolve before there's a credible prototype:

1. **What is the achievable re-randomization period on a quiescent x86_64 system?** Hypothesis: 1–10 seconds floor due to consistency-model convergence. Need a microbenchmark of `klp_enable_patch` → `klp_complete_transition` round-trip with an empty patch.

2. **What fraction of `vmlinux` functions are actually re-randomizable?** Subtract: tail-called functions, inlined-everywhere functions, functions on any kthread's perpetual sleep stack (scheduler core, RCU, IRQ entry), functions with active kprobes / eBPF. Need a kallsyms walk + ftrace-availability + static analysis. Expect 60–80% coverage at best.

3. **How does atomic-replace scale with N functions per cycle?** Livepatch was designed for `N≈10` CVE fixes. Evasive-linux needs `N≈thousands` per cycle. Does the transition stack walk cost scale linearly in N? Quadratically? Need a stress test.

4. **`__jump_table` and `.altinstructions` consistency**: is there a clean hook to walk and rewrite these on every re-randomization, or does each cycle need a bespoke pass? If bespoke, evasive-linux ships its own objtool extension.

5. **Honeytrap mechanics**: `INT3` fill of stale function bodies — does `text_poke_bp` allow writing entire function-body ranges, or only single instructions? If only single instructions, does evasive-linux need a separate "stale-text scribbler" using CR0.WP toggling? What's the cost?

6. **Seed and key management across re-randomizations**. Each new layout needs a fresh seed. Where does the seed come from (RDRAND? HW RNG?), and is it derived from the encrypted-linux seed-chain or independent? Threat model question: if the seed leaks, the next layout leaks.

7. **`/proc/kallsyms`, `/proc/kcore`, perf, ftrace lockdown story**. Without `lockdown=confidentiality`, root-or-equivalent leaks the new layout immediately, defeating the scheme. What's the minimum hardening posture?

8. **eBPF / kprobe coexistence policy**. Either (a) refuse to re-randomize functions with active probes, (b) evict and reinstall probes around each cycle, or (c) cooperate with a small kernel patch that makes ftrace ops re-attach by symbolic name rather than address. Option (c) is the most evasive-linux-shaped solution but requires upstream cooperation.

**Bonus question**: does evasive-linux re-randomize `vmlinux` at all, or only modules? Adelie-style "modules only" is dramatically easier and covers most attack surface (drivers are the bug-rich layer). Going after vmlinux is the differentiator vs. Adelie but multiplies engineering cost ~5×.

---

## Sources

- [Linux kernel livepatch documentation (kernel.org)](https://docs.kernel.org/livepatch/livepatch.html)
- [Livepatch source: kernel/livepatch/core.c (torvalds/linux)](https://github.com/torvalds/linux/blob/master/kernel/livepatch/core.c)
- [Atomic Replace & Cumulative Patches (kernel.org)](https://www.kernel.org/doc/html/latest/livepatch/cumulative-patches.html)
- [livepatch: hybrid consistency model (LWN, Jonathan Corbet)](https://lwn.net/Articles/714464/)
- [Kernel Live Patching (LWN 2014)](https://lwn.net/Articles/619390/)
- [livepatch: change to a per-task consistency model — commit d83a7cb3 (Josh Poimboeuf, 4.12)](https://github.com/torvalds/linux/commit/d83a7cb375eec21f04c83542395d08b2f6641da2)
- [Reliable Stacktrace (kernel.org)](https://www.kernel.org/doc/html/v5.15/livepatch/reliable-stacktrace.html)
- [Compiler considerations for livepatching (Joe Lawrence)](https://people.redhat.com/~jolawren/klp-compiler-notes/livepatch/compiler-considerations.html)
- [Everything You Wanted to Know About Kernel Livepatch in Ubuntu (Matthew Ruffell)](https://ruffell.nz/programming/writeups/2020/04/20/everything-you-wanted-to-know-about-kernel-livepatch-in-ubuntu.html)
- [kpatch (GitHub, dynup/kpatch — deprecated notice)](https://github.com/dynup/kpatch)
- [klp-build (SUSE)](https://github.com/SUSE/klp-build)
- [Linux 6.19 merges klp-build (Phoronix)](https://www.phoronix.com/news/Linux-6.19-objtool-klp-build)
- [klp-convert and livepatch relocations — LPC 2019](https://lpc.events/event/4/contributions/507/attachments/316/533/LPC2019.pdf)
- [Shuffler: Fast and Deployable Continuous Code Re-Randomization — Williams-King et al., OSDI 2016](https://www.usenix.org/system/files/conference/osdi16/osdi16-williams-king.pdf)
- [Adelie: Continuous Address Space Layout Re-randomization for Linux Drivers — ASPLOS 2022 (arXiv)](https://arxiv.org/abs/2201.08378)
- [Linux Kernel Module Continuous Address Space Re-Randomization — Nadeem MS thesis, Virginia Tech 2020](https://vtechworks.lib.vt.edu/handle/10919/104685)
- [Rave: Modular Framework for Program State Re-Randomization — MTD '22](https://www.ssrg.ece.vt.edu/papers/mtd22.pdf)
- [Timely Rerandomization for Mitigating Memory Disclosures — Bigelow et al., CCS 2015](https://web.mit.edu/ha22286/www/papers/CCS15_2.pdf)
- [Breaking KASLR with Intel TSX (DrK) — Jang et al., CCS 2016](https://taesoo.kim/pubs/2016/jang:drk-ccs.pdf)
- [PaX: Future of kernel self-protection (PaX Team)](https://pax.grsecurity.net/docs/PaXTeam-H2HC12-PaX-kernel-self-protection.pdf)
- [Xen livepatch documentation](https://xenbits.xen.org/docs/unstable/misc/livepatch.html)
- [A Survey of Research on Runtime Rerandomization Under Memory Disclosure](https://www.researchgate.net/publication/334751529_A_Survey_of_Research_on_Runtime_Rerandomization_Under_Memory_Disclosure)
- [Reliable and Stable Kernel Exploits via Defense-Amplified… — USENIX Security 2025](https://www.usenix.org/system/files/usenixsecurity25-maar-kernel.pdf)
