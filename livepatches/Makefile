# Makefile for evasive-linux out-of-tree livepatch modules.
#
# Demo 02 modules (hand-written): lp1.o, lp2.o
# Demo 03 modules (generated from lp_template.c): lp_01.o ... lp_05.o
# Demo 03 attacker module: attacker.o
#
# The generated lp_NN.c files are produced by the orchestrator script
# before invoking `make -C /opt/linux M=$PWD modules`.

# Demo 02 — kept for backward compatibility.
obj-m += lp1.o
obj-m += lp2.o

# Demo 03 — 5 generations of evasive-linux livepatches.
obj-m += lp_01.o
obj-m += lp_02.o
obj-m += lp_03.o
obj-m += lp_04.o
obj-m += lp_05.o

# Demo 03b — simulated stale-pointer attacker.
obj-m += attacker.o
