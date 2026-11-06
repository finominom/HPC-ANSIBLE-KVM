# Running this project on KVM/libvirt

This copy adds `inventory/kvm` (the default in `ansible.cfg`). The `vbox` and
`supermicro` inventories and all roles are unchanged.

Tested here: `--syntax-check` of master.yml, compute.yml and site.yml with
ansible-core 2.14.18 and the pinned collections in `requirements.yml`.
Verified on a live KVM master (alma98): roles `base`, `service_accounts`,
`chrony` and `bind`. The new `data_disk` role was tested on a loop file
(format, folders, second run changes nothing, in-use-device refusal) but
its mount and home-move steps have not been run on the VM yet. Not yet run:
`localrepo`, `nfs`, `cobbler`, `slurm`, `compute.yml`.

## What inventory/kvm assumes

| Setting | Value | Why |
|---|---|---|
| `master_if_external` | `enp1s0` | libvirt network `default` (NAT) |
| `master_if_mgmt` | `enp7s0` | libvirt network `mgmt` (isolated, no DHCP) |
| `master_if_cluster` | `enp8s0` | libvirt network `hpc` (isolated, no DHCP) |
| `bind_forwarders` | `192.168.122.1` | DNS of libvirt's `default` network |
| `bind_dnssec_validation` | `"no"` | libvirt's dnsmasq strips DNSSEC data |
| `nfs_require_separate_data_fs` | `true` | `/data` is its own virtual disk (`vdb`) |
| `cobbler_iso_path` | `/data/isos/AlmaLinux-9-latest-x86_64-dvd.iso` | the ISO is a file on `/data` |
| `cluster_pkg_source` | `nat` | rehearsal mode (runbook Option B) |

Check the NIC names against `ip -br link` and `virsh domiflist alma98` (match
the MAC addresses) before the first run.

## Setup on the master (as root)

```bash
dnf -y install ansible-core git unzip
cd /opt
unzip -o /path/to/hpc-ansible-kvm.zip          # creates /opt/hpc-ansible
cd /opt/hpc-ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook master.yml --syntax-check
```

Unzip from `/opt`, not from inside `/opt/hpc-ansible`; the archive already
contains the `hpc-ansible` folder. Expected collections: ansible.posix 1.5.x,
community.general 8.x, community.mysql 3.x.

## Run one role at a time, snapshot after each (on the host)

| Step | Command (in the VM) | Snapshot (on the host) |
|---|---|---|
| base | `ansible-playbook master.yml --tags base` | `virsh snapshot-create-as alma98 03-base` |
| time + accounts | `... --tags service_accounts,chrony` | `04-time` |
| DNS (Gate C) | `... --tags bind` | `05-dns` |
| data disk | `... --tags data` (after the host script, see below) | `07-data` |
| NFS | `... --tags nfs` | `08-nfs` |
| Cobbler | `... --tags cobbler` (sync stays off until Gate D) | `09-cobbler` |
| node VMs | on the KVM host: `host-prep/compute-vms.yml` | (VMs, no snapshot) |
| node install | `virsh start c01`, then `compute.yml` | `10-node-c01` |
| Slurm | `master.yml --tags slurm`, then `compute.yml --tags slurm` | `11-slurm` |

Do not use `--check` with `base`: its `nmcli` lookups are skipped in check mode.
Run each role a second time; `changed=0` means it is repeatable.

Checks after each step:

```bash
# base
firewall-cmd --get-active-zones; firewall-cmd --zone=public --query-masquerade
ip route | grep default                 # exactly one, via 192.168.122.1
# service_accounts + chrony
getent passwd install munge slurm       # UIDs 5001, 5100, 5101
chronyc sources; chronyc tracking       # wait 1-2 min; want one ^* source
firewall-cmd --zone=internal --query-service=ntp
# bind
dig +short master.hpc @127.0.0.1        # 192.168.16.1
dig +short -x 192.168.17.1 @127.0.0.1   # c01.hpc.
dig +short almalinux.org @127.0.0.1     # must return an IP
```

Notes from the live run:

- `chronyc sources` shows `^?` for the first minute after the role restarts
  chronyd, and the VM clock may be seconds off; it steps into line by itself.
- The `internal` zone still lists `cockpit`. Harmless; remove it with
  `firewall-cmd --permanent --zone=internal --remove-service=cockpit` if unused.
- If external names return SERVFAIL, DNSSEC validation is the cause; this
  inventory already sets `bind_dnssec_validation: "no"`.

## Point the master at its own DNS (runbook 8.5, manual)

Only after `dig +short almalinux.org @127.0.0.1` returns an address:

```bash
EXT=$(nmcli -g GENERAL.CONNECTION device show enp1s0)
CLU=$(nmcli -g GENERAL.CONNECTION device show enp8s0)
nmcli connection modify "$EXT" ipv4.ignore-auto-dns yes ipv4.dns ""
nmcli connection modify "$CLU" ipv4.dns 127.0.0.1 ipv4.dns-search "hpc mgmt"
nmcli connection up "$EXT"; nmcli connection up "$CLU"
cat /etc/resolv.conf; dig +short almalinux.org; dnf makecache
```

