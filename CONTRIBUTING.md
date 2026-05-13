# Contributing to evasive-linux

This is a research project exploring continuous in-kernel
re-randomization via Linux's livepatch subsystem. Contributions are
welcome — from typo fixes to new defense demos.

## Quick reproducibility check

Before you submit anything, make sure CI is green locally:

```
make demo-03   # the most comprehensive demo; ~15 min cold
```

If demo-03 ends with `evasive-linux HONEY-TRAP: superseded patch 02
hit at ...` in the QEMU console, you're set.

## Filing issues

Please include:

- Host OS and arch (`uname -a`).
- Docker version (`docker --version`).
- QEMU version (`qemu-system-x86_64 --version`).
- Which demo failed, and the last 80 lines of the corresponding
  `build/qemu-*.log` (or `build-continuous.log`).

If the issue is a security finding in the project's defenses (e.g.,
"the honey-trap can be bypassed by …"), please follow `SECURITY.md`
instead of opening a public issue.

## Code style

C code follows the Linux kernel coding style: tabs of width 8, K&R
braces, 80-column soft limit, `pr_info()` / `pr_warn()` for logging.
The `.editorconfig` at the repo root encodes this — your editor should
respect it.

Shell scripts use 4-space indentation, `set -euo pipefail` at the top,
`bash` shebangs (not `sh`).

Markdown uses 2-space indentation, ATX-style headers (`#`, `##`, …),
fenced code blocks with language identifiers.

## Adding a new demo

The pattern established by demos 01/02/03 is:

1. Add a `scripts/build-<name>-demo.sh` orchestrator that runs inside
   the `evasive-linux-kbuild` Docker image. The orchestrator should
   produce one or more `.ko` files and a self-contained
   `build/rootfs-<name>.cpio.gz` whose `/init` runs the demo and
   `poweroff -f`s when done.
2. If the demo needs new kernel config, add a fragment under
   `kernel/<name>.config` and append it in the orchestrator.
3. If the demo needs new livepatch sources, add them under
   `livepatches/` and reference from `livepatches/Makefile`.
4. Wire the demo into `.github/workflows/ci.yml` as a new job, with
   one or more `grep`-based assertions on `build/qemu-<name>.log` that
   prove the demo's claim.
5. Add a Makefile target (`make demo-<name>`).
6. Document the demo in `README.md`'s status table, with an
   abbreviated expected-output block.

## Adding a new livepatch generation to demo 03

To experiment with more generations (the current demo loads five),
edit two places:

- `scripts/build-continuous-demo.sh` — the `for nn in 01 02 03 04 05`
  list inside the docker driver (template materialization) and inside
  the init script (load loop).
- `livepatches/Makefile` — add `obj-m += lp_NN.o` for each new
  generation.

## Adding a new research dossier

Drop it under `research/` with a leading two-digit number and a
kebab-case slug. Cross-link from the README's "Research / prior art"
section.

## Commit message conventions

Subject line under 70 chars, imperative mood ("Add X" not "Added X").
Body explains *why* the change, not *what* — the diff already shows
the what. References to upstream sources (LWN articles, kernel
commits, papers) are encouraged.

## License

All contributions are accepted under Apache-2.0, the project's
existing license. By submitting a contribution you assert you have
the right to license it under those terms.
