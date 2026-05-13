# Security policy

## Scope and posture

evasive-linux is a research project — kernel-internals plumbing
exploring whether Linux's livepatch subsystem can serve as a transport
for continuous code re-randomization. It is **not** production code.
The README, the research dossiers, and the inline comments are direct
about what the defense does and doesn't do; nothing here should be
relied upon as a hardening measure for a live system.

That said, we care about the integrity of the demos. If you find one
of the following, we want to hear about it:

- A demo that claims a property (e.g., "the honey-trap fires when the
  attacker invokes a superseded address") but doesn't actually achieve
  that property, in a way the CI checks don't catch.
- A way to bypass the kprobe-based honey-trap from inside the running
  kernel — i.e., the trap registration succeeds but the trap doesn't
  fire when expected.
- A way to leak a future generation's planned layout from a previous
  generation while the patches are still loaded — i.e., information
  leak through `/proc/kallsyms`, `/sys/kernel/livepatch/`, perf,
  ftrace, BTF, or any other surface.
- A non-obvious crash in the demo modules' init or exit paths that
  isn't already documented.

## Reporting

For sensitive findings, please use GitHub's private vulnerability
reporting:
[github.com/encrypted-execution/evasive-linux/security/advisories/new](https://github.com/encrypted-execution/evasive-linux/security/advisories/new)

Or email: `me@archisgore.com`.

For everything else, regular GitHub issues are fine.

## What's explicitly *out* of scope

- "Random number from `RDRAND` isn't truly random" / general
  randomness-source criticism. Demos use the kernel's PRNG and call
  it good. The seed is recoverable; that's by design and discussed in
  `research/`.
- "An attacker who has full root / `/dev/mem` access can defeat
  this." Yes. The defense targets attackers with a memory disclosure
  primitive but not full kernel write-where. See
  `research/00-linux-livepatch-internals.md` §5.
- "Adelie, kASLR-Plus, or paper X already proposed this." If you have
  prior art the dossiers missed, PRs to update them are welcome.

## Disclosure

We follow a 90-day disclosure window for findings reported privately:
the fix lands, a patch is published, then the finding becomes public.
Earlier disclosure if the fix is non-trivial; later only with the
reporter's consent.
