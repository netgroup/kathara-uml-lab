#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# Runs in the VM container (foreground, PID 1): fetches and checks the
# Debian cloud image once, serves a cloud-init seed over HTTP, then runs
# the VM under KVM. /vm is the VM directory of the work dir.
set -o pipefail

URL=https://cloud.debian.org/images/cloud/trixie/latest
IMG=debian-13-genericcloud-amd64.qcow2

die()
{
	echo "run-vm.sh: $*" >&2
	exit 1
}

# The Debian cloud image, downloaded once and checked against SHA512SUMS.
fetch_image()
{
	if [ -f "img/$IMG" ]; then
		return
	fi
	mkdir -p img
	(
		cd img || exit 1
		curl -sfLO "$URL/SHA512SUMS" && curl -sfLO "$URL/$IMG" || die "download failed"
		if ! grep " $IMG\$" SHA512SUMS | sha512sum -c -; then
			rm -f "$IMG"
			die "bad checksum of $IMG"
		fi
	) || exit 1
}

# The cloud-init seed: root logs in with the key of seed/id_ed25519.
make_seed()
{
	mkdir -p seed
	if [ ! -f seed/id_ed25519 ]; then
		ssh-keygen -q -t ed25519 -N '' -f seed/id_ed25519
	fi
	cat > seed/user-data <<EOF
#cloud-config
disable_root: false
ssh_pwauth: false
users:
  - name: root
    ssh_authorized_keys:
      - $(cat seed/id_ed25519.pub)
EOF
	printf 'instance-id: kathara-uml-vm\nlocal-hostname: kathara-uml-vm\n' > seed/meta-data
}

# The disk of the VM, a copy-on-write layer on the cloud image.
make_disk()
{
	if [ ! -f img/vm.qcow2 ]; then
		qemu-img create -q -f qcow2 -F qcow2 -b "/vm/img/$IMG" img/vm.qcow2 30G
	fi
}

cd /vm || exit 1
fetch_image
make_seed
make_disk
mkdir -p logs
python3 -m http.server 8000 -d /vm/seed > logs/seed-http.log 2>&1 &
exec qemu-system-x86_64 -accel kvm -cpu host -m "${VM_MEM:-6G}" -smp "${VM_CPUS:-4}" \
	-display none -monitor none -serial file:/vm/logs/serial.log \
	-drive file=/vm/img/vm.qcow2,if=virtio,discard=unmap \
	-nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
	-smbios 'type=1,serial=ds=nocloud;s=http://10.0.2.2:8000/'
