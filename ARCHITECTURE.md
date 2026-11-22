# Architecture of a UML device

How a Kathara device runs on its own User-Mode Linux (UML) kernel: what
Kathara does, what runs in the container, how packets reach the UML, what
the UML boot options are for, and how the files and the shell of the
device get into the UML.

Line numbers refer to the Kathara of the `kathara` submodule
(`src/Kathara/manager/docker/`, at b905aaf) and, for the kernel, to a
tree at v7.4-rc2-492-g533ec433efdc, not to the 7.3.5 sources the test
kernel is built from. The outputs under "Observed" come from the router lab in the test
VM, on 2026-11-21, with the 7.3.5 kernel of `out/kernel`.

## The pieces

```
 lab.conf: r[kernel]="kernel/linux"
     |
     v
 Kathara (kathara/, Docker manager)          helpers (UmlHelpers.py)
   DockerMachine.create()  ---- copies ---->   /kathara-uml/start   entrypoint of the container
   DockerMachine.start()                       /kathara-uml/init    PID 1 of the UML
   DockerMachine.exec()                        /kathara-uml/ushell  shell of the device
     |
     | mounts read-only
     v
 /kathara-uml-kernel  = the UML kernel, a normal x86-64 ELF program
                        (built by uml-kernel/build.sh)
```

A UML kernel is a Linux kernel built with `ARCH=um`: it runs as a process
of the host, here as PID 1 of the device's container. Its own processes
are processes of the container too.

## What Kathara does

For a device with the `kernel` option, `DockerMachine.create()`:

- resolves the path: relative to the lab directory, through the lab
  filesystem, with links resolved (`DockerMachine.py:336-338`); the file
  must exist (`:339-340`);
- mounts it read-only on `/kathara-uml-kernel` (`:342`) and sets
  `KATHARA_UML_IFACES` to the number of interfaces (`:343`);
- sets the label `uml`, the shell label to `/kathara-uml/ushell` and the
  entrypoint to `/kathara-uml/start` (`:377-380`);
- copies the three helpers into `/kathara-uml` (`:415-416`).

`DockerMachine.start()` starts the container, then connects the
interfaces after the first one, which Kathara does only after the start
(`:546-555`), then touches `/run/kathara-uml.ready` (`:563-565`), then runs
the startup commands as `<shell> -c <commands>` (`:586`). `connect` runs
the shell label (`:702-703`), and `exec` of a UML device runs the
command as `<shell> -c <command>` (`:834-835`). With the shell label set
to `ushell`, all three go into the UML.

## Boot sequence

```
 Kathara                         container r                        UML kernel
 -------                         -----------                        ----------
 create(): mount kernel,
   entrypoint start,
   copy helpers
 start(): container start  --->  start: ssh key, then waits
                                 for /run/kathara-uml.ready
 connect eth1.. ethN
 touch kathara-uml.ready   --->  start: veth um0/um1, ethK up,
                                 exec /kathara-uml-kernel ... -->   boot, mount / (hostfs),
                                                                    vecK interfaces,
                                                                    run /kathara-uml/init
                                                                    init: vecK -> ethK,
                                                                    last -> kmgmt, sshd
 startup: ushell -c CMDS   --->  ushell: waits for the key,
                                 ssh 169.254.77.2 -------------->   sshd: runs CMDS
                                 (ssh retries the connect           (r.startup)
                                 until sshd answers)
```

`start` makes the key of `ushell` first (`UmlHelpers.py:47-55`), then
builds the `vecK` boot options from the interfaces of the container, so
it waits for the ready file, that is until Kathara has attached them all:
600 checks 0.1 s apart (`:25-32`, `:56`).

Kathara runs the startup through `ushell` right after it touches the
ready file. `ushell` waits for the key (`:159-168`), up to 600 checks 0.1 s
apart, then runs one ssh (`:149-153`, `:169-173`). While the UML boots,
ssh retries only the TCP connect, once a second, up to
`ConnectionAttempts=120` times (`sshconnect.c:461-518` of OpenSSH
9.2p1), so a startup or an `exec` issued then waits for `sshd`, and a
command never runs twice. `ConnectTimeout=10` bounds each connect and the
ssh banner exchange (`kex.c:1275-1282`).

