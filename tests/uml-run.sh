#!/bin/bash
# Boots the UML kernel /kathara-uml-kernel in this container, on the
# container's own / (hostfs) as in a UML device, runs a command as its
# init and prints the console of the UML. For the tests that need a UML
# but no Kathara lab, run in a container that mounts the kernel there:
#
#   docker run --rm -v <kernel>:/kathara-uml-kernel:ro -v <tests>:/tests:ro \
#           --entrypoint /tests/uml-run.sh <image> <command> [args...]
#
# UML_MEM (default 256M), UML_SECCOMP (default auto) and UML_TIMEOUT (in
# seconds, default 300) set the memory, the seccomp= option and how long
# the UML may run. The last line is "uml exit <status>".
#
# As in a UML device, the console goes to a file and stdin stays open:
# with a pipe on stdout or stdin at EOF the UML boot stops.

UML_TMP=/tmp/uml
CONSOLE_IN=$UML_TMP/stdin
CONSOLE_OUT=$UML_TMP/console.log
INIT=$UML_TMP/init.sh

# The init of the UML: the filesystems the tests use, the release of the
# kernel, the command, then a power off, so that the UML process ends.
write_init()
{
	# shellcheck disable=SC2016 # $(uname -r) is for the init of the UML
	{
		echo '#!/bin/bash'
		echo 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin'
		echo 'mount -t proc proc /proc'
		echo 'mount -t sysfs sysfs /sys'
		echo 'mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null'
		echo 'mount -t bpf bpf /sys/fs/bpf 2>/dev/null'
		echo 'echo "UML $(uname -r)"'
		printf '%q ' "$@"
		echo
		echo 'echo o > /proc/sysrq-trigger'
		echo 'sleep 5'
	} > "$INIT"
	chmod 755 "$INIT"
}

if [ $# = 0 ]; then
	echo "usage: $0 <command> [args...]" >&2
	exit 1
fi

mkdir -p "$UML_TMP"
write_init "$@"
rm -f "$CONSOLE_IN"
mkfifo "$CONSOLE_IN"
sleep infinity > "$CONSOLE_IN" &

TMPDIR="$UML_TMP" timeout "${UML_TIMEOUT:-300}" /kathara-uml-kernel mem="${UML_MEM:-256M}" \
	root=/dev/root rootfstype=hostfs rootflags=/ rw init="$INIT" \
	con0=fd:0,fd:1 con=null seccomp="${UML_SECCOMP:-auto}" \
	< "$CONSOLE_IN" > "$CONSOLE_OUT" 2>&1
status=$?

tr -d '\r' < "$CONSOLE_OUT"
echo "uml exit $status"
