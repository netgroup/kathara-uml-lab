#!/bin/bash
# bpf_printk from inside a Kathara UML device: a lab with one device, r,
# on a UML kernel built with patches/ and trace.fragment and on the image
# image/printk-test. kathara exec loads the socket filter of prog.c in
# r, runs it once and reads its line from the trace buffer of r's kernel.
#
#   check-printk-lab.sh <UML kernel>
#
# Prints one OK/FAIL line per check and exits non-zero if one failed.

# shellcheck source=lib.sh source-path=SCRIPTDIR
. "$(dirname "$0")/lib.sh"

IMAGE=kathara-uml/printk-test

if [ ! -f "$1" ]; then
	echo "usage: $0 <UML kernel>" >&2
	exit 1
fi
KERNEL=$(realpath "$1")

if ! docker build -q -t "$IMAGE" "$(dirname "$0")/../image/printk-test" >/dev/null; then
	echo "FAIL test image"
	exit 1
fi

LAB=$(mktemp -d)
trap 'cd /; kathara lclean -d "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
cat > "$LAB/lab.conf" <<EOF
r[0]="A"
r[image]="$IMAGE"
r[kernel]="$KERNEL"
EOF
cd "$LAB" || exit 1

kathara lstart --noterminals >/tmp/check-printk-lab-lstart.log 2>&1
check "lstart" "$?" 0
r=$(docker ps --format '{{.Names}}' | grep '_r_')
check "r is a UML device" "$(docker inspect "$r" --format '{{index .Config.Labels "uml"}}')" 1
uml=$(kathara exec r "uname -r" | tr -d '\r')
check "exec r runs in the UML kernel" "$(other_kernel "$uml")" yes

out=$(kathara exec r "bash -c '
	mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing
	bpftool prog load /printk/prog.o /sys/fs/bpf/printk_test || exit 1
	head -c 64 /dev/zero > /tmp/pkt
	bpftool prog run pinned /sys/fs/bpf/printk_test data_in /tmp/pkt repeat 1 >/dev/null
	sleep 1
	grep -m1 -o \"KATHARA_UML_PRINTK len=[0-9]*\" /sys/kernel/tracing/trace'" 2>&1 | tr -d '\r')
echo "     r ($uml): $out"
check "bpf_printk line in the trace buffer of r" "$(echo "$out" | grep -c '^KATHARA_UML_PRINTK len=[0-9]*$')" 1

finish PRINTK_LAB
