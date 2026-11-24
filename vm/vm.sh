#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# Test VM for UML devices: a Debian 13 VM under KVM, with QEMU in a podman
# container. Docker, this tree with the Kathara of its submodule and the
# device image are installed INSIDE the VM, so the tests touch neither the
# host's Docker nor its network. Everything lives in out.
#
#   vm.sh start          create (first time) and boot the VM, wait for ssh
#   vm.sh install        copy this tree (and out/kernel/linux) into the
#                        VM, install Docker and Kathara (install-in-vm.sh)
#   vm.sh test           run tests/check-router.sh and check-shared.sh
#   vm.sh ssh [cmd...]   a command (or a shell) in the VM
#   vm.sh stop           shut the VM down and remove its container (its
#                        disk stays in out/vm)
#
# VM_MEM (default 6G) and VM_CPUS (default 4) size the VM. /dev/kvm is
# needed; when the user cannot open it, podman runs through sudo, and the
# VM files in out/vm are then owned by root.
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
WORK=$REPO/out
V=$WORK/vm
NAME=kathara-uml-vm
IMAGE=localhost/kathara-uml-vm
TREE=/opt/kathara-uml
SSH_OPTIONS=(-i /vm/seed/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-p 2222 root@127.0.0.1)

die()
{
	echo "vm.sh: $*" >&2
	exit 1
}

usage()
{
	sed -n '4,20p' "$0"
	exit 1
}

# A command in the VM, through the ssh client of the VM container.
vssh()
{
	"${PM[@]}" exec -i "$NAME" ssh -q -o LogLevel=ERROR -o ConnectTimeout=5 "${SSH_OPTIONS[@]}" "$@"
}

# A shell in the VM, on the terminal.
vshell()
{
	"${PM[@]}" exec -it "$NAME" ssh -q "${SSH_OPTIONS[@]}"
}

running()
{
	[ "$("${PM[@]}" inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ]
}

ensure_running()
{
	if ! running; then
		die "VM not running: vm.sh start"
	fi
}

# Waits up to 300 s for the ssh of the VM.
wait_for_ssh()
{
	local s

	for ((s = 1; s <= 300; s++)); do
		if ! running; then
			"${PM[@]}" logs "$NAME" 2>&1 | tail -5
			die "VM container stopped"
		fi
		if vssh true 2>/dev/null; then
			echo "VM up after $s s: $(vssh uname -r)"
			return
		fi
		sleep 1
	done
	die "no ssh after 300 s, see $V/logs/serial.log"
}

do_start()
{
	if running; then
		echo "VM already running"
		return
	fi
	"${PM[@]}" rm -f "$NAME" >/dev/null 2>&1
	if ! "${PM[@]}" build -q -t "$IMAGE" "$HERE" > "$V/tmp/image.log" 2>&1; then
		cat "$V/tmp/image.log"
		die "VM image failed"
	fi
	"${PM[@]}" run -d --name "$NAME" --memory=10g --device /dev/kvm \
		-e VM_MEM="${VM_MEM:-6G}" -e VM_CPUS="${VM_CPUS:-4}" \
		-v "$V:/vm:Z" -v "$HERE/run-vm.sh:/run-vm.sh:ro,Z" "$IMAGE" bash /run-vm.sh >/dev/null ||
		die "cannot start the VM container"
	echo "VM booting (the first start downloads the Debian cloud image)"
	wait_for_ssh
}

# The tracked and the new files of the tree and of the kathara submodule,
# not what .gitignore hides, plus the kernel built by uml-kernel/build.sh
# if there is one.
pack_tree()
{
	local tar=$1

	(cd "$REPO" && git ls-files -co --exclude-standard -z -- ':!kathara' | tar --null -T - -cf "$tar") ||
		die "cannot pack the tree"
	(cd "$REPO/kathara" && git ls-files -co --exclude-standard -z |
		tar --null -T - -rf "$tar" --transform 's|^|kathara/|') ||
		die "cannot pack kathara: git submodule update --init"
	if [ -f "$WORK/kernel/linux" ]; then
		tar -rf "$tar" -C "$WORK/kernel" --transform 's|^|out/kernel/|' linux
	fi
}

do_install()
{
	local tar=$V/tmp/tree.tar

	ensure_running
	pack_tree "$tar"
	vssh "rm -rf $TREE && mkdir $TREE && tar -C $TREE -xf -" < "$tar" || die "cannot copy the tree"
	vssh bash "$TREE/vm/install-in-vm.sh"
}

# Runs the lab tests and exits with the number of tests that failed.
do_test()
{
	local t failed=0

	ensure_running
	for t in check-router check-shared; do
		if ! vssh bash "$TREE/tests/$t.sh"; then
			failed=$((failed + 1))
		fi
	done
	return "$failed"
}

# Shuts the VM down cleanly, then removes its container. Killing QEMU
# right after a test may leave the containers that Docker was removing in
# the VM as Dead, at the next boot. Waits up to 120 s for the shutdown.
do_stop()
{
	local s

	if running; then
		vssh poweroff >/dev/null 2>&1
		for ((s = 0; s < 120; s++)); do
			if ! running; then
				break
			fi
			sleep 1
		done
	fi
	"${PM[@]}" rm -f "$NAME" >/dev/null && echo "VM stopped"
}

do_ssh()
{
	ensure_running
	if [ $# = 0 ]; then
		vshell
	else
		vssh "$@"
	fi
}

mkdir -p "$V/tmp" || die "cannot create $V"
V=$(cd "$V" && pwd)
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	PM=(env TMPDIR="$V/tmp" podman)
else
	PM=(sudo env TMPDIR="$V/tmp" podman)
fi
PM+=(--root "$V/podman/storage" --runroot "$V/podman/run")

case "$1" in
start)
	do_start
	;;
install)
	do_install
	;;
test)
	do_test
	;;
ssh)
	shift
	do_ssh "$@"
	;;
stop)
	do_stop
	;;
*)
	usage
	;;
esac
