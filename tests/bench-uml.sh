#!/bin/bash
# Cost of running in a UML device: the same micro-tests in a plain
# container, then inside a UML kernel in the ptrace mode (seccomp=off,
# the kernel default) and in the seccomp mode (seccomp=on). The UML runs
# as in a Kathara UML device: in a container of the device image, with
# hostfs on the container's /.
#
#   bench-uml.sh <UML kernel> [image]     (image default kathara-uml/base-ssh)
#
# Prints lines "BENCH <where> <test> <seconds>". BENCH_RUNS (default 1)
# repeats the whole set, to see the spread.
KERNEL=$(cd "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1")
IMAGE=${2:-kathara-uml/base-ssh}
[ -f "$KERNEL" ] || { echo "usage: $0 <UML kernel> [image]" >&2; exit 1; }

# The tests: only dd, bash and awk, which every image has.
TESTS='
t() { local s=$(date +%s.%N); "$@" >/dev/null 2>&1; awk -v a=$s -v b=$(date +%s.%N) -v n="$BN" "BEGIN{printf \"BENCH %s %s %.3f\n\", ENVIRON[\"WHERE\"], n, b-a}"; }
BN=syscalls_200k t dd if=/dev/zero of=/dev/null bs=1 count=100000
BN=forkexec_300 t bash -c "for i in \$(seq 300); do /bin/true; done"
BN=pagefaults_200MB t dd if=/dev/zero of=/dev/null bs=200M count=1
BN=cpu_awk t awk "BEGIN{for (i = 0; i < 3000000; i++) s += i}"
'

echo "kernel: $KERNEL ($(uname -r) host side)"
for run in $(seq "${BENCH_RUNS:-1}"); do
echo "run $run"
docker run --rm -e WHERE=container "$IMAGE" bash -c "$TESTS"

for mode in off on; do
	# The tests run as the init of the UML, from a file that the UML sees
	# through hostfs. Same traps as the device helpers: the console goes to
	# a file and stdin stays open.
	docker run --rm -v "$KERNEL:/kathara-uml-kernel:ro" -e MODE=$mode -e TESTS="$TESTS" \
		--entrypoint bash "$IMAGE" -c '
		mkdir -p /tmp/uml && mkfifo /tmp/uml/stdin
		{ printf "#!/bin/bash\nmount -t proc proc /proc\nmount -t sysfs sysfs /sys\n"
		  printf "export PATH=/usr/sbin:/usr/bin:/sbin:/bin WHERE=uml-seccomp-%s\n" $MODE
		  printf "%s\n" "$TESTS"
		  printf "echo o > /proc/sysrq-trigger\nsleep 5\n"; } > /tmp/uml/init.sh
		chmod 755 /tmp/uml/init.sh
		sleep infinity > /tmp/uml/stdin &
		TMPDIR=/tmp/uml timeout 600 /kathara-uml-kernel mem=512M root=/dev/root rootfstype=hostfs \
			rootflags=/ rw init=/tmp/uml/init.sh con0=fd:0,fd:1 con=null seccomp=$MODE \
			< /tmp/uml/stdin > /tmp/uml/console.log 2>&1
		echo "uml exit $?" >> /tmp/uml/console.log
		tr -d "\r" < /tmp/uml/console.log | grep -a -E "^BENCH |seccomp|ptrace|not functional|uml exit"'
done
done
