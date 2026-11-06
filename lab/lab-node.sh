#!/usr/bin/env bash
# lab-node.sh -- run on the KVM HOST (not the master VM), as root.
# Create / destroy / rebuild a blank compute-node VM and its virtual BMC.
#
#   VBMC_PASS=secret ./lab-node.sh recreate 1     # wipe c01 and make a blank one
#   VBMC_PASS=secret ./lab-node.sh pxe 1          # power off/on (node installs if Cobbler netboot is on)
#   VBMC_PASS=secret ./lab-node.sh bmctest 1      # does 'bootdev pxe' stick? (grey area test)
#   ./lab-node.sh status 1
set -euo pipefail

HPC_NET=${HPC_NET:-hpc}                       # libvirt network master's internal NIC is on (NO DHCP)
MAC_PREFIX=${MAC_PREFIX:-52:54:00:aa:bb}      # c01 -> 52:54:00:aa:bb:01 (matches your Cobbler record)
VBMC_ADDR=${VBMC_ADDR:-192.168.0.254}         # host IP on a network the master can reach
VBMC_USER=${VBMC_USER:-mhpc}
VBMC_PASS=${VBMC_PASS:-}
VBMC_BASE_PORT=${VBMC_BASE_PORT:-6230}        # c01 -> 6231, c02 -> 6232
DISK_DIR=${DISK_DIR:-/var/lib/libvirt/images}
DISK_GB=${DISK_GB:-80}
RAM_MB=${RAM_MB:-4096}
VCPUS=${VCPUS:-2}
OSINFO=${OSINFO:-almalinux9}                  # fall back to rhel9.0 if unknown
NIC_MODEL=${NIC_MODEL:-virtio}
BOOT_ORDER=${BOOT_ORDER:-network,hd}         # PXE first: Cobbler's netboot flag decides; pxelinux 'localboot' falls through to the disk

die() { echo "ERROR: $*" >&2; exit 1; }

cmd=${1:-}; N=${2:-}
[[ -n $cmd ]] || die "usage: $0 create|destroy|recreate|status|pxe|bmctest N"
[[ $N =~ ^[0-9]+$ ]] || die "node number required, e.g. 1 for c01"
NODE=$(printf 'c%02d' "$N")
MAC=$(printf '%s:%02x' "$MAC_PREFIX" "$N")
PORT=$((VBMC_BASE_PORT + N))
DISK=$DISK_DIR/$NODE.qcow2

ipmi() {
  [[ -n $VBMC_PASS ]] || die "set VBMC_PASS"
  ipmitool -I lanplus -H "$VBMC_ADDR" -p "$PORT" -U "$VBMC_USER" -P "$VBMC_PASS" "$@"
}

do_destroy() {
  echo "== destroying $NODE"
  vbmc stop "$NODE"   >/dev/null 2>&1 || true
  vbmc delete "$NODE" >/dev/null 2>&1 || true
  virsh destroy "$NODE" >/dev/null 2>&1 || true
  virsh undefine "$NODE" --remove-all-storage >/dev/null 2>&1 || true
  rm -f "$DISK"
  virsh dominfo "$NODE" >/dev/null 2>&1 && die "$NODE still defined"
  echo "   gone"
}

do_create() {
  virsh dominfo "$NODE" >/dev/null 2>&1 && die "$NODE already exists (use recreate)"
  virsh net-info "$HPC_NET" >/dev/null 2>&1 || die "libvirt network '$HPC_NET' not found (virsh net-list --all)"
  if virsh net-dumpxml "$HPC_NET" | grep -q '<dhcp>'; then
    die "network $HPC_NET runs DHCP -- it would answer PXE before Cobbler"
  fi
  ip -4 addr | grep -q "inet $VBMC_ADDR/" || echo "WARN: $VBMC_ADDR is not on this host; the master cannot reach the BMC"

  echo "== creating $NODE ($MAC on $HPC_NET)"
  qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" >/dev/null
  virt-install --name "$NODE" --memory "$RAM_MB" --vcpus "$VCPUS" --cpu host-passthrough \
    --osinfo "$OSINFO" --import \
    --disk "path=$DISK,bus=virtio" \
    --network "network=$HPC_NET,model=$NIC_MODEL,mac=$MAC" \
    --boot "$BOOT_ORDER" --print-xml | virsh define /dev/stdin

  pgrep -x vbmcd >/dev/null || vbmcd
  sleep 1
  vbmc add "$NODE" --address "$VBMC_ADDR" --port "$PORT" \
      --username "$VBMC_USER" --password "${VBMC_PASS:?set VBMC_PASS}"
  vbmc start "$NODE"
  echo "== $NODE defined, powered off. BMC: $VBMC_ADDR:$PORT"
  echo "   boot it with:  $0 pxe $N     (or hpc-node provision $NODE on the master)"
}

case $cmd in
  create)   do_create ;;
  destroy)  do_destroy ;;
  recreate) do_destroy; do_create ;;
  status)
    virsh dominfo "$NODE" | grep -E 'Name|State'
    virsh domiflist "$NODE"
    virsh dumpxml "$NODE" | grep -E '<boot ' || true
    vbmc show "$NODE" 2>/dev/null | grep -E 'status|address|port' || echo "no vbmc entry"
    ;;
  pxe)
    # VirtualBMC rejects "power cycle" and applies boot-order changes only on a full off/on.
    # The VM is PXE-first, so no bootdev is needed; Cobbler's netboot flag decides.
    if ipmi chassis power status | grep -q 'is on'; then
      ipmi chassis power off
      for _ in $(seq 1 30); do ipmi chassis power status | grep -q 'is off' && break; sleep 2; done
    fi
    ipmi chassis power on
    ;;
  bmctest)
    # Does an IPMI 'bootdev pxe' rewrite the VM's boot order permanently?
    virsh dumpxml "$NODE" > "/tmp/$NODE.before.xml"
    echo "--- boot order before:"; grep -E '<boot ' "/tmp/$NODE.before.xml" || true
    ipmi chassis bootdev pxe
    echo "--- boot order after 'bootdev pxe':"; virsh dumpxml "$NODE" | grep -E '<boot ' || true
    echo "--- restoring original definition"
    virsh define "/tmp/$NODE.before.xml" >/dev/null
    echo "If 'after' lost the 'hd' entry, bootdev is persistent: have the workflow run"
    echo "  ipmitool ... chassis bootdev disk   once the node reaches NETBOOT_DISABLED."
    ;;
  *) die "unknown command $cmd" ;;
esac
