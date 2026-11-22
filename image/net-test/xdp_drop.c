// SPDX-License-Identifier: GPL-2.0
/*
 * Drops every frame, for check-net.sh: attached with ip link xdpgeneric.
 * Each drop leaves a line in the trace buffer, through bpf_printk.
 */
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

SEC("xdp")
int xdp_drop(struct xdp_md *ctx)
{
	bpf_printk("KATHARA_UML_XDP len=%u", ctx->data_end - ctx->data);
	return XDP_DROP;
}

char _license[] SEC("license") = "GPL";
