#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# The failures of lstart for a UML device that cannot run: r on a file
# that is not a UML kernel, and on a UML kernel with too little memory,
# where its container exits (KATHARA_UML_MEM=4M) or, from one boot to the
# next, its kernel panics or its container exits (16M: in the tests both
# happened, while the memory that UML adds for the exec-shield gap, in its
# console, changed from boot to boot). Each lstart must fail with the
# reason, within seconds and not after the boot timeout of Kathara, and
# leave no container of r behind.
#
# It uses copies of examples/router in temporary directories, so a lab
# already running is not touched. Run it where Kathara is, for example in
# the test VM: `vm/vm.sh ssh bash /opt/kathara-uml/tests/check-boot.sh`.
#
#   check-boot.sh [UML kernel]   (default: out/kernel/linux)
#
# Prints one OK/FAIL line per check and exits non-zero if one failed.

# shellcheck source=lib.sh source-path=SCRIPTDIR
. "$(dirname "$0")/lib.sh"

HERE=$(cd "$(dirname "$0")" && pwd)
KERNEL=$(realpath "${1:-$HERE/../out/kernel/linux}")
# Well below the 120 s that Kathara waits for a UML kernel to boot.
MAX_TIME=60
LABS=()

# A copy of the router lab, with r on the kernel given and with the
# environment variable given, in NEW_LAB. It is not printed for a $(...):
# LABS, which clean_labs reads, must grow in this shell.
new_lab()
{
	local kernel=$1 env=$2

	NEW_LAB=$(mktemp -d)
	LABS+=("$NEW_LAB")
	cp -r "$HERE/../examples/router/." "$NEW_LAB"
	rm -f "$NEW_LAB/kernel"
	sed -i "s|^r\[kernel\]=.*|r[kernel]=\"$kernel\"|" "$NEW_LAB/lab.conf"
	if [ -n "$env" ]; then
		echo "r[env]=\"$env\"" >> "$NEW_LAB/lab.conf"
	fi
}

# shellcheck disable=SC2317 # called from the EXIT trap
clean_labs()
{
	local lab

	for lab in "${LABS[@]}"; do
		kathara lclean -d "$lab" >/dev/null 2>&1
		rm -rf "$lab"
	done
}

# yes if value is less than max, else no.
less_than()
{
	local value=$1 max=$2

	if awk -v v="$value" -v m="$max" 'BEGIN { exit !(v < m) }'; then
		echo yes
	else
		echo no
	fi
}

# lstart of NEW_LAB, which must fail: with the error, the words and, if
# given, the line of the UML console in its output, which Kathara wraps on
# several lines, and with no container of r left. words and console are
# extended regular expressions.
check_lstart_fails()
{
	local what=$1 error=$2 words=$3 console=$4 start out

	start=$(date +%s.%N)
	out=$(kathara lstart --noterminals -d "$NEW_LAB" 2>&1)
	check "$what: lstart fails" "$?" 1
	check "$what: lstart fails within $MAX_TIME s" "$(less_than "$(elapsed "$start")" "$MAX_TIME")" yes
	out=$(tr -s ' \n' ' ' <<< "$out")
	check "$what: the error is $error" "$(grep -c "($error)" <<< "$out")" 1
	check "$what: the error says \"$words\"" "$(grep -cE "$words" <<< "$out")" 1
	if [ -n "$console" ]; then
		check "$what: the error has \"$console\" of the console" "$(grep -cE "$console" <<< "$out")" 1
	fi
	check "$what: no container of r is left" "$(docker ps -a -q --filter label=name=r | wc -l)" 0
	kathara lclean -d "$NEW_LAB" >/dev/null 2>&1
}

if [ ! -f "$KERNEL" ]; then
	echo "usage: $0 [UML kernel]" >&2
	exit 1
fi
if [ -n "$(docker ps -q --filter label=app=kathara)" ]; then
	echo "a Kathara lab is running: its devices would be counted as left by this test" >&2
	exit 1
fi
trap clean_labs EXIT

new_lab "$HERE/../examples/router/lab.conf"
check_lstart_fails "not a kernel" MachineOptionError "it is not a UML kernel"
new_lab "$KERNEL" KATHARA_UML_MEM=4M
check_lstart_fails "4M of memory" MachineBootError "its container exited with code 1" "Too few physical memory!"
new_lab "$KERNEL" KATHARA_UML_MEM=16M
check_lstart_fails "16M of memory" MachineBootError "its kernel panicked|its container exited with code 1" \
	"Kernel panic - not syncing|Too few physical memory!"

finish BOOT
