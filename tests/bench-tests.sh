#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# The micro-tests of bench-uml.sh, with only dd, bash and awk, which every
# image has. Prints one line "BENCH <where> <test> <seconds>" per test;
# <where> is WHERE from the environment.

WHERE=${WHERE:-unknown}

# Runs a command, without its output, and prints how long it took.
bench()
{
	local name=$1 start

	shift
	start=$(date +%s.%N)
	"$@" >/dev/null 2>&1
	awk -v a="$start" -v b="$(date +%s.%N)" -v w="$WHERE" -v n="$name" \
		'BEGIN { printf "BENCH %s %s %.3f\n", w, n, b - a }'
}

bench syscalls_200k dd if=/dev/zero of=/dev/null bs=1 count=100000
# shellcheck disable=SC2016 # the loop is for the bash under test
bench forkexec_300 bash -c 'for i in $(seq 300); do /bin/true; done'
bench pagefaults_200MB dd if=/dev/zero of=/dev/null bs=200M count=1
bench cpu_awk awk 'BEGIN { for (i = 0; i < 3000000; i++) s += i }'