## Network

```
    collision domain A                            collision domain B
     (Kathara bridge)                              (Kathara bridge)
             |                                             |
+------------|----------------- container r ---------------|---------------+
|          eth0 no address                               eth1 no address   |
|           | ^                                           | ^              |
|        rx | | tx          AF_PACKET sockets          rx | | tx           |
|           v |                                           v |              |
|  +--------|-|------------- UML kernel (PID 1) ----------|-|-----------+  |
|  |  vec0 = eth0  10.0.1.2/24              vec1 = eth1  10.0.2.2/24    |  |
|  |  routing, netfilter, eBPF ... of the UML kernel                    |  |
|  |                                                                    |  |
|  |  vec2 = kmgmt  169.254.77.2/30  <-- sshd                           |  |
|  +--------|-|---------------------------------------------------------+  |
|           | ^                                                            |
|        rx v | tx                                                         |
|          um1  veth peer of um0                                           |
|          um0  169.254.77.1/30  <-- ushell (ssh client)                   |
+--------------------------------------------------------------------------+
```

### Collision domain interfaces

Kathara attaches the container to its collision domains as for any device:
`eth0`, `eth1`, ... are veth interfaces of the container. `start` gives
each one to the UML (`UmlHelpers.py:36-42`, `:62-66`):

- it disables IPv6 on it and sets it up; it gives it no address, so the
  interface of the container is only a wire for the UML;
- it adds `vecK:transport=raw,ifname=ethK,depth=128,gro=1` to the boot
  options.

The UML vector driver, with the raw transport, opens two packet sockets
on that interface (`arch/um/drivers/vector_user.c:521-560`):

- a receive socket, `socket(AF_PACKET, SOCK_RAW, ETH_P_ALL)` bound to the
  interface with `ETH_P_ALL` (`:533`, `:167-195`), "Every packet"
  (`include/uapi/linux/if_ether.h:138`);
- a transmit socket created with protocol 0, "Turn off RX on this fd",
  and bound with `ETH_P_IP` (`:538`).

Observed, `/proc/net/packet` of the container: two sockets on each of
ifindex 71 (`eth0`), 72 (`eth1`) and 2 (`um1`), one with protocol 0003
(`ETH_P_ALL`) and one with 0800.

### Packet path

```
 transmit: UML stack -> vec0 queue -> sendmmsg(tx socket) -> eth0 of the container
           -> veth peer on the bridge of A -> other devices of A

 receive:  frame on the bridge of A -> eth0 of the container
           -> rx socket (ETH_P_ALL) -> recvmmsg() in the UML
           -> napi_gro_receive() -> UML stack
```

- The driver sends with `uml_vector_sendmmsg()` (`vector_kern.c:427`) and
  receives with `uml_vector_recvmmsg()` (`vector_kern.c:973`), wrappers
  of `sendmmsg()` and `recvmmsg()` (`vector_user.c:806-832`): up to
  `depth` frames per system call.
- A received frame goes up the UML stack through `napi_gro_receive()`
  (`vector_kern.c:1025`).
- For the raw transport the driver asks for `PACKET_QDISC_BYPASS`
  (`vector_kern.c:246-247`, `:1288-1290`); if the socket refuses it, it
  attaches to the receive socket a BPF filter that drops the frames whose
  source MAC is the one of the UML interface (`vector_kern.c:1289-1296`,
  `vector_user.c:860-889`). Inference, not checked further: both keep the
  UML from receiving the frames it sent itself.
- The container's own stack also receives the frames of `eth0`, but the
  interface has no IPv4 address and IPv6 is off on it. The router test
  (`tests/check-router.sh`) checks that the container's `eth0` has no
  address and that the first hop from `a` to `b` is the address of the UML.

