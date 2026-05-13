// SPDX-License-Identifier: GPL-2.0
/*
 * lp2.c — second of two evasive-linux livepatch modules.
 *
 * Loaded after lp1.ko, this replaces cmdline_proc_show again. Because
 * .replace = true (atomic-replace), the kernel disables lp1's
 * redirection and installs lp2's in a single transition. On init,
 * prints the address of *its* replacement function. Comparing this to
 * lp1's logged address proves that consecutive patches put their
 * replacement bodies at distinct addresses — the foundational property
 * we need for continuous code re-randomization.
 *
 * License: GPL-2.0
 */
#include <linux/module.h>
#include <linux/printk.h>
#include <linux/seq_file.h>
#include <linux/livepatch.h>

static int evasive_lp2_cmdline_show(struct seq_file *m, void *v)
{
	seq_printf(m, "evasive-linux lp2 — patch #2\n");
	return 0;
}

static struct klp_func funcs[] = {
	{
		.old_name = "cmdline_proc_show",
		.new_func = evasive_lp2_cmdline_show,
	}, { }
};

static struct klp_object objs[] = {
	{
		.funcs = funcs,
	}, { }
};

static struct klp_patch patch = {
	.mod = THIS_MODULE,
	.objs = objs,
	.replace = true,
};

static int lp2_init(void)
{
	pr_info("evasive-linux lp2: new_func at %px\n",
		evasive_lp2_cmdline_show);
	return klp_enable_patch(&patch);
}

static void lp2_exit(void) { }

module_init(lp2_init);
module_exit(lp2_exit);

MODULE_LICENSE("GPL");
MODULE_INFO(livepatch, "Y");
MODULE_DESCRIPTION("evasive-linux lp2 — second replacement of cmdline_proc_show");
