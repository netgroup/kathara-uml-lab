#!/bin/bash
# Runs inside a UML: loads the socket filter of prog.c, runs it once with
# BPF_PROG_TEST_RUN and prints its bpf_printk line from the trace buffer.
# If the verifier refuses the program, prints LOAD_REFUSED and the line of
# the verifier that says why, and exits with 1.

TRACE=/sys/kernel/tracing
PIN=/sys/fs/bpf/printk_test

if ! mountpoint -q "$TRACE"; then
	mount -t tracefs tracefs "$TRACE"
fi

if ! bpftool -d prog load /printk/prog.o "$PIN" 2>/tmp/printk-load.err; then
	echo LOAD_REFUSED
	grep -m1 "cannot use helper" /tmp/printk-load.err | sed 's/^/LOAD_ERR /'
	exit 1
fi
echo LOAD_OK

head -c 64 /dev/zero > /tmp/printk-packet
bpftool prog run pinned "$PIN" data_in /tmp/printk-packet repeat 1 >/dev/null
sleep 1
grep -m1 -o "KATHARA_UML_PRINTK len=[0-9]*" "$TRACE/trace"
