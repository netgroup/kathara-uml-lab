#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# tc, netfilter and XDP inside a UML device. In a copy of the router lab,
# r runs on a UML kernel built with net.fragment and trace.fragment, and
# on the image image/net-test; each check changes, inside the UML of r,
# how r forwards the pings from a to b, looks at the pings, and puts r
# back. The eBPF programs of tc and XDP also write, with bpf_printk, a
# line per drop in the trace buffer of the UML.
#
# It uses a copy of examples/router in a temporary directory, so a lab
# already running is not touched. Run it where Kathara is, for example in
# the test VM: `vm/vm.sh ssh bash /opt/kathara-uml/tests/check-net.sh`.
#
#   check-net.sh [UML kernel]   (default: uml-kernel/prebuilt/linux)
#
# Prints one OK/FAIL line per check and exits non-zero if one failed.

# shellcheck source=lib.sh source-path=SCRIPTDIR
. "$(dirname "$0")/lib.sh"

HERE=$(cd "$(dirname "$0")" && pwd)
KERNEL=$(realpath "${1:-$HERE/../uml-kernel/prebuilt/linux}")
IMAGE=kathara-uml/net-test

setup_lab()
{
	LAB=$(mktemp -d)
	trap 'kathara lclean -d "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
	cp -r "$HERE/../examples/router/." "$LAB"
	rm -f "$LAB/kernel"
	sed -i "s|^r\[kernel\]=.*|r[kernel]=\"$KERNEL\"|; s|^r\[image\]=.*|r[image]=\"$IMAGE\"|" "$LAB/lab.conf"
}

# A command in the UML of r, through bash.
in_r()
{
	kathara exec -d "$LAB" r "bash -c '$1'" 2>&1 | tr -d '\r'
}

# How many lines with marker the trace buffer of the UML of r holds.
trace_lines()
{
	in_r "mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing; grep -c $1 /sys/kernel/tracing/trace"
}

# How many of 3 pings from a reach b through r and come back.
pings_through_r()
{
	kathara exec -d "$LAB" a "ping -c 3 -i 0.3 -W 1 10.0.2.1" | grep -o '[0-9]* received' | cut -d' ' -f1
}

# The average round trip, in ms, of 3 pings from a to b.
round_trip()
{
	kathara exec -d "$LAB" a "ping -c 3 -i 0.3 -W 2 10.0.2.1" | awk -F/ '/^rtt/ { print $5 }'
}

# yes if value is a number and at least min, else no. A value that is not
# a number, such as the error of a command, is no: awk would compare it
# with min as a string.
at_least()
{
	local value=$1 min=$2

	if [[ $value =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v v="$value" -v m="$min" 'BEGIN { exit !(v >= m) }'; then
		echo yes
	else
		echo no
	fi
}

check_tc_netem()
{
	in_r "tc qdisc add dev eth1 root netem delay 200ms"
	check "tc netem on eth1 delays the pings by 200 ms" "$(at_least "$(round_trip)" 200)" yes
	in_r "tc qdisc del dev eth1 root"
	check "pings without netem are not delayed" "$(at_least "$(round_trip)" 200)" no
}

check_tc_bpf()
{
	in_r "tc qdisc add dev eth0 clsact"
	in_r "tc filter add dev eth0 ingress bpf bytecode \"1,6 0 0 4294967295\" action drop"
	check "tc classic BPF filter on eth0 drops the pings" "$(pings_through_r)" 0
	in_r "tc filter del dev eth0 ingress"
	check "pings after the classic BPF filter" "$(pings_through_r)" 3
	in_r "tc filter add dev eth0 ingress bpf da obj /net/tc_drop.o sec tc"
	check "tc eBPF filter on eth0 drops the pings" "$(pings_through_r)" 0
	check "bpf_printk of the tc program in the trace buffer" "$(at_least "$(trace_lines KATHARA_UML_TC)" 1)" yes
	in_r "tc filter del dev eth0 ingress"
	in_r "tc qdisc del dev eth0 clsact"
	check "pings after the eBPF filter" "$(pings_through_r)" 3
}

check_xdp()
{
	in_r "ip link set dev eth0 xdpgeneric obj /net/xdp_drop.o sec xdp"
	check "generic XDP program on eth0 drops the pings" "$(pings_through_r)" 0
	check "bpf_printk of the XDP program in the trace buffer" "$(at_least "$(trace_lines KATHARA_UML_XDP)" 1)" yes
	in_r "ip link set dev eth0 xdpgeneric off"
	check "pings after the XDP program" "$(pings_through_r)" 3
}

check_iptables()
{
	local translated

	in_r "iptables -A FORWARD -p icmp -j DROP"
	check "iptables FORWARD rule drops the pings" "$(pings_through_r)" 0
	in_r "iptables -D FORWARD -p icmp -j DROP"
	check "pings after the FORWARD rule" "$(pings_through_r)" 3
	in_r "iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE"
	check "pings through the MASQUERADE of eth1" "$(pings_through_r)" 3
	translated=$(in_r "iptables -t nat -L POSTROUTING -v -n -x" | awk '/MASQUERADE/ { print $1 }')
	check "MASQUERADE counted the pings" "$(at_least "${translated:-0}" 1)" yes
	in_r "iptables -t nat -D POSTROUTING -o eth1 -j MASQUERADE"
}

if [ ! -f "$KERNEL" ]; then
	echo "usage: $0 [UML kernel]" >&2
	exit 1
fi

if ! docker build -q -t "$IMAGE" "$HERE/../image/net-test" >/dev/null; then
	echo "FAIL test image"
	exit 1
fi

setup_lab
kathara lstart --noterminals -d "$LAB" >/dev/null 2>&1
check "lstart" "$?" 0
wait_until 60 1 docker exec "$(docker ps -q --filter label=name=r --filter label=uml=1)" test -f /tmp/EOS
check "pings through r" "$(pings_through_r)" 3

check_tc_netem
check_tc_bpf
check_xdp
check_iptables

finish NET
