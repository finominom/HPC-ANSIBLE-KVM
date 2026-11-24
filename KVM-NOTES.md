# Running this project on KVM/libvirt

`inventory/kvm` is the default in `ansible.cfg`. The `vbox` and `supermicro`
inventories use the same roles.

Compute nodes are now installed by **xCAT** (`roles/xcat`) and the `hpc-node`
controller (`roles/hpc_provisioning`), not Cobbler. `roles/xcat/README.md` and
`roles/hpc_provisioning/README.md` map each old Cobbler step to its xCAT equivalent.
The lab loop (VirtualBMC, `lab-node.sh`, `preflight.sh`) is in `lab/RUNBOOK.md`.

The master VM is called `master` in virsh (older notes said `alma98`).

The `xcat` and `hpc_provisioning` roles pass `--syntax-check` and ansible-lint,
and their commands follow the xCAT 2.18 source, but they have **not yet run on
a live master**: snapshot before them.

## What inventory/kvm assumes

| Setting | Value | Why |
|---|---|---|
| `master_if_external` | `enp1s0` | libvirt network `default` (NAT) |
| `master_if_mgmt` | `enp7s0` | libvirt network `mgmt` (isolated, no DHCP) |
| `master_if_cluster` | `enp8s0` | libvirt network `hpc` (isolated, no DHCP); xCAT's DHCP is pinned to it |
| `bind_forwarders` | `192.168.122.1` | DNS of libvirt's `default` network |
| `bind_dnssec_validation` | `"no"` | libvirt's dnsmasq strips DNSSEC data |
| `nfs_require_separate_data_fs` | `true` | `/data` is its own virtual disk (`vdb`) |
| `xcat_iso_path` | `/data/isos/AlmaLinux-9-latest-x86_64-minimal.iso` | the Minimal ISO (SHA-256 checked); `provisioning.yml` |
| `xcat_install_repos` | Minimal + `/repos/baseos` + `/repos/appstream` | the installer also uses the master's full mirrors |
| `xcat_osver` | `alma9.8` | must match the ISO; the role reads the version from it |
| `xcat_root_mb` / `xcat_swap_mb` | `12288` / `2048` | node disk: /boot, swap, / fixed, `/scratch` = rest |
| `xcat_enable_dhcp` | `false` | Stop Gate D |
| `cluster_pkg_source` | `local` | nodes offline: packages from `/data/repos` on the master (Option A) |
| `xcat_mac` (host_vars) | `52:54:00:aa:bb:01`, `…:02` | one value for both the VM (`lab-node.sh`) and the xCAT node |
| `hpc_ipmi_function` | VirtualBMC `192.168.0.254:6231…` | `hpc-node` powers the VMs; password `vault_ipmi_password` |

Check the NIC names against `ip -br link` and `virsh domiflist master` (match
the MAC addresses) before the first run.

## The KVM host (Ubuntu or AlmaLinux)

| | Ubuntu | AlmaLinux |
|---|---|---|
| Packages | `apt install qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst virt-manager virt-viewer ipxe-qemu ansible-core` | `dnf install qemu-kvm libvirt virt-install virt-manager virt-viewer ansible-core` |
| Your user | `usermod -aG libvirt,kvm $USER` (log in again) | `usermod -aG libvirt $USER` |
| Image folder `/home/libvirt/images` | AppArmor: no label needed; `chmod o+x /home/libvirt` so the `libvirt-qemu` user can reach it | SELinux: `semanage fcontext -a -t virt_image_t '/home/libvirt/images(/.*)?'; restorecon -Rv /home/libvirt/images` |

Always use the system connection (`virsh -c qemu:///system`, or
`export LIBVIRT_DEFAULT_URI=qemu:///system`); the scripts here set it.
`ipxe-qemu` provides the NIC boot ROMs that PXE needs on Ubuntu.

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

**Upgrading from the Cobbler version:** see `MERGE-NOTES.md` for every file
that changed. In short: the inventory file is now `hosts.ini` (was `cobbler.ini`),
`roles/cobbler` and `roles/cobbler_provisioning` are gone (replaced by `roles/xcat`
and `roles/hpc_provisioning`), and these settings were renamed:

