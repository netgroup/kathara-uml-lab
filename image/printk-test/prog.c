// SPDX-License-Identifier: GPL-2.0
/* A socket filter that calls bpf_printk(): the tests run it once with
 * BPF_PROG_TEST_RUN and look for its line in the trace buffer.
 */
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

SEC("socket")
int printk_test(struct __sk_buff *skb)
{
	bpf_printk("KATHARA_UML_PRINTK len=%u", skb->len);
	return 0;
}

char _license[] SEC("license") = "GPL";