### Management link

`start` adds a veth pair inside the container (`UmlHelpers.py:58-59`):
`um0` keeps 169.254.77.1/30 in the container, `um1` is given to the UML
as its last vector interface (`:66`). `init` renames that one `kmgmt`,
gives it 169.254.77.2/30 (`:113-115`) and starts `sshd` on that address
(`:133`). `ushell` is ssh from the container to `root@169.254.77.2`
(`:149-173`), with a key that `start` creates in `/var/lib/kathara-uml/id`
and copies to `/root/.ssh/authorized_keys` (`:47-53`); the UML reads that
file through hostfs.

## Boot options of the UML

The command `start` runs (`UmlHelpers.py:79-82`):

```
env TMPDIR=/tmp/uml /kathara-uml-kernel mem=256M \
    root=/dev/root rootfstype=hostfs rootflags=/ rw init=/kathara-uml/init \
    con0=fd:0,fd:1 con=null seccomp=auto \
    vec0:transport=raw,ifname=eth0,depth=128,gro=1 ... \
    < /tmp/uml/stdin > /var/log/uml-console.log 2>&1
```

| Option | What it does | Source |
|---|---|---|
| `TMPDIR=/tmp/uml` | the directory where UML creates the file that backs its memory | `arch/um/os-Linux/mem.c:83-90`, `:131-146`, `:212` |
| `mem=256M` | the memory of the UML kernel; `KATHARA_UML_MEM` (`env` option) changes it | `arch/um/kernel/physmem.c:120-136`, `UmlHelpers.py:79` |
| `root=/dev/root` | only a name: `parse_root_device()` returns 0 when no block device has the name, and with `rootfstype` set the kernel then mounts a filesystem that needs no device, with the name as source (observed: "VFS: Mounted root (hostfs filesystem)") | `init/do_mounts.c:428-452`, `:394-397`, `:339-364` |
| `rootfstype=hostfs` | the root filesystem is hostfs, which shows a directory of the host (here, of the container) | `init/do_mounts.c:122`, `fs/hostfs/hostfs_kern.c:1023-1026` |
| `rootflags=/` | the mount data, for hostfs the host directory to show: `/` of the container | `init/do_mounts.c:121`, `fs/hostfs/hostfs_kern.c:1006-1020` |
| `rw` | mount the root read-write; the default is read-only | `init/do_mounts.c:31`, `:45-54` |
| `init=/kathara-uml/init` | the first process of the UML: the `init` helper | `UmlHelpers.py:85-139` |
| `con0=fd:0,fd:1` | console 0 reads fd 0 and writes fd 1 of the UML process | UML howto ("fd channel") |
| `con=null` | the other consoles discard input and output | UML howto ("null channel") |
| `seccomp=auto` | run the UML processes in the seccomp mode if it works, else in the ptrace mode; `KATHARA_UML_SECCOMP` changes it | `arch/um/os-Linux/start_up.c:424-489`, `UmlHelpers.py:69` |
| `vecK:transport=raw` | a network interface `vecK` on raw packet sockets | UML howto ("raw socket transport"), `vector_user.c:521-560` |
| `ifname=ethK` | the interface of the container the sockets bind to | UML howto ("Shared Options") |
| `depth=128` | frames read or written per system call; the default is 64 | UML howto ("Common options"), `vector_kern.c:81` |
| `gro=1` | receive/transmit offloads; the howto says it must match the host side and that veth has GRO on | UML howto ("Common options") |

The UML howto is `Documentation/virt/uml/user_mode_linux_howto_v2.rst`
of the kernel tree.

`mem=` and `seccomp=` are options of UML itself: UML parses its own
options first and leaves out of the kernel command line those whose
handler sets `*add = 0` (`arch/um/kernel/um_arch.c:396-403`), as
`uml_mem_setup()` (`arch/um/kernel/physmem.c:124`) and
`uml_seccomp_config()` (`arch/um/os-Linux/start_up.c:428`) do. So the
console prints a command line without them. Observed:

