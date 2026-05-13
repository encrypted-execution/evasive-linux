// SPDX-License-Identifier: GPL-2.0
/*
 * attacker.c — minimal "kernel attacker" module for demo 03b.
 *
 * Simulates an attacker who held a code pointer to a function before
 * it was superseded by an atomic-replace livepatch transition. The
 * attacker reaches for that stale pointer — and if evasive-linux has
 * armed a kprobe-based honey-trap there, the trap fires and the
 * intrusion is logged.
 *
 * Loaded as:   insmod attacker.ko addr=0xffffffffXXXXXXXX
 *
 * The call is dispatched from a kthread so a fault inside the stale
 * function doesn't kill init.
 *
 * License: GPL-2.0
 */
#include <linux/module.h>
#include <linux/printk.h>
#include <linux/kthread.h>

static unsigned long addr;
module_param(addr, ulong, 0444);
MODULE_PARM_DESC(addr, "Stale kernel-text address to invoke");

static struct task_struct *attacker_task;

static int attacker_thread(void *data)
{
	int (*fn)(void *, void *);

	fn = (int (*)(void *, void *))addr;
	pr_info("attacker: dispatching call to %px ...\n", (void *)addr);
	/* This invocation should trip the honey-trap kprobe registered by
	 * a later livepatch generation at the same address. The bad-args
	 * call (NULL, NULL) will probably oops *after* the kprobe fires
	 * because the superseded cmdline_proc_show body dereferences its
	 * seq_file argument; that's fine — the trap log already arrived,
	 * and the oops is isolated to this kthread, not init. */
	(void)fn(NULL, NULL);
	pr_info("attacker: call to %px returned normally\n", (void *)addr);
	return 0;
}

static int __init attacker_init(void)
{
	if (!addr) {
		pr_err("attacker: addr= parameter is required\n");
		return -EINVAL;
	}
	attacker_task = kthread_run(attacker_thread, NULL,
				    "evasive-attacker");
	if (IS_ERR(attacker_task))
		return PTR_ERR(attacker_task);
	return 0;
}

static void __exit attacker_exit(void) { }

module_init(attacker_init);
module_exit(attacker_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("evasive-linux: simulated stale-pointer attacker for demo 03b");
