#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# The settings of Kathara on a UML device against the same settings on a
# container device: a is a container, r a UML device, both with the same
# sysctl, env, shell, ulimit, bridged and port options and a MAC address
# on eth0. What each device sees must match, and the entrypoint option
# must be refused with kernel.
#
# It uses copies of examples/router in temporary directories, so a lab
# already running is not touched. Run it where Kathara is, for example in
# the test VM: `vm/vm.sh ssh bash /opt/kathara-uml/tests/check-settings.sh`.
#
#   check-settings.sh [UML kernel]   (default: uml-kernel/prebuilt/linux)
#
# Prints one OK/FAIL line per check and exits non-zero if one failed.

# shellcheck source=lib.sh source-path=SCRIPTDIR
. "$(dirname "$0")/lib.sh"

HERE=$(cd "$(dirname "$0")" && pwd)
KERNEL=$(realpath "${1:-$HERE/../uml-kernel/prebuilt/linux}")
SYSCTLS=(net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter
	net.ipv4.conf.lo.rp_filter net.ipv4.icmp_ratelimit net.ipv6.conf.all.forwarding
	net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6
	net.ipv4.tcp_syncookies net.ipv4.conf.eth0.rp_filter)
LABS=()

# A copy of the router lab, with its kernel given by path, in NEW_LAB. It
# is not printed for a $(...): LABS, which clean_labs reads, must grow in
# this shell.
new_lab()
{
	NEW_LAB=$(mktemp -d)
	LABS+=("$NEW_LAB")
	cp -r "$HERE/../examples/router/." "$NEW_LAB"
	rm -f "$NEW_LAB/kernel"
	sed -i "s|^r\[kernel\]=.*|r[kernel]=\"$KERNEL\"|" "$NEW_LAB/lab.conf"
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

# The same options on a and r, each with its own published port, and
# startup lines that record what the startup sees and start an HTTP server
# on port 80.
add_options()
{
	local lab=$1 device d port

	for device in "a 8091" "r 8092"; do
		read -r d port <<< "$device"
		cat >> "$lab/lab.conf" <<EOF
${d}[sysctl]="net.ipv4.tcp_syncookies=0"
${d}[sysctl]="net.ipv4.conf.eth0.rp_filter=2"
${d}[env]="GREETING=hello world"
${d}[shell]="/bin/sh"
${d}[ulimit]="nofile=4096:8192"
${d}[bridged]="true"
${d}[port]="$port:80"
EOF
		# shellcheck disable=SC2016 # for the shell of the device
		cat >> "$lab/$d.startup" <<'EOF'
echo "$GREETING" > /tmp/settings-env
readlink /proc/$$/exe > /tmp/settings-shell
mkdir -p /tmp/www && hostname > /tmp/www/index.html
nohup python3 -m http.server 80 --directory /tmp/www > /dev/null 2>&1 &
EOF
	done
	sed -i 's|^a\[0\]=.*|a[0]="A/02:42:ac:11:00:0a"|; s|^r\[0\]=.*|r[0]="A/02:42:ac:11:00:0b"|' "$lab/lab.conf"
}

# A command in a device of the lab, through a shell, without the \r of the
# terminal.
in_device()
{
	local device=$1 command=$2

	kathara exec -d "$LAB" "$device" "bash -c '$command'" 2>&1 | tr -d '\r'
}

wait_for_startups()
{
	local d

	for d in a r; do
		wait_until 60 1 docker exec "$(docker ps -q --filter label=name=$d)" test -f /tmp/EOS
	done
}

check_sysctls()
{
	local s

	for s in "${SYSCTLS[@]}"; do
		check "sysctl $s in r as in a" "$(in_device r "sysctl -n $s")" "$(in_device a "sysctl -n $s")"
	done
}

check_files()
{
	local hosts_a hosts_r

	check "MAC of eth0 of r" "$(in_device r "cat /sys/class/net/eth0/address")" 02:42:ac:11:00:0b
	check "env, startup of r as of a" "$(in_device r "cat /tmp/settings-env")" "$(in_device a "cat /tmp/settings-env")"
	check "env, exec in r as in a" "$(in_device r "echo \$GREETING")" "$(in_device a "echo \$GREETING")"
	check "shell, startup of r as of a" "$(in_device r "cat /tmp/settings-shell")" "$(in_device a "cat /tmp/settings-shell")"
	check "ulimit nofile, exec in r as in a" "$(in_device r "echo \$(ulimit -Sn):\$(ulimit -Hn)")" \
		"$(in_device a "echo \$(ulimit -Sn):\$(ulimit -Hn)")"
	hosts_a=$(in_device a "cat /etc/hosts" | sed 's/ a$/ DEVICE/')
	hosts_r=$(in_device r "cat /etc/hosts" | sed 's/ r$/ DEVICE/')
	check "/etc/hosts of r as of a" "$hosts_r" "$hosts_a"
	check "/etc/resolv.conf of r as of a" "$(in_device r "cat /etc/resolv.conf")" "$(in_device a "cat /etc/resolv.conf")"
}

check_mounts()
{
	local m

	for m in /dev/shm /dev/mqueue /sys/fs/cgroup; do
		check "filesystem of $m in r as in a" "$(in_device r "stat -f -c %T $m")" "$(in_device a "stat -f -c %T $m")"
	done
	check "/run of r is the one of the container, not a tmpfs" "$(in_device r "stat -f -c %T /run" | grep -c '^tmpfs$')" 0
}

check_bridged()
{
	local r docker_ip

	r=$(docker ps -q --filter label=name=r --filter label=uml=1)
	docker_ip=$(docker inspect "$r" --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')
	check "address of the bridged interface of r" "$(in_device r "ip -4 -o addr show dev eth2" | awk '{ print $4 }' | cut -d/ -f1)" \
		"$docker_ip"
	check "published port of a" "$(curl -s -m 5 http://127.0.0.1:8091/)" a
	check "published port of r" "$(curl -s -m 5 http://127.0.0.1:8092/)" r
}

check_entrypoint_refused()
{
	local out

	new_lab
	echo 'r[entrypoint]="/usr/sbin/mydaemon"' >> "$NEW_LAB/lab.conf"
	out=$(kathara lstart --noterminals -d "$NEW_LAB" 2>&1)
	check "lstart with entrypoint on r fails" "$?" 1
	check "the error names the options" "$(grep -c 'entrypoint and args options' <<< "$out")" 1
}

if [ ! -f "$KERNEL" ]; then
	echo "usage: $0 [UML kernel]" >&2
	exit 1
fi
if [ -n "$(docker ps -q --filter label=app=kathara)" ]; then
	echo "a Kathara lab is running: its published ports or devices could clash" >&2
	exit 1
fi
trap clean_labs EXIT

new_lab
LAB=$NEW_LAB
add_options "$LAB"
kathara lstart --noterminals -d "$LAB" >/dev/null 2>&1
check "lstart" "$?" 0
wait_for_startups

check_sysctls
check_files
check_mounts
check_bridged
kathara lclean -d "$LAB" >/dev/null 2>&1
check_entrypoint_refused

finish SETTINGS
