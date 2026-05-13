# arXiv preprint source

LaTeX source for the evasive-linux arXiv submission.

## Files

- `main.tex` — the paper. Compiles to ~12 pages.
- `refs.bib` — BibTeX bibliography (33 references).
- `Makefile` — convenience targets (`make`, `make clean`, `make watch`).

## Compile

Requires a TeX distribution with `biber` (Debian/Ubuntu:
`apt install texlive-full biber`, macOS: `brew install --cask
mactex` and `brew install biber`).

```bash
make           # produces main.pdf
make clean     # remove aux files
```

If you don't have `make`, the equivalent sequence is:

```bash
pdflatex main
biber main
pdflatex main
pdflatex main
```

## arXiv submission checklist

When ready to submit at <https://arxiv.org/submit>:

1. **Compile locally**, verify `main.pdf` looks correct.
2. **Choose primary category** `cs.CR` (Cryptography and Security).
   Secondary: `cs.OS` (Operating Systems).
3. **Bundle** for upload — arXiv wants a tarball or zip of the
   source. The minimum set is `main.tex` and `refs.bib`. arXiv
   re-compiles on their side; do not include `main.pdf` or `.bbl`
   files in the upload (unless their compiler can't reproduce
   yours).
4. **Abstract** — copy from the paper's `\begin{abstract}` block
   into arXiv's abstract field. Keep formatting markdown-free (arXiv
   strips LaTeX in the abstract field).
5. **Title** — copy from `\title{}`.
6. **Author** — currently `Archis Gore`. Co-authors? Add to `\author`.
7. **License** — Apache-2.0 already inherits from the project; on
   arXiv pick "CC BY 4.0" or "arXiv perpetual non-exclusive license"
   to match.
8. **Comments field** — suggested: "12 pages. Source, demos, and
   reproducible CI at github.com/encrypted-execution/evasive-linux".

## Pre-submission review pass

Before submitting, do at least these:

- [ ] Re-read §3 (threat model) and §6 (limitations) for honesty.
      Anything overclaimed?
- [ ] Verify every citation in `refs.bib` is reachable; especially
      check that the venue + year are correct.
- [ ] Run `chktex main.tex` if available; address any warnings.
- [ ] Check that captured demo output in §5 (Evaluation) matches the
      current repo HEAD's CI artifacts.
- [ ] Ask one trusted reviewer for feedback before submission. arXiv
      preprints are publicly indexed forever; first version sets the
      anchor.

## Notes for future revisions

- The paper currently has zero microbenchmarks. The natural v2 adds
  measurements of `klp_enable_patch → klp_complete_transition`
  latency, the per-cycle overhead of `register_kprobe` /
  `unregister_kprobe`, and a coverage analysis of which fraction of
  vmlinux is re-randomizable.
- The paper presents the kprobe-based honey-trap as the practical
  baseline and mentions INT3-carpet and synthetic-gadget-bait
  variants as future work. If either variant lands in the repo, it
  belongs in §4 (Design).
