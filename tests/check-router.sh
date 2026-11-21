#!/bin/bash
# Test of a UML device with the example lab uml/examples/router (a and b
# are containers, r runs on its own UML kernel). Run it where Kathara and
# the lab are, for example in the test VM: `uml/vm/vm.sh test`.
#
#   check-router.sh [lab dir]     (default: ../examples/router)
#
# Prints one OK/FAIL line per check and exits non-zero if one failed.
LAB=${1:-$(dirname "$0")/../examples/router}
cd "$LAB" || exit 1
fails=0
check() { if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
elapsed() { awk -v a="$1" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}'; }

kathara lclean >/dev/null 2>&1
s=$(date +%s.%N)
kathara lstart --noterminals >/tmp/check-router-lstart.log 2>&1
check "lstart" "$?" 0
echo "     lstart took $(elapsed "$s") s"
r=$(docker ps --format '{{.Names}}' | grep '_r_')

# Kathara sets the device up as a UML device, without privileged mode.
check "r is a UML device" "$(docker inspect "$r" --format '{{index .Config.Labels "uml"}}')" 1
check "r is not privileged" "$(docker inspect "$r" --format '{{.HostConfig.Privileged}}')" false
# Which mode UML runs its processes in (seccomp=auto: seccomp if it works).
for i in $(seq 60); do docker exec "$r" grep -q 'Run /kathara-uml/init' /var/log/uml-console.log 2>/dev/null && break; sleep 0.5; done
if docker exec "$r" grep -q 'seccomp filters can be installed...OK' /var/log/uml-console.log; then
	echo "     UML mode of r: seccomp"
else
	echo "     UML mode of r: ptrace"
fi

# exec reaches the UML kernel of r; a keeps the kernel of the host.
uml=$(kathara exec r "uname -r" | tr -d '\r')
host=$(uname -r)
check "exec r runs in the UML kernel" "$([ -n "$uml" ] && [ "$uml" != "$host" ] && echo yes)" yes
check "exec a runs in the host kernel" "$(kathara exec a "uname -r" | tr -d '\r')" "$host"
kathara exec r "sh -c 'exit 5'" >/dev/null 2>&1
check "exit code of exec r" "$?" 5

# r.startup ran inside the UML and configured its interfaces. Kathara
# runs it with `set -x`: the output line is the one that starts with it.
for i in $(seq 60); do docker exec "$r" test -f /tmp/EOS 2>/dev/null && break; sleep 0.5; done
check "r.startup ran in the UML" "$(docker exec "$r" grep -c "^r.startup ran on $uml\$" /var/log/startup.log)" 1
check "eth0 of r has 10.0.1.2" "$(kathara exec r "ip -br addr show eth0" | grep -c 10.0.1.2/24)" 1
check "eth0 of the container r has no address" "$(docker exec "$r" ip -br -4 addr show eth0 | grep -c inet)" 0

# a reaches b through the UML router.
check "ping a -> b through r" "$(kathara exec a "ping -c 5 -i 0.3 -W 2 10.0.2.1" | grep -o '5 received')" "5 received"
check "first hop is r" "$(kathara exec a "traceroute -n -m 1 10.0.2.1" | awk 'NR == 2 {print $2}')" 10.0.1.2

# connect opens a shell in the UML.
{ sleep 6; printf 'echo KMARK $(uname -r)\nexit\n'; sleep 3; } |
	timeout 30 script -qec 'kathara connect r' /dev/null > /tmp/check-router-connect.log 2>&1
check "connect r opens a shell in the UML" \
	"$(tr -d '\r' < /tmp/check-router-connect.log | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -c "^KMARK $uml")" 1

s=$(date +%s.%N)
kathara lclean >/dev/null 2>&1
check "lclean" "$?" 0
echo "     lclean took $(elapsed "$s") s"
check "no device left" "$(docker ps -a --format '{{.Names}}' | grep -c '^kathara_')" 0

echo "CHECK_ROUTER=$([ $fails = 0 ] && echo PASS || echo "FAIL ($fails)")"
exit $fails
