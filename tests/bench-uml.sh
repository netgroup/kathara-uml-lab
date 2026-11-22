#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# Cost of running in a UML device: the micro-tests of bench-tests.sh in a
# plain container, then inside a UML kernel in the ptrace mode
# (seccomp=off, the kernel default) and in the seccomp mode (seccomp=on).
# The UML runs as in a Kathara UML device: in a container of the device
# image, with hostfs on the container's / (tests/uml-run.sh).
#
#   bench-uml.sh <UML kernel> [image]     (image default kathara/base)
#
# Prints lines "BENCH <where> <test> <seconds>". BENCH_RUNS (default 1)
# repeats the whole set, to see the spread.

TESTS=$(cd "$(dirname "$0")" && pwd)
IMAGE=${2:-kathara/base}

in_container()
{
	docker run --rm -e WHERE=container -v "$TESTS:/tests:ro" "$IMAGE" \
		bash /tests/bench-tests.sh
}

# The console lines worth keeping: the results, the mode UML took, and the
# exit status of the UML.
in_uml()
{
	local mode=$1

	docker run --rm -v "$KERNEL:/kathara-uml-kernel:ro" -v "$TESTS:/tests:ro" \
		-e UML_MEM=512M -e UML_SECCOMP="$mode" -e UML_TIMEOUT=600 \
		--entrypoint /tests/uml-run.sh "$IMAGE" \
		env WHERE="uml-seccomp-$mode" bash /tests/bench-tests.sh |
		grep -a -E '^BENCH |seccomp|ptrace|not functional|uml exit'
}

if [ ! -f "$1" ]; then
	echo "usage: $0 <UML kernel> [image]" >&2
	exit 1
fi
KERNEL=$(realpath "$1")

echo "kernel: $KERNEL ($(uname -r) host side)"
for run in $(seq "${BENCH_RUNS:-1}"); do
	echo "run $run"
	in_container
	for mode in off on; do
		in_uml "$mode"
	done
done
