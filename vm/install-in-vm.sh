#!/bin/bash
# author: Andrea Mayer <andrea.mayer@uniroma2.it>
#
# Runs in the test VM, from the tree that vm.sh install copied into
# /opt/kathara-uml: installs Docker and python3-venv if they are missing,
# Kathara from the kathara submodule in a venv in /opt/kathara, and a
# kathara command that runs it.
set -e
export DEBIAN_FRONTEND=noninteractive

TREE=/opt/kathara-uml
VENV=/opt/kathara

have_packages()
{
	command -v docker >/dev/null && [ -x /usr/bin/python3 ] && python3 -c 'import venv' 2>/dev/null
}

install_packages()
{
	if have_packages; then
		return
	fi
	apt-get update -q >/dev/null
	apt-get install -y -q docker.io python3-venv >/tmp/apt.log
}

install_kathara()
{
	if [ ! -x "$VENV/bin/pip" ]; then
		python3 -m venv "$VENV"
	fi
	"$VENV/bin/pip" install -q "$TREE/kathara" >/tmp/pip.log
	cat > /usr/local/bin/kathara <<EOF
#!/bin/sh
exec $VENV/bin/python $TREE/kathara/src/kathara.py "\$@"
EOF
	chmod 755 /usr/local/bin/kathara
}

install_packages
install_kathara
echo "installed: $(kathara --version | tail -1), Docker $(docker version --format '{{.Server.Version}}')"
if [ -f "$TREE/out/kernel/linux" ]; then
	ls -l "$TREE/out/kernel/linux"
else
	echo "no UML kernel: run uml-kernel/build.sh first"
fi
