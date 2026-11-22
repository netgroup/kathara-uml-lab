# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# Helpers shared by the tests, sourced by them:
#
#   . "$(dirname "$0")/lib.sh"
#
# A test calls check for each result, then finish, which prints
# CHECK_<NAME>=PASS or FAIL and exits with the number of failed checks.

fails=0

# Prints OK or FAIL for one check and counts the failures.
check()
{
	local what=$1 got=$2 want=$3

	if [ "$got" = "$want" ]; then
		echo "OK   $what"
	else
		echo "FAIL $what: got '$got', want '$want'"
		fails=$((fails + 1))
	fi
}

# As check, for a time in seconds that must be at least min.
check_at_least()
{
	local what=$1 got=$2 min=$3

	if awk -v g="$got" -v m="$min" 'BEGIN { exit !(g >= m) }'; then
		echo "OK   $what ($got s)"
	else
		echo "FAIL $what: took $got s, want at least $min s"
		fails=$((fails + 1))
	fi
}

# The seconds since start, a value of date +%s.%N, with one decimal.
elapsed()
{
	local start=$1

	awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }'
}

# yes if the kernel release given is set and is not the one of this host:
# a command that printed it ran on another kernel, a UML one.
other_kernel()
{
	local release=$1

	if [ -n "$release" ] && [ "$release" != "$(uname -r)" ]; then
		echo yes
	else
		echo "no ($release)"
	fi
}

# Runs a command until it succeeds, up to tries times, interval s apart.
# Returns non-zero if it never succeeded.
wait_until()
{
	local tries=$1 interval=$2

	shift 2
	while ! "$@" >/dev/null 2>&1; do
		tries=$((tries - 1))
		if [ "$tries" -le 0 ]; then
			return 1
		fi
		sleep "$interval"
	done
}

# Prints the result of the test and exits with the number of failures.
finish()
{
	local name=$1

	if [ "$fails" = 0 ]; then
		echo "CHECK_$name=PASS"
	else
		echo "CHECK_$name=FAIL ($fails)"
	fi
	exit "$fails"
}
