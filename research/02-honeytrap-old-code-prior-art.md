# Research Dossier 02 — Honeytrap-the-Old-Code: Prior Art, Engineering, and the Gap

**Question.** When the Linux kernel is live-patched, the pre-patch function
body stays resident in memory — unreached, because ftrace trampolines now
redirect the entry point to the new function. Can that resident-but-dead
code be deliberately *poisoned* (INT3, UD2, infinite loop, instrumented
fake gadget, deceptive function body) so that any control transfer to it
is, by construction, an attack signal? The audience for this dossier is
someone deciding whether to actually build it.

## 1. What others have done

### 1.1 HoneyGadget — the closest direct ancestor

Huang, Yan, Zhang & Wang's **HoneyGadget** ([Springer chapter, SciSec
2019](https://link.springer.com/chapter/10.1007/978-3-030-34637-9_9);
extended journal version, *Information Systems Frontiers* 2020,
[link](https://link.springer.com/article/10.1007/s10796-020-10014-7))
is the only published system that explicitly proposes "honey gadgets" as
a defense primitive. The design:

1. At build time, insert short instruction sequences that *look like*
   useful ROP gadgets (`pop rdi; ret`, etc.) into locations no normal
   control flow will ever reach.
2. Record their addresses in a kernel-resident allowlist of honey
   addresses.
3. At runtime, use Intel **Last Branch Record (LBR)** to log the last 16
   indirect branches. On entry to sensitive functions (e.g.,
   `execve`, `mprotect`), compare the LBR history to the honey-address
   list. Any hit means a code-reuse attack used the trap gadget.

Reported overhead: ~7.6%. Importantly: HoneyGadget is a **userspace**
technique evaluated on PE binaries; it inserts decoys at build time, not
in residual post-patch code; and it relies on LBR sampling, not on the
trap firing directly. The deception is passive (the gadget executes
normally); detection is via after-the-fact branch history. This is the
nearest neighbor to the evasive-linux idea but a clearly different
construction.

### 1.2 Booby Trapping Software — the position paper

Crane, Larsen, Brunthaler & Franz, **Booby Trapping Software** (NSPW
2013, [PDF
mirror](https://ics.uci.edu/~sjcrane/papers/sjcrane13_booby_trapping_software.pdf)).
A position paper proposing that *every* defense currently designed to
prevent exploitation should also be paired with a trap that fires when
the prevented condition is violated — i.e. don't just stop the attack,
log it and respond. Examples: when a stack canary mismatches, don't just
abort; also call a per-application response routine. They argue that
diversification (a single-axis variant of which is ASLR) and booby traps
are complements. They do **not** discuss livepatch dead-code residue;
they predate the kpatch/livepatch consistency model (merged 2014–2016).

This is the conceptual framework that legitimizes the evasive-linux
idea but doesn't instantiate the specific case.

### 1.3 Zombie-gadget defenses — adjacent, opposite direction

Snow et al., **Return to the Zombie Gadgets** (Oakland 2016,
[PDF](https://www3.cs.stonybrook.edu/~mikepo/papers/heisenbite.sp16.pdf)),
and **Defeating Zombie Gadgets by Re-randomizing Code Upon Disclosure**
(ESSoS 2017, [PDF](https://dandylife.net/docs/rerand.essos17.pdf)).
Zombie gadgets are gadgets in code pages that have been "destroyed" by
destructive code reads but which the attacker reconstructs via code
inference. The defense is to *re-randomize* the old code, not to *trap*
on it. Snow's threat model is exactly the scenario evasive-linux is
worried about (attacker holds a pre-randomization pointer); the response
in the literature has been "make it not work," not "make it explode."

### 1.4 Apate — kernel-module syscall deception

Steinmetz, **Apate — A Linux Kernel Module for High Interaction
Honeypots** (arXiv 2015, [1507.03117](https://arxiv.org/abs/1507.03117)).
LKM that intercepts syscalls and returns deceptive results to attackers.
Operates at the syscall layer, not the code-residue layer. Establishes
that the "fake response to attacker" pattern is well-trodden in the
honeypot community, but at function-call granularity, not text-page
granularity.

### 1.5 In-place code randomization — what people did instead

Pappas, Polychronakis & Keromytis, **Smashing the Gadgets** (Oakland
2012, [paper](https://ieeexplore.ieee.org/document/6234439/)). The
canonical "kill gadgets in place" paper: rewrite instructions to
preserve semantics but break the gadget. RETGUARD on OpenBSD took the
gadget count in their kernel from 69,935 to 46
([paper](https://www.openbsd.org/papers/asiabsdcon2019-rop-paper.pdf)).
This is the **opposite philosophy**: remove gadgets, don't trap on them.
The two ideas are compatible (you can do both), but no published work
combines them on the same address range.

### 1.6 Cyber-deception surveys, kernel layer

Han, Kheir & Balzarotti, **Deception Techniques in Computer Security: A
Research Perspective** (ACM CSUR 2018,
[PDF](https://www.s3.eurecom.fr/docs/csur18_deception.pdf)). Pappas et
al., **Three Decades of Deception Techniques** (2021,
[arXiv 2104.03594](https://arxiv.org/pdf/2104.03594)). Lu & Wang,
**Cyber Deception Survey** (arXiv 2007.14497). All three surveys
catalogue deception at the network, host, application, file, and data
layers. **None enumerate a "text-page deception" or "post-patch residue
deception" category.** Yuill's process model
([NPS report](https://faculty.nps.edu/dedennin/publications/Yuill-Deception-for-Computer-Security-Defense.pdf))
covers honeyfiles and decoy services; not code regions.

### 1.7 DARPA programs

DARPA funded **Active Cyber Defense (ACD)** and an explicit **Cyber
Deception** thrust (~$15M, 2013) — focused on decoy file systems,
network infrastructure replication, beacon documents. The 2018+ Army
Cyber Deception program (
[C4ISRNet](https://www.c4isrnet.com/dod/army/2018/08/29/the-army-is-testing-deceptive-cyber-technology-despite-past-struggles/))
covers honey accounts, fake data, deceptive endpoints. **No DARPA
program I can find funded text-segment deception or post-patch-residue
deception specifically.** The closest is the Crane et al. NSPW paper
which came out of DARPA's CRASH program (UCI/UCI-led).

## 2. What others have *not* done — the actual gap

After fairly exhaustive search:

1. **No published work uses livepatch dead code specifically as a
   tripwire.** Searches across "kpatch tripwire," "livepatch
   honeytoken," "post-patch residue," "ftrace dead code" all return
   empty. The dead-code-as-tripwire idea is, as far as I can determine,
   unpublished.
2. **No work has instrumented INT3 in kernel text for SOC-pipeline
   delivery.** kprobes uses INT3 and logs to ftrace ring buffer; nobody
   has wired that into an SIEM ingest with attacker-attribution
   semantics. The literature treats INT3 as a debug primitive.
3. **No work has placed deliberately fake-but-instrumented gadgets in
   the kernel.** HoneyGadget does this in userspace and only for
   detection via LBR. The "instrumented gadget that logs registers and
   continues" variant is not in the literature.
4. **No work injects fake gadgets to pollute ROPgadget/ropper output.**
   This is a clean novelty: an attacker-side toolchain attack via
   honey-gadget pollution. Searched "gadget pollution," "gadget
   confusion," "ROPgadget poisoning" — empty.
5. **No work treats live-patched address space as a deception canvas.**
   The livepatch documentation calls the old code "dead" and moves on.
   Nobody has asked: what if dead code is the most valuable
   high-fidelity-alarm surface in the kernel?

The gap is real, not just an artifact of bad search terms.

## 3. Engineering feasibility on Linux

### 3.1 Can we overwrite the old function bytes?

Yes. The path is the same one livepatch already uses.

- `text_poke()` and `text_poke_bp()` (arch/x86/kernel/alternative.c)
  exist precisely to modify executable kernel text while it's mapped X.
  `text_poke_bp` uses the int3-then-replace dance documented in
  [LKML rewrite series](https://lkml.kernel.org/lkml/20191125154726.2f701690121e3630caf8a787@kernel.org/t/):
  write INT3 to byte 0 (atomic, 1 byte), IPI-sync, write the rest of
  the instruction, IPI-sync, replace byte 0 with the real first byte.
- `CONFIG_STRICT_KERNEL_RWX` makes text read-only via page-table perms,
  but the `text_poke` family explicitly walks around it with a private
  mm and CR3 switch (see [LWN](https://lwn.net/Articles/574309/) and the
  text_poke_mm rename
  [series](https://lists.openwall.net/linux-kernel/2025/03/27/1243)).
  Livepatch already uses this path.
- The 2025 text_poke_mm refactor is relevant: it cleans up the
  mm-switching for executable lockdowns, meaning a future evasive-linux
  poisoning module would plug into stable internal API.

**Verdict.** Overwriting a function body with `0xCC` (INT3) bytes is
trivially within reach of a livepatch-style module. Use the same
text_poke_bp dance livepatch uses, just with a different replacement
payload.

### 3.2 What does livepatch leave behind?

Confirmed from kernel docs and kpatch sources: livepatch redirects via
an ftrace handler installed at the function's `__fentry__` site (first
instruction after prologue). The body of the old function is **not
freed, not zeroed, not unmapped**. From the kpatch FAQ: *"removed
functions will continue to exist in kernel address space as effectively
dead code."*
([kpatch repo](https://github.com/dynup/kpatch/blob/master/doc/patch-author-guide.md)).
The transition model
([livepatch.rst](https://github.com/torvalds/linux/blob/master/Documentation/livepatch/livepatch.rst))
guarantees that after a successful patch transition, **no task is
executing in the old code** — which is exactly the precondition needed
to poison it without breaking anything. (Before transition completes,
threads may still be running in the old body. The poisoning module must
wait for `KLP_PATCHED` state per object.)

### 3.3 The fake-gadget construction

To generate *convincing but instrumented* gadgets:

- Use **ROPgadget**'s own algorithm to enumerate the gadget set in the
  pre-patch function body. Replace the bytes that constitute each gadget
  with an instrumented variant: e.g., for `pop rdi; pop rsi; ret`,
  substitute `pop rdi; pop rsi; call <log_thunk>; ret`. The call thunk
  records `RIP`, `RDI`, `RSI`, current task PID, and the LBR snapshot.
- Or substitute with bytes whose decoding under offset-1 / offset-2
  produces a *different* set of plausible gadgets that all funnel to the
  same thunk. This is unmapped territory.
- No existing tool does this. Closest is `ropgadget --binary`, which
  finds gadgets; there is no inverse tool that synthesizes them. The
  engineering is straightforward (a few hundred lines of Python).

### 3.4 Pitfalls

- **Backwards branches**: an attacker who knows the layout might compute
  `old_function_addr + offset` and target a *non-entry* point of the
  old body. INT3-poisoning catches this; an instrumented-gadget approach
  must ensure every byte in the old body is either INT3 or a logged
  gadget.
- **Hot-path performance**: zero impact, because by construction no
  legitimate code path enters the poisoned region.
- **CFI interaction**: KCFI
  ([Android post](https://source.android.com/docs/security/test/kcfi))
  hashes function signatures at indirect call sites. CFI alone won't
  prevent a leaked function-pointer attack on the old body — but it
  reduces the attack surface to direct jumps and ROP. The honeytrap
  catches what CFI doesn't.
- **`do_int3` handler**: the trap fires in interrupt context. The
  logger must be lockless (per-CPU ring buffer is standard) and not
  re-enter livepatch.

## 4. Detection-vs-deception tradeoff

Three operating modes, in increasing complexity and decreasing fidelity:

| Mode | Old-code fill | Detection signal | Attacker awareness |
|---|---|---|---|
| Tripwire | INT3 / UD2 every byte | Trap immediately, log RIP and stack | Low — until attacker probes |
| Tarpit | `JMP $` infinite loop | Stuck thread visible to scheduler | Medium |
| Decoy | Instrumented fake gadgets / functions | Log on every use, *continue* | Highest — attacker can be A/B tested |

The decoy mode is where this gets research-interesting: an attacker who
reads a leaked function pointer and chains through it gets a working
exploit that returns plausible values, while we observe every step.
This is genuinely **new territory** — the literature has detection
honeypots (HoneyGadget, kprobes) and deception services (Apate, honey
files) but not "deception-as-functioning-code-the-attacker-actually-uses."

The cost is asymmetric: tripwire mode is one `memset(addr, 0xCC, len)`
call per patched function. Decoy mode requires per-function deceptive
implementation and is bespoke per kernel version — the same maintenance
cost as livepatch itself.

## 5. Concrete proposal sketch for evasive-linux

A new LKM, **`klp-honeytrap`**, that:

1. Hooks `KLP_PATCHED` state transition. When livepatch declares an
   object fully transitioned, enumerate the old function bodies
   (addresses derivable from `klp_func->old_func` and the function
   length from kallsyms / ELF symbol size).
2. For each old function body, use `text_poke_bp` to overwrite all
   bytes with `0xCC` (INT3) — except the first byte, which livepatch
   already overwrote with a `CALL <ftrace>`. Optionally pad the tail
   with `UD2` (`0F 0B`) as a belt-and-suspenders against partial
   disassembly.
3. Register a custom `int3` notifier (via `register_die_notifier` with
   `DIE_INT3`) that, when the trap RIP falls in a poisoned region,
   logs `{RIP, task->pid, task->comm, regs, kernel_stack[0..8]}` to a
   per-CPU ring buffer drained to userspace via a perf event or
   relayfs. Then `do_exit()` the offending task.
4. Optional Phase 2: for selected hot functions (`getuid`, `commit_creds`,
   `prepare_kernel_cred`, syscall dispatcher entries — the well-known
   rootkit hook targets), generate an *instrumented decoy body* instead
   of an INT3 fill. The decoy returns plausible values (`0` from getuid,
   etc.) and logs every entry. This is bait for kernel rootkits that
   captured function pointers pre-patch.
5. Optional Phase 3: gadget pollution. At kernel link time, insert
   `.honeytrap_gadgets` sections containing instrumented gadget bodies
   marked as legitimate-looking by ROPgadget. Use linker scripts to
   place them at addresses where naive `vmlinux` scans will find them.
   Any execution is by definition an attack.

**Honest novelty assessment.**

- Phase 1 (INT3 fill of livepatch residue) is **clearly novel**. The
  building blocks exist; nobody has assembled them.
- Phase 2 (deceptive function bodies for rootkit-target functions) is
  **partly novel**: the deception literature has the pattern, but at
  the syscall/file layer, not the kernel-function layer.
- Phase 3 (fake-gadget injection) is **most novel** and most risky —
  the security argument depends on the trap firing in attacker code,
  which means attacker is already in kernel context, which means logging
  is racing them. Probably worth a paper but probably not worth shipping.

**Honest where-it-fails assessment.**

- The technique catches attackers who hold a *stale* pointer
  (pre-patch leak) or rely on *static* ROP gadget databases. It does
  **not** catch attackers who re-scan after each patch.
- It overlaps with KASLR base-reveal: if the attacker can read the
  poisoned bytes (just `0xCC` repeated), they learn nothing they didn't
  already know about KASLR. But if they can read the *length and
  location* of the INT3 region, they can map which functions were
  patched — minor disclosure surface.
- For Phase 3 specifically, sophisticated attackers will fingerprint
  the gadget bodies and skip the honey ones. This is the same problem
  HoneyGadget has. Defense degrades to: raise the cost of every
  kernel-ROP exploit by a constant factor while the deception holds.

**Recommended next step.** Build Phase 1 as a 200–400 line LKM, run it
on a fuzzing harness (syzkaller) with synthetic exploits that target
known pre-patch function addresses. Publish if Phase 1 catches anything
syzkaller's existing detectors miss. That's the experiment that
distinguishes "neat idea" from "publishable result."

---

**Sources (selected).**

- HoneyGadget — [SciSec 2019 chapter](https://link.springer.com/chapter/10.1007/978-3-030-34637-9_9) ; [ISF 2020 journal](https://link.springer.com/article/10.1007/s10796-020-10014-7)
- Booby Trapping Software (Crane et al., NSPW 2013) — [PDF](https://ics.uci.edu/~sjcrane/papers/sjcrane13_booby_trapping_software.pdf)
- Return to the Zombie Gadgets (Snow et al., Oakland 2016) — [PDF](https://www3.cs.stonybrook.edu/~mikepo/papers/heisenbite.sp16.pdf)
- Defeating Zombie Gadgets by Re-randomization (ESSoS 2017) — [PDF](https://dandylife.net/docs/rerand.essos17.pdf)
- Apate — A Linux Kernel Module for High Interaction Honeypots — [arXiv 1507.03117](https://arxiv.org/abs/1507.03117)
- Smashing the Gadgets (Pappas et al., Oakland 2012) — [IEEE](https://ieeexplore.ieee.org/document/6234439/)
- Removing ROP Gadgets from OpenBSD (Mortimer, AsiaBSDCon 2019) — [PDF](https://www.openbsd.org/papers/asiabsdcon2019-rop-paper.pdf)
- Han/Kheir/Balzarotti, Deception Techniques (ACM CSUR 2018) — [PDF](https://www.s3.eurecom.fr/docs/csur18_deception.pdf)
- Three Decades of Deception Techniques (2021) — [arXiv 2104.03594](https://arxiv.org/pdf/2104.03594)
- Cyber Deception Survey (2020) — [arXiv 2007.14497](https://arxiv.org/abs/2007.14497)
- Yuill, Deception for Computer Security Defense — [NPS](https://faculty.nps.edu/dedennin/publications/Yuill-Deception-for-Computer-Security-Defense.pdf)
- text_poke / text_poke_bp / text_poke_mm — [LWN](https://lwn.net/Articles/574309/) ; [ftrace rewrite series](https://lkml.kernel.org/lkml/20191125154726.2f701690121e3630caf8a787@kernel.org/t/) ; [openwall 2025-03](https://lists.openwall.net/linux-kernel/2025/03/27/1243)
- Livepatch documentation — [docs.kernel.org](https://docs.kernel.org/livepatch/livepatch.html) ; [livepatch.rst](https://github.com/torvalds/linux/blob/master/Documentation/livepatch/livepatch.rst)
- kpatch patch-author-guide — [GitHub](https://github.com/dynup/kpatch/blob/master/doc/patch-author-guide.md)
- STRICT_KERNEL_RWX vs livepatch — [linuxppc/issues#375](https://github.com/linuxppc/issues/issues/375) ; [LWN livepatch RFC](https://lwn.net/Articles/574309/)
- Kprobes (INT3 mechanism) — [docs.kernel.org](https://docs.kernel.org/trace/kprobes.html) ; [LWN intro](https://lwn.net/Articles/132196/)
- Android kernel CFI — [source.android.com](https://source.android.com/docs/security/test/kcfi) ; [LWN](https://lwn.net/Articles/900099/)
- Army cyber deception program — [C4ISRNet 2018](https://www.c4isrnet.com/dod/army/2018/08/29/the-army-is-testing-deceptive-cyber-technology-despite-past-struggles/)