```
Kernel command line: root=/dev/root rootfstype=hostfs rootflags=/ rw init=/kathara-uml/init con0=fd:0,fd:1 con=null vec0:transport=raw,ifname=eth0,depth=128,gro=1 ...
VFS: Mounted root (hostfs filesystem) on device 0:17.
```

stdin is a FIFO kept open by `sleep infinity`, and the console goes to a
file (`UmlHelpers.py:74-82`): with a pipe on stdout or stdin at end of
file the UML stops early in the boot (see README, "Things to know").

The seccomp mode: see README, "seccomp or ptrace", for what it changes and
what it costs. Observed with `seccomp=auto` under KVM:
`Checking that seccomp filters can be installed...OK`.

## Files

```
 image layers (read-only, e.g. kathara/base)   \
 upper layer of the container (read-write)      >  overlay2 = / of the container
 bind mounts: /shared, /hosthome, volumes,     /
              /kathara-uml-kernel (ro)
                         |
                         |  hostfs, rootflags=/
                         v
                    / of the UML
```

The UML has no disk: its root is the container's own `/`, through hostfs.
The image, the files Kathara copies into the container, `/shared`,
`/hosthome` and the volumes are all there. A file the UML writes goes
where a write of the container goes. Observed: a file written from the
UML (`kathara exec r "bash -c 'echo from-uml > /root/arch-probe'"`) was
in the upper directory of the container's overlay2.

`init` mounts `/proc`, `/sys`, `/dev`, `/dev/pts`, `/run` and
`/sys/fs/bpf` of the UML (`UmlHelpers.py:93-101`): those are the UML
kernel's own, not the container's.

The hostfs caveat of the howto applies ("Hostfs Caveats"): if a file is
changed outside the UML, the UML does not know it, and its in-memory cache
of the file may be corrupt. The shared folder test
(`tests/check-shared.sh`) reads each file with a new process; a file kept
open in the UML while the host changes it was not tested.

## Shell, exec and startup

```
 kathara exec r "ip -br addr"
   -> exec(): ["/kathara-uml/ushell", "-c", "ip -br addr"]      DockerMachine.py:834-835
   -> docker exec in container r
   -> ushell: ssh -T root@169.254.77.2 -- "ip -br addr"          UmlHelpers.py:169-172
   -> sshd in the UML runs it, the output and the exit code come back

 kathara connect r
   -> the shell label: /kathara-uml/ushell                     DockerMachine.py:702-703
   -> ushell: ssh -t root@169.254.77.2                          UmlHelpers.py:173
```

The startup commands of Kathara (`STARTUP_COMMANDS`,
`DockerMachine.py:45`), the device's `.startup` file among them, run in
the UML in the same way. They read the lab files from the same paths as
for a container, because the UML sees the container's files.

## Observed processes and interfaces

In the container (`docker exec <r> ps -eo pid,args`): PID 1 is
`/kathara-uml-kernel mem=256M root=/dev/root ...`, then `sleep infinity`
(the stdin of the console) and the `uml-userspace` processes of UML.

```
container r                         UML of r
lo     127.0.0.1/8                  lo     127.0.0.1/8
um0    169.254.77.1/30              eth0   10.0.1.2/24
um1    (no address)                 eth1   10.0.2.2/24
eth0   (no address)                 kmgmt  169.254.77.2/30
eth1   (no address)                 dummy0, sit0 (down)
```

To look at a running device:

```
kathara exec r "ip -br addr"                                   # the UML side
docker exec $(docker ps -qf name=_r_) ip -br addr              # the container side
docker exec $(docker ps -qf name=_r_) cat /var/log/uml-start.log
docker exec $(docker ps -qf name=_r_) cat /var/log/uml-console.log
docker exec $(docker ps -qf name=_r_) cat /proc/net/packet
docker exec $(docker ps -qf name=_r_) cat /var/tmp/uml-status  # written by init every 2 s
```
