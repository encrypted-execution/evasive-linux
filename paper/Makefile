# Compile the arXiv preprint.
#
# Requires pdflatex + biber. On Debian/Ubuntu:
#   sudo apt-get install texlive-full biber
# On macOS:
#   brew install --cask mactex; brew install biber

TARGET := main
TEX    := pdflatex -interaction=nonstopmode -halt-on-error

.DEFAULT_GOAL := pdf

.PHONY: pdf clean distclean watch

pdf: $(TARGET).pdf

$(TARGET).pdf: $(TARGET).tex refs.bib
	$(TEX) $(TARGET).tex
	biber $(TARGET)
	$(TEX) $(TARGET).tex
	$(TEX) $(TARGET).tex

clean:
	rm -f $(TARGET).aux $(TARGET).bbl $(TARGET).bcf $(TARGET).blg
	rm -f $(TARGET).log $(TARGET).out $(TARGET).run.xml
	rm -f $(TARGET).toc $(TARGET).fdb_latexmk $(TARGET).fls

distclean: clean
	rm -f $(TARGET).pdf

# `latexmk -pvc` would be nicer but isn't universally installed.
watch:
	@command -v latexmk >/dev/null 2>&1 || { echo "latexmk not found"; exit 1; }
	latexmk -pvc -pdf -interaction=nonstopmode -bibtex $(TARGET).tex