If anything breaks, undo with
`nmcli connection modify "$EXT" ipv4.ignore-auto-dns no` and bring it up again.

## Secrets (before the cobbler and slurm roles)

```bash
INV=inventory/kvm
cp $INV/group_vars/master/vault.yml.example $INV/group_vars/master/vault.yml
openssl rand -base64 24        # -> vault_slurm_db_pass
openssl passwd -6              # -> vault_node_root_password_hash
vi $INV/group_vars/master/vault.yml
ansible-vault encrypt $INV/group_vars/master/vault.yml

dd if=/dev/urandom bs=1 count=1024 of=$INV/files/munge.key
ansible-vault encrypt $INV/files/munge.key
```

Add `--ask-vault-pass` to the cobbler and slurm runs. Never commit the
unencrypted files; back up the Munge key, because it cannot be regenerated.

## /data disk, local home and the ISO

Three steps, the first on the KVM host (a VM cannot attach its own disk):

```bash
# 1. On the KVM host, as root. Safe to run twice.
./host-prep/attach-data-disk.sh alma98 80G
```

```bash
# 2. In the VM, as root, from a console login with jioke logged out
lsblk                                    # vdb should be 80G and empty
cd /opt/hpc-ansible
ansible-playbook master.yml --tags data
findmnt /data; ls /data; ls -Z /data/home
```

The `data_disk` role (device `/dev/vdb`, set in `inventory/kvm`) does this:

- refuses to continue if the device is missing, is not a block device, or is
  mounted anywhere except `/data`
- creates an XFS filesystem labelled `data` only if the disk has none (it
  never reformats; it fails if the disk holds another filesystem or a
  partition table)
- mounts it by UUID and writes the `/etc/fstab` line
- creates `/data/home`, `/data/opt` and `/data/isos`
- moves each local home listed in `data_disk_move_homes` (default `jioke`)
  to `/data/home`, after checking that the user has no processes and that the
  destination does not already exist
- gives `/data/home` the same SELinux labels as `/home`
  (`semanage fcontext -a -e`); check with `ls -Z /data/home`

If it stops because `jioke` is logged in, log that user out (a console login
as root works) and run it again. Remove `data_disk_move_homes` if the master
has no local user. Leave `data_disk_device` empty on inventories where `/data`
is prepared by hand; the role then does nothing.

```bash
# 3. Then NFS (needs /data mounted)
ansible-playbook master.yml --tags nfs
exportfs -v; showmount -e localhost; systemctl is-active nfs-server autofs
```

The ISO is only needed for Cobbler. Either copy the DVD ISO from the host:
`scp /home/libvirt/images/AlmaLinux-9-latest-x86_64-dvd.iso USER@MASTER-IP:/data/isos/`
or download the minimal ISO (about 2 GB) on the master into `/data/isos/` and
point `cobbler_iso_path` at it. Compare `sha256sum` with the official CHECKSUM
file either way.

The node Kickstart installs `@^minimal-environment`, `chrony`, `python3` and
`nfs-utils` from the ISO itself (`url --url=$tree`). The minimal ISO carries
only part of BaseOS, so check before importing it:

```bash
mkdir -p /mnt/iso && mount -o loop,ro /data/isos/AlmaLinux-9-latest-x86_64-minimal.iso /mnt/iso
find /mnt/iso -name 'nfs-utils-*' -o -name 'chrony-*' -o -name 'python3-3*'
umount /mnt/iso
```

If `nfs-utils` is missing, the node install stops at the package step. Use the
DVD ISO instead, or add a `repo` line (an AlmaLinux mirror) to the Kickstart;
in `nat` mode the installer can reach the internet through the master.

## Compute VMs

The node VMs are defined from the inventory, on the KVM host, so the MAC in
`host_vars/cNN.hpc.yml` is the single source for both the VM and Cobbler's
system record. Settings are in `inventory/kvm/group_vars/compute.yml`
(network `hpc`, NIC model `e1000`, 3 GB RAM, 2 vCPUs, 20 GB disk).

Why `e1000`: legacy BIOS PXE needs a NIC that has a PXE boot ROM in QEMU.
`e1000` (the runbook's "Intel PRO/1000") and `virtio` have one; as far as I
know `e1000e` only ships a UEFI ROM, so it would not PXE-boot here.

Order:

```bash
# 1. After the cobbler role (with cobbler_mac set) and Stop Gate D passed.
#    On the KVM host, as root, from a copy of this project:
sudo ansible-playbook -i inventory/kvm/cobbler.ini host-prep/compute-vms.yml
virsh list --all                       # c01 and c02, shut off

# 2. Start one node and watch it install over PXE
virsh start c01
virt-viewer c01
```

The VMs boot from the network first, then the disk. Cobbler's `pxe_just_once`
turns network boot off after the install finishes. Start `c02` once `c01`
works. After a node is installed, run `compute.yml` for it, then replace
`slurm_node_params` with the `slurmd -C` output from the node.

Before the Slurm role, test `getent hosts master` from a node: the Kickstart
may not add the `hpc` search domain.
