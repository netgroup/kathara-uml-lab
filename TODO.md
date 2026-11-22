# TODO: UML devices

## Devices

- [ ] **Images without OpenSSH** (low priority). The UML runs on the
      image of the device, and the Kathara images seen (kathara/base,
      kathara/frr) have the OpenSSH client and server, iproute2 and glibc.
      Only for an image without OpenSSH: a static dropbear (prototype in
      `out/dropbear`, not in git) copied with the helpers.
- [ ] **Kernel modules.** UML supports them (`CONFIG_MODULES=y` in
      `arch/um/configs/x86_64_defconfig`); base.fragment turns them off.
      1. build.sh checks every option of every fragment, so a fragment
         with `CONFIG_MODULES=y` after base.fragment (`=n`) fails with
         CONFIG MISMATCH: check, for each option, the last fragment that
         sets it.
      2. With `CONFIG_MODULES=y`, build and install the modules
         (`make modules`, `modules_install` into
         `out/kernel/modules`).
      3. Mount them with the existing volume option,
         `r[volume]="<out>/modules/lib/modules/<release>|/lib/modules/<release>|ro"`,
         and test `modprobe` of a network module in a UML device of a
         lab. Then maybe `r[kernel]` pointing to a directory with
         `linux` and `modules/`.
- [ ] **perf.fragment.** The options of a kernel tuned for speed that may
      help a UML kernel (`SLUB_DEBUG=n`, `CC_OPTIMIZE_FOR_PERFORMANCE`,
      `CPU_MITIGATIONS=n`, ...): keep those that exist on UML, measure
      with `tests/bench-uml.sh`, make it the default only if it helps.
- [ ] **Prebuilt test kernel**, attached to a release of the fork, so a
      lab does not need a kernel build first.
- [ ] **Bridged UML devices.** With `bridged`, Kathara adds one more
      interface to the container, numbered after the others
      (DockerMachine.py:266-267) and attached in start() after them
      (:566-568). KATHARA_UML_IFACES counts only `machine.interfaces`
      (:344), so start gives the UML eth0 ... ethN-1 and not the bridged
      one. Read from the code, not tried: hand it over too, and test.
- [ ] **Kubernetes manager**: only the Docker manager knows the kernel
      option today.

## Seen in the tests, not explained

- [ ] **A router run that failed.** One run of `check-router.sh` out of
      five, the first after a boot of the test VM (2026-11-22): `exec r`
      printed nothing and the startup of r did not run. A race found
      since, the key of ushell made 40 ms after the ready file and ssh
      without the key exiting at once with 255, is fixed in the fork.
      After the fix 10 runs passed, 3 of them the first after a boot;
      that the race was the only cause is not proven.
- [ ] **SIGSTOP in the UML.** In the seccomp mode, `kill -STOP` of the
      sshd listener inside the UML: `ps` shows it as `Ts`, yet new
      connections still get the ssh banner (UML 7.3.5). Not tried in the
      ptrace mode.
- [ ] **A test that did not clean.** One run of `check-ushell.sh` out of
      four left its lab running and its directory in /tmp: the EXIT trap
      did not run its `kathara lclean`. Three more runs, one with
      `bash -x`, cleaned.

## Patches

- [ ] `uml-kernel/patches/7.3` carries "bpf: Build bpf_trace_printk()
      without BPF_EVENTS", not yet submitted to the kernel.
      If it goes upstream, replace it with the upstream commit.

## Upstream Kathara

- [ ] **The helpers as files.** start, init and ushell are bash kept in
      Python strings in UmlHelpers.py, because setup.py has no
      package_data and the PyInstaller spec has `datas=[]`. Ship them as
      files of the package instead, which touches the packaging of
      Kathara.
- [ ] **Fixed values.** The management link, 169.254.77.0/30, and the
      path of the key of ushell are written in the helpers: make them
      settings, or say why they need not be.
- [ ] **Tests in Kathara.** Kathara runs only the pytest tests of the
      fork; the lab tests of this repository run in the test VM. Find out
      what the authors of Kathara would want in their own test suite.

## Elsewhere

- GOB labs (a GOB UML kernel with a gob.fragment, an image with the
  iproute2 that has `ip ioam gobschema`, a lab GOB node, node without
  GOB, GOB node) belong to the GOB repository, which uses this fork.
