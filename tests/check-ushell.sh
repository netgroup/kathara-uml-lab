#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# Test of the shell of a UML device, /kathara-uml/ushell, while the sshd
# of the UML cannot be reached and while its key is not there yet: a
# command must arrive once both are back, run once, and give back its exit
# code.
#
# It uses a copy of examples/router in a temporary directory, so a lab
# already running is not touched. Run it where Kathara is, for example in
# the test VM: `vm/vm.sh ssh bash /opt/kathara-uml/tests/check-ushell.sh`.
#
#   check-ushell.sh [UML kernel]   (default: out/kernel/linux)
#
# Prints one OK/FAIL line per check and exits non-zero if one failed.

# shellcheck source=lib.sh source-path=SCRIPTDIR
. "$(dirname "$0")/lib.sh"

HERE=$(cd "$(dirname "$0")" && pwd)
KERNEL=$(realpath "${1:-$HERE/../out/kernel/linux}")
SSHD="/usr/sbin/sshd -o ListenAddress=169.254.77.2 -o UseDNS=no -o PermitRootLogin=prohibit-password"
# An outage starts 1 s after the exec that sets it up returns, and the
# exec under test starts 1 s later: it waits at least OUTAGE - 2 s.
OUTAGE=10
MIN_WAIT=$((OUTAGE - 2))

# The container of r of this lab: the one that mounts its shared folder.
container_of_r()
{
	local c

	for c in $(docker ps -q --filter label=name=r); do
		if docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$c" | grep -q "$LAB/shared"; then
			echo "$c"
		fi
	done
}

# Run a command in the UML of r, without the \r of the terminal.
uml()
{
	kathara exec -d "$LAB" r "$1" | tr -d '\r'
}

# Run a script in the UML of r, detached from the exec that starts it: it
# keeps running when its ssh session ends or the management link goes down.
# kathara exec runs no shell, so the redirections go to a bash in the UML.
uml_detached()
{
	kathara exec -d "$LAB" r "bash -c \"setsid -f sh -c '$1' </dev/null >/dev/null 2>&1\"" >/dev/null 2>&1
}

# Time an exec issued while sshd cannot be reached, and check its output.
exec_during_outage()
{
	local what=$1 start out

	start=$(date +%s.%N)
	out=$(uml "echo answered")
	check "exec while $what" "$out" answered
	check_at_least "exec while $what waits for the end of the outage" "$(elapsed "$start")" "$MIN_WAIT"
}

setup_lab()
{
	LAB=$(mktemp -d)
	trap 'kathara lclean -d "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
	cp -r "$HERE/../examples/router/." "$LAB"
	rm -f "$LAB/kernel"
	sed -i "s|^r\[kernel\]=.*|r[kernel]=\"$KERNEL\"|" "$LAB/lab.conf"
}

if [ ! -f "$KERNEL" ]; then
	echo "usage: $0 [UML kernel]" >&2
	exit 1
fi

setup_lab
kathara lstart --noterminals -d "$LAB" >/dev/null 2>&1
check "lstart" "$?" 0
check "exec r before the outages" "$(uml "echo up")" up

# sshd gone, as before it starts at boot: the connect is refused.
uml_detached "sleep 1; kill \$(pgrep -o -x sshd); sleep $OUTAGE; $SSHD"
sleep 2
exec_during_outage "sshd is gone"

# The management link down: the connect gets no answer at all.
uml_detached "sleep 1; ip link set kmgmt down; sleep $OUTAGE; ip link set kmgmt up"
sleep 2
exec_during_outage "the management link is down"

# The key of ushell not there yet, as when Kathara runs the startup right
# after the start of the container. It comes back after OUTAGE s, the
# private key before the public one, as ssh-keygen writes them.
r=$(container_of_r)
keys=/var/lib/kathara-uml
docker exec "$r" sh -c "mv $keys/id $keys/id.away && mv $keys/id.pub $keys/id.pub.away"
(
	sleep "$OUTAGE"
	docker exec "$r" sh -c "mv $keys/id.away $keys/id && mv $keys/id.pub.away $keys/id.pub"
) &
sleep 1
exec_during_outage "the key of ushell is not there"
wait

# Exit codes come back, 255 too, and the command runs once.
kathara exec -d "$LAB" r "sh -c 'exit 7'" >/dev/null 2>&1
check "exit code 7" "$?" 7
kathara exec -d "$LAB" r "sh -c 'echo run >> /root/ushell-runs; exit 255'" >/dev/null 2>&1
check "exit code 255" "$?" 255
check "a command that exits with 255 runs once" "$(uml "bash -c 'wc -l < /root/ushell-runs'")" 1

finish USHELL
