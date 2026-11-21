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
- [ ] **Kubernetes manager**: only the Docker manager knows the kernel
      option today.

## Patches

- [ ] `uml-kernel/patches/7.3` carries "bpf: Build bpf_trace_printk()
      without BPF_EVENTS", not yet submitted to the kernel.
      If it goes upstream, replace it with the upstream commit.

## Upstream Kathara

- [ ] Kathara develops on `develop`, ahead of `main` (this branch is on
      `main`, 3.8.4) and with changes in DockerMachine.py: rebase there
      before proposing anything.

## Elsewhere

- GOB labs (a GOB UML kernel with a gob.fragment, an image with the
  iproute2 that has `ip ioam gobschema`, a lab GOB node, node without
  GOB, GOB node) belong to the GOB repository, which uses this fork.
