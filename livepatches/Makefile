# Makefile for evasive-linux out-of-tree livepatch modules.
#
# Demo 02 modules (hand-written, always present): lp1.c, lp2.c
# Demo 03 modules: lp_01.c ... lp_05.c — generated from lp_template.c
#                  by scripts/build-continuous-demo.sh before this
#                  Makefile is invoked. NOT present in the source tree.
# Demo 03b attacker module: attacker.c (always present)
#
# The lp_NN.o entries are added conditionally — only when the matching
# .c files exist in $(M). This lets demo 02's build (which doesn't
# generate the template) succeed without complaining about missing
# lp_01.c .. lp_05.c.

# Always-built modules.
obj-m += lp1.o
obj-m += lp2.o
obj-m += attacker.o

# Generated modules — only when present.
ifneq ($(wildcard $(M)/lp_01.c),)
obj-m += lp_01.o lp_02.o lp_03.o lp_04.o lp_05.o
endif