| Old | New |
|---|---|
| `inventory/kvm/cobbler.ini` | `inventory/kvm/hosts.ini` (plus the `[monitored]` group) |
| `cobbler_mac` (host_vars) | `xcat_mac` |
| `cobbler_distro_name`, `cobbler_arch` | `xcat_osver: alma9.8`, `xcat_arch` |
| `hpc_iso_file`, `hpc_iso_sha256` | `xcat_iso_path`, `xcat_iso_sha256` |
| `hpc_root_mb`, `hpc_swap_mb` | `xcat_root_mb`, `xcat_swap_mb` |
| `hpc_ipmi_*`, `hpc_validate_*` | unchanged (now read by `hpc_provisioning`) |
| `cobbler_run_sync` | `xcat_enable_dhcp` |

`vault.yml` and `files/munge.key` are not in the zip and stay as they are; add
`vault_grafana_admin_password` (monitoring) with `ansible-vault edit`.

## Run one role at a time, snapshot after each (on the host)

| Step | Command (in the VM) | Snapshot (on the host) |
|---|---|---|
| base | `ansible-playbook master.yml --tags base` | `virsh snapshot-create-as master 03-base` |
| time + accounts | `... --tags service_accounts,chrony` | `04-time` |
| DNS (Gate C) | `... --tags bind` | `05-dns` |
| self-DNS (manual, below) | `nmcli ...` | `06-selfdns` |
| local repo | `... --tags localrepo` | `07-repo` |
| data disk | `... --tags data` (after the host script, see below) | `07-data` |
| NFS | `... --tags nfs` | `08-nfs` |
| xCAT + hpc-node | `... --ask-vault-pass --tags xcat,provisioning` (DHCP stays off until Gate D) | `09-xcat` |
| Slurm | `... --ask-vault-pass --tags slurm` | `10-slurm` |
| Monitoring | `... --ask-vault-pass --tags monitoring` | `10b-monitoring` |
| Gate D | `... --ask-vault-pass --tags xcat -e xcat_enable_dhcp=true` | `11-dhcp` |
| node VMs | on the KVM host: `lab/lab-node.sh recreate 1` | (VMs, no snapshot) |
| node install | `hpc-node provision c01` | `12-node-c01` |

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

Only after `dig +short almalinux.org @127.0.0.1` returns an address. **The
xcat role needs this**: it stops if `getent ahostsv4 c01.hpc` does not give
192.168.17.1.

```bash
EXT=$(nmcli -g GENERAL.CONNECTION device show enp1s0)
CLU=$(nmcli -g GENERAL.CONNECTION device show enp8s0)
nmcli connection modify "$EXT" ipv4.ignore-auto-dns yes ipv4.dns ""
nmcli connection modify "$CLU" ipv4.dns 127.0.0.1 ipv4.dns-search "hpc mgmt"
nmcli connection up "$EXT"; nmcli connection up "$CLU"
cat /etc/resolv.conf; dig +short almalinux.org; dnf makecache
getent ahostsv4 c01.hpc; hostname -f       # 192.168.17.1 ... ; master.hpc
```

If anything breaks, undo with
`nmcli connection modify "$EXT" ipv4.ignore-auto-dns no` and bring it up again.

## Secrets (before the xcat and slurm roles)

```bash
INV=inventory/kvm
cp $INV/group_vars/master/vault.yml.example $INV/group_vars/master/vault.yml
openssl rand -base64 24        # -> vault_slurm_db_pass
openssl passwd -6              # -> vault_node_root_password_hash
#                                 vault_ipmi_password = the VBMC_PASS of lab-node.sh
openssl rand -base64 18        # -> vault_grafana_admin_password
vi $INV/group_vars/master/vault.yml
ansible-vault encrypt $INV/group_vars/master/vault.yml

dd if=/dev/urandom bs=1 count=1024 of=$INV/files/munge.key
ansible-vault encrypt $INV/files/munge.key
```

Add `--ask-vault-pass` to the xcat, slurm and monitoring runs. `hpc-node` runs
Ansible unattended, so also put the vault password in `/root/.vault_pass`
(`chmod 600`). Never commit the unencrypted files; back up the Munge key,
because it cannot be regenerated.

