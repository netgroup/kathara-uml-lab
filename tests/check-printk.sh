#!/bin/bash
# bpf_printk in a UML kernel: load a socket filter that calls bpf_printk,
# run it once with BPF_PROG_TEST_RUN and look for its line in tracefs.
# With a kernel built with patches/ and trace.fragment the line must be
# there; without the patch (BPF_SYSCALL and tracing still on) the verifier
# refuses the program because of the helper. Run it where
# Docker is, for example in the test VM: `vm/vm.sh ssh bash ...`.
#
#   check-printk.sh <UML kernel> [expect: printk|refused]   (default printk)
#
# The test image (image/printk-test) adds bpftool and clang to the
# device image and builds prog.c in it.
KERNEL=$(cd "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1")
EXPECT=${2:-printk}
[ -f "$KERNEL" ] || { echo "usage: $0 <UML kernel> [printk|refused]" >&2; exit 1; }
IMAGE=kathara-uml/printk-test

docker build -q -t $IMAGE "$(dirname "$0")/../image/printk-test" >/dev/null ||
	{ echo "FAIL test image"; exit 1; }

# The UML runs the test as its init, from a file it sees through hostfs;
# its console goes to a file and its stdin stays open (see README.md).
out=$(docker run --rm -v "$KERNEL:/kathara-uml-kernel:ro" --entrypoint bash $IMAGE -c '
	mkdir -p /tmp/uml && mkfifo /tmp/uml/stdin
	cat > /tmp/uml/init.sh <<EOS
#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
mount -t proc proc /proc; mount -t sysfs sysfs /sys
mount -t tracefs tracefs /sys/kernel/tracing; mount -t bpf bpf /sys/fs/bpf
echo "UML \$(uname -r)"
if bpftool -d prog load /printk/prog.o /sys/fs/bpf/printk_test 2>/tmp/uml/load.err; then
	echo LOAD_OK
	head -c 64 /dev/zero > /tmp/uml/pkt
	bpftool prog run pinned /sys/fs/bpf/printk_test data_in /tmp/uml/pkt repeat 1
	sleep 1
	grep -m1 -o "KATHARA_UML_PRINTK len=[0-9]*" /sys/kernel/tracing/trace
else
	echo LOAD_REFUSED
	grep -m1 "cannot use helper" /tmp/uml/load.err | sed "s/^/LOAD_ERR /"
fi
echo o > /proc/sysrq-trigger
sleep 5
EOS
	chmod 755 /tmp/uml/init.sh
	sleep infinity > /tmp/uml/stdin &
	TMPDIR=/tmp/uml timeout 300 /kathara-uml-kernel mem=256M root=/dev/root rootfstype=hostfs \
		rootflags=/ rw init=/tmp/uml/init.sh con0=fd:0,fd:1 con=null seccomp=auto \
		< /tmp/uml/stdin > /tmp/uml/console.log 2>&1
	tr -d "\r" < /tmp/uml/console.log | grep -a -E "^(UML |LOAD_|KATHARA_UML_PRINTK)"')
echo "$out"

case "$EXPECT" in
printk) echo "$out" | grep -q '^KATHARA_UML_PRINTK len=[0-9]*$' ;;
refused) echo "$out" | grep -q '^LOAD_ERR .*cannot use helper bpf_trace_printk' ;;
esac
rc=$?
echo "CHECK_PRINTK=$([ $rc = 0 ] && echo PASS || echo FAIL) (expected $EXPECT)"
exit $rc
