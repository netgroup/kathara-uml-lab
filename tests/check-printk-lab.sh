#!/bin/bash
# bpf_printk from inside a Kathara UML device: a lab with one device, r,
# on a UML kernel built with patches/ and trace.fragment and on the image
# uml/image/printk-test. kathara exec loads the socket filter of prog.c in
# r, runs it once and reads its line from the trace buffer of r's kernel.
#
#   check-printk-lab.sh <UML kernel>
#
# Prints one OK/FAIL line per check and exits non-zero if one failed.
KERNEL=$(cd "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1")
[ -f "$KERNEL" ] || { echo "usage: $0 <UML kernel>" >&2; exit 1; }
fails=0
check() { if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }

docker build -q -t kathara-uml/printk-test "$(dirname "$0")/../image/printk-test" >/dev/null ||
	{ echo "FAIL test image"; exit 1; }

LAB=$(mktemp -d)
trap 'cd /; kathara lclean -d "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
cat > "$LAB/lab.conf" <<EOF
r[0]="A"
r[image]="kathara-uml/printk-test"
r[kernel]="$KERNEL"
EOF
cd "$LAB" || exit 1

kathara lstart --noterminals >/tmp/check-printk-lab-lstart.log 2>&1
check "lstart" "$?" 0
r=$(docker ps --format '{{.Names}}' | grep '_r_')
check "r is a UML device" "$(docker inspect "$r" --format '{{index .Config.Labels "uml"}}')" 1
uml=$(kathara exec r "uname -r" | tr -d '\r')
check "exec r runs in the UML kernel" "$([ -n "$uml" ] && [ "$uml" != "$(uname -r)" ] && echo yes)" yes

out=$(kathara exec r "bash -c '
	mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing
	bpftool prog load /printk/prog.o /sys/fs/bpf/printk_test || exit 1
	head -c 64 /dev/zero > /tmp/pkt
	bpftool prog run pinned /sys/fs/bpf/printk_test data_in /tmp/pkt repeat 1 >/dev/null
	sleep 1
	grep -m1 -o \"KATHARA_UML_PRINTK len=[0-9]*\" /sys/kernel/tracing/trace'" 2>&1 | tr -d '\r')
echo "     r ($uml): $out"
check "bpf_printk line in the trace buffer of r" "$(echo "$out" | grep -c '^KATHARA_UML_PRINTK len=[0-9]*$')" 1

echo "CHECK_PRINTK_LAB=$([ $fails = 0 ] && echo PASS || echo "FAIL ($fails)")"
exit $fails
