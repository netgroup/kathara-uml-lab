#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# bpf_printk in a UML kernel, without a Kathara lab: the UML boots in a
# container of image/printk-test (tests/uml-run.sh) and runs its run.sh,
# which loads a socket filter that calls bpf_printk, runs it once and looks
# for its line in tracefs. With a kernel built with patches/ and
# trace.fragment the line must be there; without the patch (BPF_SYSCALL
# and tracing still on) the verifier refuses the program because of the
# helper. Run it where Docker is, for example in the test VM:
# `vm/vm.sh ssh bash ...`.
#
#   check-printk.sh <UML kernel> [expect: printk|refused]   (default printk)

# shellcheck source=lib.sh source-path=SCRIPTDIR
. "$(dirname "$0")/lib.sh"

TESTS=$(cd "$(dirname "$0")" && pwd)
IMAGE=kathara-uml/printk-test
EXPECT=${2:-printk}

usage()
{
	echo "usage: $0 <UML kernel> [printk|refused]" >&2
	exit 1
}

if [ ! -f "$1" ]; then
	usage
fi
KERNEL=$(realpath "$1")

if ! docker build -q -t "$IMAGE" "$TESTS/../image/printk-test" >/dev/null; then
	echo "FAIL test image"
	exit 1
fi

out=$(docker run --rm -v "$KERNEL:/kathara-uml-kernel:ro" -v "$TESTS:/tests:ro" \
	--entrypoint /tests/uml-run.sh "$IMAGE" /printk/run.sh |
	grep -a -E '^(UML |LOAD_|KATHARA_UML_PRINTK)')
echo "$out"

case "$EXPECT" in
printk)
	check "bpf_printk line in the trace buffer" \
		"$(grep -c '^KATHARA_UML_PRINTK len=[0-9]*$' <<< "$out")" 1
	;;
refused)
	check "program refused because of the helper" \
		"$(grep -c '^LOAD_ERR .*cannot use helper bpf_trace_printk' <<< "$out")" 1
	;;
*)
	usage
	;;
esac

finish PRINTK
