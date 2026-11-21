#!/bin/bash
# Test VM for UML devices: a Debian 13 VM under KVM, with QEMU in a podman
# container. Docker, this tree with the Kathara of its submodule and the
# device image are installed INSIDE the VM, so the tests touch neither the
# host's Docker nor its network. Everything lives in the work dir:
# UML_LAB_WORK, default out.
#
#   vm.sh start          create (first time) and boot the VM, wait for ssh
#   vm.sh install        copy this tree (and out/kernel/linux) into the
#                        VM, install Docker, Kathara and the device image
#   vm.sh test           run tests/check-router.sh and check-shared.sh
#   vm.sh ssh [cmd...]   a command (or a shell) in the VM
#   vm.sh stop           stop the VM (its disk stays in the work dir)
#
# VM_MEM (default 6G) and VM_CPUS (default 4) size the VM. /dev/kvm is
# needed; when the user cannot open it, podman runs through sudo, and the
# VM files in the work dir are then owned by root.
set -o pipefail

die() { echo "vm.sh: $*" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
WORK=${UML_LAB_WORK:-$REPO/out}
V=$WORK/vm
NAME=kathara-uml-vm
IMAGE=localhost/kathara-uml-vm

mkdir -p "$V/tmp" || die "cannot create $V"
V=$(cd "$V" && pwd)
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	PM=(env TMPDIR="$V/tmp" podman)
else
	PM=(sudo env TMPDIR="$V/tmp" podman)
fi
PM+=(--root "$V/podman/storage" --runroot "$V/podman/run")

vssh()
{
	"${PM[@]}" exec -i $NAME ssh -q -i /vm/seed/id_ed25519 -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
		-p 2222 root@127.0.0.1 "$@"
}

running() { [ "$("${PM[@]}" inspect -f '{{.State.Running}}' $NAME 2>/dev/null)" = true ]; }

do_start()
{
	running && { echo "VM already running"; return 0; }
	"${PM[@]}" rm -f $NAME >/dev/null 2>&1
	"${PM[@]}" build -q -t $IMAGE "$HERE" > "$V/tmp/image.log" 2>&1 ||
		{ cat "$V/tmp/image.log"; die "VM image failed"; }
	"${PM[@]}" run -d --name $NAME --memory=10g --device /dev/kvm \
		-e VM_MEM="${VM_MEM:-6G}" -e VM_CPUS="${VM_CPUS:-4}" \
		-v "$V:/vm:Z" -v "$HERE/run-vm.sh:/run-vm.sh:ro,Z" $IMAGE bash /run-vm.sh >/dev/null ||
		die "cannot start the VM container"
	echo "VM booting (the first start downloads the Debian cloud image)"
	for i in $(seq 300); do
		running || { "${PM[@]}" logs $NAME 2>&1 | tail -5; die "VM container stopped"; }
		vssh true 2>/dev/null && { echo "VM up after ${i} s: $(vssh uname -r)"; return 0; }
		sleep 1
	done
	die "no ssh after 300 s, see $V/logs/serial.log"
}

do_install()
{
	running || die "VM not running: vm.sh start"
	local tar=$V/tmp/tree.tar
	# The tracked and the new files of the tree and of the kathara
	# submodule, not what .gitignore hides, plus the kernel built by
	# uml-kernel/build.sh if there is one.
	(cd "$REPO" && git ls-files -co --exclude-standard -z -- ':!kathara' | tar --null -T - -cf "$tar") ||
		die "cannot pack the tree"
	(cd "$REPO/kathara" && git ls-files -co --exclude-standard -z |
		tar --null -T - -rf "$tar" --transform 's|^|kathara/|') ||
		die "cannot pack kathara: git submodule update --init"
	[ -f "$WORK/kernel/linux" ] &&
		tar -rf "$tar" -C "$WORK/kernel" --transform 's|^|out/kernel/|' linux
	vssh 'set -e
		export DEBIAN_FRONTEND=noninteractive
		if ! command -v docker >/dev/null || ! [ -x /usr/bin/python3 ] || ! python3 -c "import venv" 2>/dev/null; then
			apt-get update -q >/dev/null && apt-get install -y -q docker.io python3-venv >/tmp/apt.log
		fi
		rm -rf /opt/kathara-uml && mkdir /opt/kathara-uml && tar -C /opt/kathara-uml -xf -
		[ -x /opt/kathara/bin/pip ] || python3 -m venv /opt/kathara
		/opt/kathara/bin/pip install -q /opt/kathara-uml/kathara >/tmp/pip.log
		printf "#!/bin/sh\nexec /opt/kathara/bin/python /opt/kathara-uml/kathara/src/kathara.py \"\$@\"\n" > /usr/local/bin/kathara
		chmod 755 /usr/local/bin/kathara
		echo "installed: $(kathara --version | tail -1), Docker $(docker version --format "{{.Server.Version}}")"
		ls -l /opt/kathara-uml/out/kernel/linux 2>/dev/null || echo "no UML kernel: run uml-kernel/build.sh first"' < "$tar"
}

do_test()
{
	running || die "VM not running: vm.sh start"
	vssh 'cd /opt/kathara-uml/tests && bash check-router.sh; a=$?; bash check-shared.sh; b=$?; exit $((a + b))'
}

case "$1" in
start) do_start ;;
install) do_install ;;
test) do_test ;;
ssh) shift; if [ $# = 0 ]; then "${PM[@]}" exec -it $NAME ssh -q -i /vm/seed/id_ed25519 \
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 root@127.0.0.1; else vssh "$@"; fi ;;
stop) "${PM[@]}" rm -f $NAME >/dev/null && echo "VM stopped" ;;
*) sed -n '2,17p' "$0"; exit 1 ;;
esac
