#!/bin/bash
# The lab's shared folder (/shared) seen by a container device (a) and by
# a UML device (r, through hostfs), with writes from the host side and
# from inside the UML. Uses examples/router.
#
#   check-shared.sh [lab dir]     (default: ../examples/router)
#
# Each read is a new process (cat, ls): a file kept open or mapped in the
# UML while the host changes it is not tested (see README.md).

# shellcheck source=lib.sh source-path=SCRIPTDIR
. "$(dirname "$0")/lib.sh"

LAB=${1:-$(dirname "$0")/../examples/router}

# A command in r or in a. kathara exec runs it without a shell, so pipes
# need bash -c.
in_r()
{
	kathara exec r "bash -c \"$1\"" 2>&1 | tr -d '\r'
}

in_a()
{
	kathara exec a "bash -c \"$1\"" 2>&1 | tr -d '\r'
}

cd "$LAB" || exit 1
LAB=$(pwd)
H=$LAB/shared

kathara lclean >/dev/null 2>&1
rm -rf "$H"
mkdir -p "$H"
kathara lstart --noterminals >/tmp/check-shared-lstart.log 2>&1
check "lstart" "$?" 0

echo v1 > "$H/f"
check "host creates, UML reads" "$(in_r 'cat /shared/f')" v1
check "host creates, container reads" "$(in_a 'cat /shared/f')" v1

echo v2-longer > "$H/f"
check "host rewrites in place, UML reads" "$(in_r 'cat /shared/f')" v2-longer
sleep 5
check "same, 5 s later" "$(in_r 'cat /shared/f')" v2-longer

echo v3 >> "$H/f"
check "host appends, UML reads" "$(in_r 'cat /shared/f | paste -sd,')" v2-longer,v3

echo v4 > "$H/f.new"
mv "$H/f.new" "$H/f"
check "host replaces (new inode), UML reads" "$(in_r 'cat /shared/f')" v4

touch "$H/n1"
check "host creates n1, UML lists" "$(in_r 'ls /shared | paste -sd,')" f,n1
rm "$H/n1"
check "host removes n1, UML lists" "$(in_r 'ls /shared | paste -sd,')" f

in_r 'echo u1 > /shared/g' >/dev/null
check "UML creates, host reads" "$(cat "$H/g")" u1
check "UML creates, container reads" "$(in_a 'cat /shared/g')" u1
in_r 'echo u2-longer > /shared/g' >/dev/null
check "UML rewrites, host reads" "$(cat "$H/g")" u2-longer
in_r 'echo u3 >> /shared/g' >/dev/null
check "UML appends, host reads" "$(paste -sd, "$H/g")" u2-longer,u3

in_r 'dd if=/dev/urandom of=/shared/big bs=1M count=10 status=none' >/dev/null
check "UML writes 10 MB, same sha256 on the host" \
	"$(in_r 'sha256sum /shared/big' | cut -d' ' -f1)" "$(sha256sum "$H/big" | cut -d' ' -f1)"

kathara lclean >/dev/null 2>&1
check "lclean" "$?" 0
rm -rf "$H"

finish SHARED
