// SPDX-License-Identifier: GPL-2.0
/*
 * lp1.c — first of two evasive-linux livepatch modules.
 *
 * Replaces fs/proc/cmdline.c::cmdline_proc_show with our own copy that
 * announces itself as "evasive-linux lp1 — patch #1". On init,
 * prints the address of the replacement function so the demo init
 * script can compare it against lp2's placement.
 *
 * License: GPL-2.0
 */
#include <linux/module.h>
#include <linux/printk.h>
#include <linux/seq_file.h>
#include <linux/livepatch.h>

static int evasive_lp1_cmdline_show(struct seq_file *m, void *v)
{
	seq_printf(m, "evasive-linux lp1 — patch #1\n");
	return 0;
}

static struct klp_func funcs[] = {
	{
		.old_name = "cmdline_proc_show",
		.new_func = evasive_lp1_cmdline_show,
	}, { }
};

static struct klp_object objs[] = {
	{
		/* .name = NULL → patches vmlinux */
		.funcs = funcs,
	}, { }
};

static struct klp_patch patch = {
	.mod = THIS_MODULE,
	.objs = objs,
	.replace = true,
};

static int lp1_init(void)
{
	pr_info("evasive-linux lp1: new_func at %px\n",
		evasive_lp1_cmdline_show);
	return klp_enable_patch(&patch);
}

static void lp1_exit(void) { }

module_init(lp1_init);
module_exit(lp1_exit);

MODULE_LICENSE("GPL");
MODULE_INFO(livepatch, "Y");
MODULE_DESCRIPTION("evasive-linux lp1 — first replacement of cmdline_proc_show");