## /data disk, local home and the ISO

Three steps, the first on the KVM host (a VM cannot attach its own disk):

```bash
# 1. On the KVM host, as root. Safe to run twice.
./host-prep/attach-data-disk.sh master 80G
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
- mounts it by UUID and writes the `/etc/fstab` line (replacing a hand-made
  `LABEL=data /data` line, if you made one earlier)
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

**The ISO.** The lab uses the AlmaLinux 9.8 **Minimal** ISO already in
`/data/isos` (the one Cobbler used). xCAT copies it into `/install` (about
2 GB; the role checks the free space and the SHA-256 in `provisioning.yml`).
The Minimal ISO lacks some packages the install needs (`perl`, `wget`, ...):
the Kickstart therefore also uses the master's full mirrors `/repos/baseos`
and `/repos/appstream` (`xcat_install_repos`), and the role checks every
needed package is in the media or in `/data/repos` before going on.
Without such mirrors, use the DVD ISO instead.

"9-latest" means "newest 9.x at download time". The role reads the version
inside the ISO and stops if it is not `xcat_osver` (alma9.8).

## xCAT on the master

```bash
ansible-playbook master.yml --ask-vault-pass --tags xcat,provisioning
#   (or: ansible-playbook lab/provision-master.yml --ask-vault-pass)
source /etc/profile.d/xcat.sh             # xCAT commands in your shell
lsxcatd -a                                # version 2.18.x
tabdump site | grep -E '"(master|domain|dhcpinterfaces|nameservers|timezone)"'
lsdef -t network                          # only hpcnet
lsdef -t osimage                          # alma9.8-x86_64-install-compute + hpc-...
lsdef c01,c02                             # mac, ip, netboot=xnba, postbootscripts
systemctl is-active xcatd firewalld httpd tftp.socket
getenforce                                # Permissive
grep -E '^/(install|tftpboot)' /etc/exports || echo "no xCAT exports: OK"
firewall-cmd --zone=internal --list-all   # dhcp tftp http, ports 3001-3002, 514
```

What the role does, in order: adds the xcat-core 2.18 and xcat-dep repos,
installs xCAT, puts back firewalld / SELinux (permissive) / `/etc/exports`
(the package's own setup changes all three), fills the site and passwd
tables, keeps one network object (`hpcnet`, the cluster network), runs
`copycds`, creates the osimage `hpc-alma9.8-x86_64-install-compute` with
our Kickstart template, package list and first-boot script `hpc_bootstrap`,
defines c01/c02 and trusts the shared node host key in `/etc/ssh/ssh_known_hosts`.

Never run `makedns` or `makehosts`: BIND is managed by the bind role.

## Stop Gate D: DHCP on the hpc network

```bash
ansible-playbook master.yml --ask-vault-pass --tags xcat -e xcat_enable_dhcp=true
grep -E '^\s*subnet' /etc/dhcp/dhcpd.conf    # only 192.168.16.0 netmask 255.255.240.0
ps -C dhcpd -o args=                         # ... --no-pid enp8s0
makedhcp -q c01,c02                          # fixed addresses 192.168.17.1 / .2
```

The role pins `dhcpd` to `enp8s0` with a systemd drop-in, because the EL9
`dhcpd` unit ignores the interface setting xCAT writes. Without it, `dhcpd`
would answer on any NIC that has a subnet in its config.

Set `xcat_enable_dhcp: true` in `group_vars/master/provisioning.yml` once this
has passed, so later full runs keep DHCP on. Then run `lab/preflight.sh`: every
FAIL line must be fixed before the first `hpc-node provision`.

## Compute VMs and VirtualBMC (on the KVM host)

`lab/lab-node.sh` creates each node VM with the MAC from `host_vars`
(`52:54:00:aa:bb:0N`), network boot first, on the `hpc` network, plus a
VirtualBMC entry on `192.168.0.254:623N` so the master can power it over IPMI.

```bash
# once: VirtualBMC daemon (see lab/RUNBOOK.md)
cp lab/vbmcd.service /etc/systemd/system/ && systemctl enable --now vbmcd
# per node (wipes and recreates the VM)
VBMC_PASS=... HPC_NET=hpc ./lab/lab-node.sh recreate 1
./lab/lab-node.sh status 1
```

`host-prep/compute-vms.yml` is the alternative without VirtualBMC (e1000 NIC,
no BMC): then use `hpc-node provision c01 --no-power` and `virsh start c01`.

## Installing a node with hpc-node (on the master)

```bash
hpc-node provision c01        # asks you to type the node name; --yes skips that
hpc-node status               # NODE STATE NETBOOT XCAT SINCE JOB MESSAGE
hpc-node log c01              # the full run, live
```

What happens: `nodeset c01 osimage=hpc-alma9.8-x86_64-install-compute`,
IPMI power off/on through VirtualBMC, the VM's iPXE gets DHCP and xCAT's xNBA,
the installer runs from `/install/alma9.8` plus the `/repos` mirrors, xCAT's
scripts run and the node reboots from its disk (xCAT now answers its network
boot with "boot from disk"). With SELinux enforcing the first boot relabels and
reboots once more. Then `hpc_bootstrap` sets the static address, chrony and the
master's key, xCAT marks the node `booted`, and the worker runs `compute.yml` and
`validate-compute.yml`. States: APPROVED → INSTALLING → INSTALLED →
NETBOOT_DISABLED → CONFIGURING → VALIDATING → READY.

Watch it on the host with `virsh console c01` (Ctrl+] to leave). To re-run only
the configuration: `hpc-node configure c01`. To stop a pending install:
`hpc-node cancel c01`.

## Slurm nodes

Slurm runs jobs on the hosts in `[slurm_nodes]` in `inventory/kvm/hosts.ini`
(`slurm_compute_group: slurm_nodes`): the master, c01 and c02. The values in
`host_vars/*.yml` (`slurm_node_params`) come from `slurmd -C` on each host;
redo them if you change a VM's CPUs or memory, then run `master.yml --tags slurm`
(rewrites slurm.conf) and `compute.yml --tags slurm`.

## Monitoring: Prometheus and Grafana

Needs the Slurm role first (the Slurm exporter calls `sinfo`, `squeue`, ...)
and one more secret:

```bash
ansible-vault edit inventory/kvm/group_vars/master/vault.yml
#   vault_grafana_admin_password: "<openssl rand -base64 18>"
ansible-playbook master.yml --ask-vault-pass --tags monitoring
```

The master downloads Prometheus 3.13.5 (LTS), Alertmanager 0.35.0,
node_exporter 1.12.1 and slurm_exporter 1.8.6 from GitHub into
`/opt/monitoring-dist` (checked against each project's SHA-256 list), and
installs Grafana from rpm.grafana.com. Everything listens on 127.0.0.1
except node_exporter (:9100, which on the compute nodes only the master may reach).

```bash
systemctl is-active node_exporter prometheus alertmanager slurm_exporter grafana-server
curl -s 127.0.0.1:9090/api/v1/targets | python3 -m json.tool | grep -E '"(job|instance|health)"'
curl -s 127.0.0.1:9341/metrics | grep -c '^slurm_'     # > 0
```

From your own machine (Africa → the KVM host or Trieste), tunnel the web pages:

```bash
ssh -L 3000:localhost:3000 -L 9090:localhost:9090 -L 9093:localhost:9093 root@MASTER
# Grafana http://localhost:3000 (admin), Prometheus :9090, Alertmanager :9093
```

In the KVM lab the master is reached through the host, so chain it:
`ssh -J you@KVM-HOST -L 3000:localhost:3000 root@192.168.122.x`.

Grafana opens with two folders: **Nodes** (Node Exporter Full, NFS) and
**Slurm** (overview, jobs, nodes, usage, scheduler, exporter health). EPEL's
Slurm is 22.05, older than the exporter's tested 23–26 range: if "Exporter
Health" shows a collector as FAIL, switch it off with
`monitoring_slurm_exporter_args: ["--no-collector.NAME"]`.

**Compute nodes**: `compute.yml` (run by `hpc-node`) installs node_exporter on
them and lets only the master scrape it. `[monitored]` in `hosts.ini` already
lists c01 and c02; a node that is not installed only shows as down.
