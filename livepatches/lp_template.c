// SPDX-License-Identifier: GPL-2.0
/*
 * lp_template.c — template for evasive-linux's continuous-rerandomization
 * + honey-trap livepatch modules. The build system materializes
 * lp_01.c, lp_02.c, ... lp_05.c by substituting @NN@ and @MSG@.
 *
 * Each module:
 *   1. Replaces cmdline_proc_show with its own copy (so /proc/cmdline
 *      reflects which patch is currently active).
 *   2. Atomic-replaces any previously-loaded evasive-linux patch
 *      (.replace = true).
 *   3. Optionally, if module-parameter `poison_addr` is non-zero,
 *      registers a kprobe-based honey-trap at that address — typically
 *      the previous patch's now-superseded replacement function.
 *      Any call to the superseded address fires the trap and logs the
 *      caller via pr_warn.
 *
 * License: GPL-2.0
 */
#include <linux/module.h>
#include <linux/printk.h>
#include <linux/seq_file.h>
#include <linux/livepatch.h>
#include <linux/kprobes.h>

static unsigned long poison_addr;
module_param(poison_addr, ulong, 0444);
MODULE_PARM_DESC(poison_addr,
		 "Kernel virtual address of the previous patch's "
		 "replacement function. If non-zero, a kprobe-based "
		 "honey-trap is armed at this address.");

static int evasive_trap_pre_handler(struct kprobe *p, struct pt_regs *regs)
{
	pr_warn("evasive-linux HONEY-TRAP: superseded patch @NN@ hit at %px "
		"(caller=%pS)\n",
		p->addr, (void *)regs->ip);
	return 0;
}

static struct kprobe evasive_trap_kp = {
	.pre_handler = evasive_trap_pre_handler,
};

static int evasive_lp_@NN@_cmdline_show(struct seq_file *m, void *v)
{
	seq_printf(m, "evasive-linux lp_@NN@ — @MSG@\n");
	return 0;
}

static struct klp_func funcs[] = {
	{
		.old_name = "cmdline_proc_show",
		.new_func = evasive_lp_@NN@_cmdline_show,
	}, { }
};

static struct klp_object objs[] = {
	{ .funcs = funcs }, { }
};

static struct klp_patch patch = {
	.mod = THIS_MODULE,
	.objs = objs,
	.replace = true,
};

static int __init lp_@NN@_init(void)
{
	int ret;

	pr_info("evasive-linux lp_@NN@: new_func at %px\n",
		evasive_lp_@NN@_cmdline_show);

	ret = klp_enable_patch(&patch);
	if (ret) {
		pr_err("evasive-linux lp_@NN@: klp_enable_patch() = %d\n", ret);
		return ret;
	}

	if (poison_addr) {
		evasive_trap_kp.addr = (kprobe_opcode_t *)poison_addr;
		ret = register_kprobe(&evasive_trap_kp);
		if (ret == 0) {
			pr_info("evasive-linux lp_@NN@: HONEY-TRAP armed at %px\n",
				(void *)poison_addr);
		} else {
			pr_warn("evasive-linux lp_@NN@: register_kprobe(%px) = %d\n",
				(void *)poison_addr, ret);
			/* Trap registration failure isn't fatal — the patch
			 * itself is already live; we just lose the tripwire on
			 * the previous generation. The most common cause of
			 * failure is CONFIG_KPROBES=n in the running kernel,
			 * which makes register_kprobe a -EOPNOTSUPP stub. */
			evasive_trap_kp.addr = NULL;
		}
	}
	return 0;
}

static void __exit lp_@NN@_exit(void)
{
	if (evasive_trap_kp.addr) {
		unregister_kprobe(&evasive_trap_kp);
		pr_info("evasive-linux lp_@NN@: HONEY-TRAP at %px disarmed\n",
			(void *)evasive_trap_kp.addr);
	}
}

module_init(lp_@NN@_init);
module_exit(lp_@NN@_exit);

MODULE_LICENSE("GPL");
MODULE_INFO(livepatch, "Y");
MODULE_DESCRIPTION("evasive-linux lp_@NN@ — @MSG@");
