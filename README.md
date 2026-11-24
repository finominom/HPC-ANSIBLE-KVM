# hpc-ansible

Builds the UNIBEN HPC master and compute nodes on AlmaLinux 9, following
**HPC Master Node Runbook rev 1.1**. The same roles serve three inventories:

| Inventory | Use |
|---|---|
| `inventory/kvm` (default) | KVM/libvirt rehearsal (virt-manager, QEMU): NICs `enp1s0/7s0/8s0`, nodes offline: packages from the master's mirrors in `/data/repos` (local mode), VirtualBMC power control. See KVM-NOTES.md and `lab/` |
| `inventory/vbox` | VirtualBox rehearsal: NICs `enp0s3/8/9`, NAT |
| `inventory/supermicro` | Real cluster: NICs `eno1/2/3`, local repositories only, IPMI power control. Campus DNS still to fill in |

Compute nodes are installed by **xCAT** (role `xcat`), which replaced Cobbler.
`roles/xcat/README.md` maps every Cobbler step to its xCAT equivalent.

## What each role does

| Role | Runs on | Runbook | Does |
|---|---|---|---|
| `base` | all | 1, 2 (checks), 3, 9.4 | hostname, time zone, EPEL/CRB or local repos, base packages, firewall zones, NAT (nat mode), root SSH key |
| `service_accounts` | all | 15 | fixed IDs: tutors 5000, install 5001, munge 5100, slurm 5101 |
| `chrony` | all | 4 | master syncs upstream and serves 192.168.16.0/20 and 192.168.0.0/20; nodes sync from the master |
| `bind` | master | 5 | `.hpc` and `.mgmt` zones, reverse zones, forwarders, then tests lookups (stop gate C) |
| `localrepo` | master | 9.2 | `http://192.168.16.1/foo` (the KVM lab serves its mirrors from `/data/repos` at `/repos/`) |
| `nfs_server` | master | 9.1 | exports `/data/home` (rw, root_squash) and `/data/opt` (ro), plus autofs `/home` → `/data/home` on the master |
| `data_disk` | master | 9.1 | formats and mounts the `/data` disk, moves local homes there (KVM inventory only) |
| `xcat` | master | 12 | xCAT 2.18: DHCP (cluster NIC only), TFTP/xNBA PXE, HTTP, `copycds` of the ISO, HPC osimage (Kickstart, package list, first-boot script), node definitions, node host keys. **No DHCP until you allow it** (stop gate D) |
| `hpc_provisioning` | master | 12 | `hpc-node` controller: `hpc-node provision c01` = reinstall with xCAT, then `compute.yml`, then `validate-compute.yml`, unattended, with a state history per node. See `roles/hpc_provisioning/README.md` |
| `nfs_client` | compute | — | autofs `/home/USER` and `/data/opt` from the master |
| `compute_packages` | master / compute | — | optional: stage node software into `foo` with all dependencies (not in the playbooks by default) |
| `slurm` | all | 13 | Munge, MariaDB + slurmdbd + slurmctld (master), slurmd (nodes) |
| `monitoring` | all | — | node_exporter everywhere; Prometheus, Alertmanager, Grafana and the Slurm exporter on the master. See `roles/monitoring/README.md` |

DNS names and addresses come from one place: `cluster_hosts` in
`inventory/<name>/group_vars/all.yml`. Add a node there, in `hosts.ini`, and
give it `xcat_mac` in `host_vars/`, and DNS, xCAT and Slurm all pick it up.

## Before the first run (done by hand)

Follow runbook Phases 0–2 on the master:

1. Install AlmaLinux 9.8 Minimal.
2. Give the NICs their addresses: management `192.168.1.1/20`, cluster
   `192.168.16.1/20`, both with `ipv4.never-default yes`. External on DHCP
   (VirtualBox NAT) or the campus address.
3. Check that the internet works: `ping -c2 almalinux.org`.
4. In VirtualBox, take a snapshot.

The `base` role checks the addresses and the default route, and stops if they're wrong.

## One-time setup

All commands run as root on the master. Use the **same vault password** for every encrypted file in an inventory.

```bash
dnf -y install ansible-core git unzip
cd /opt && unzip /root/hpc-ansible.zip && cd /opt/hpc-ansible
ansible-galaxy collection install -r requirements.yml
git init && git add -A && git commit -m "Initial HPC Ansible project"

INV=inventory/vbox            # or inventory/supermicro

# 1. Secrets file
cp $INV/group_vars/master/vault.yml.example $INV/group_vars/master/vault.yml
openssl rand -base64 24       # -> vault_slurm_db_pass
openssl passwd -6             # -> vault_node_root_password_hash (node root password)
vi $INV/group_vars/master/vault.yml
ansible-vault encrypt $INV/group_vars/master/vault.yml

# 2. Munge key for this cluster
dd if=/dev/urandom bs=1 count=1024 of=$INV/files/munge.key
ansible-vault encrypt $INV/files/munge.key

# 3. AlmaLinux ISO for xCAT (check it against the published CHECKSUM).
#    Must be the release in xcat_osver (alma9.8); the role checks.
#    KVM lab: the Minimal ISO in /data/isos plus the /data/repos mirrors.
#    Without full mirrors use the DVD ISO.
mkdir -p /srv/isos            # put AlmaLinux-9.8-x86_64-dvd.iso here (KVM: /data/isos)
```

Also check:

- `$INV/group_vars/master/main.yml`: the NIC names match `ip -br link`. On the Supermicro, also set the campus DNS forwarders.
- `$INV/host_vars/c01.hpc.yml`: `slurm_node_params`. Until the node exists, use the CPU and RAM you plan to give it. Afterwards, replace with the output of `slurmd -C`.
- `/home` on the master: if the installer created a user there, move it with `mv /home/NAME /data/home/`. Otherwise the NFS role stops, because autofs would hide it.

## Running

```bash
# Master - whole thing, or one role at a time with --tags
ansible-playbook master.yml --ask-vault-pass
ansible-playbook master.yml --ask-vault-pass --tags bind

# Real cluster
ansible-playbook -i inventory/supermicro master.yml --ask-vault-pass
```

Tags: `base`, `service_accounts`, `chrony`, `bind`/`dns`, `localrepo`, `data`, `nfs`,
`xcat` (plus `xcat_install`, `xcat_tables`, `xcat_media`, `xcat_osimage`,
`xcat_nodes`, `xcat_dhcp`), `slurm` (plus `slurm_config`, `slurm_controller` and others),
`monitoring` (plus `node_exporter`, `prometheus`, `grafana`).

Running a playbook again only changes what differs from the configuration.

## Provisioning the compute nodes (stop gate D)

Before: the bind role has run **and** the master uses its own DNS (runbook 8.5).
The xcat role stops if `getent ahostsv4 c01.hpc` does not give 192.168.17.1.

1. Put each node's MAC in `host_vars/cNN.hpc.yml` as `xcat_mac` (and the xCAT and
   hpc-node settings in `group_vars/master/provisioning.yml`), then run
   `ansible-playbook master.yml --ask-vault-pass --tags xcat,provisioning`
   (installs xCAT, copies the ISO into `/install`, defines the osimage and the
   nodes, installs `hpc-node`; no DHCP yet). `lab/provision-master.yml` runs only these two roles.
2. Read what a node will get:
   `lsdef -t osimage -o hpc-alma9.8-x86_64-install-compute`, `lsdef c01`,
   `less /install/custom/install/hpc/hpc-compute.tmpl /install/postscripts/hpc_bootstrap`.
3. Allow DHCP (writes `dhcpd.conf`, starts `dhcpd` on the cluster NIC only, adds the nodes):
   `ansible-playbook master.yml --ask-vault-pass --tags xcat -e xcat_enable_dhcp=true`
   The role stops if `dhcpd.conf` has any subnet other than `192.168.16.0`.
   Then set `xcat_enable_dhcp: true` in `provisioning.yml`. Run `lab/preflight.sh` (KVM).
4. Put the vault password in `/root/.vault_pass` (mode 0600) so the unattended
   Ansible step can read the vault.
5. Reinstall a node: `hpc-node provision c01`. It runs `nodeset`, power-cycles the
   node through IPMI (VirtualBMC in the lab; `--no-power` = start it yourself),
   follows the install through xCAT's status, runs `compute.yml` and
   `validate-compute.yml`, and marks the node READY or FAILED.
   Follow it: `hpc-node status`, `hpc-node log c01`; on the KVM host `virsh console c01`.
6. Re-run only the configuration (no reinstall, data kept): `hpc-node configure c02`.

By hand, without `hpc-node`: `nodeset c01 osimage=hpc-alma9.8-x86_64-install-compute`,
`less /install/autoinst/c01`, power the node on, wait for `lsdef c01 -i status` to say
`booted`, then `ansible-playbook compute.yml --ask-vault-pass --limit c01.hpc`.

The install **wipes the install disk** of the node. After the install xCAT answers
that node's network boot with "boot from disk", so it does not reinstall; only a new
`nodeset ... osimage=` (or `hpc-node provision`) does. `hpc-node cancel c01` or
`nodeset c01 boot` cancels a pending reinstall.

## Checking the master

```bash
systemctl is-active firewalld chronyd named httpd nfs-server autofs xcatd dhcpd munge mariadb slurmdbd slurmctld \
  node_exporter prometheus alertmanager slurm_exporter grafana-server
firewall-cmd --get-active-zones           # external in public, mgmt + cluster in internal
chronyc sources
dig +short c01.hpc @127.0.0.1; dig +short -x 192.168.17.1 @127.0.0.1
exportfs -v
lsxcatd -a; lsdef -t osimage; lsdef -t network; tabdump site | grep -E 'master|domain|dhcpinterfaces'
sinfo; sacctmgr show cluster
```

Once BIND works, point the master at itself (runbook 8.5):

```bash
nmcli connection modify <external-profile> ipv4.ignore-auto-dns yes ipv4.dns ""
nmcli connection modify <cluster-profile> ipv4.dns 127.0.0.1 ipv4.dns-search "hpc mgmt"
nmcli connection up <external-profile>; nmcli connection up <cluster-profile>
```

## Monitoring (Prometheus + Grafana)

```bash
ansible-vault edit inventory/kvm/group_vars/master/vault.yml   # add vault_grafana_admin_password
ansible-playbook master.yml --ask-vault-pass --tags monitoring
# from your own machine:
ssh -L 3000:localhost:3000 -L 9090:localhost:9090 root@MASTER
# then http://localhost:3000 (Grafana, user admin) and http://localhost:9090 (Prometheus)
```

Compute nodes get node_exporter from `compute.yml`. Prometheus scrapes the
hosts in the `[monitored]` inventory group: in the KVM inventory add c01/c02
there once they are installed, then re-run `master.yml --tags monitoring`.

## Option A (`cluster_pkg_source: local`)

Nodes have no internet. They install from the ISO copied into `/install` plus the
repositories listed in `xcat_install_repos`, and later get packages only from
the master (`roles/base/templates/hpc-local.repo.j2`). In the KVM lab these
are the mirrors in `/data/repos`, served at `http://192.168.16.1/repos/`:
`baseos`, `appstream`, `crb` and `epel-lmod` (Slurm, MUNGE, Lmod). The
`compute_packages` role can instead stage packages into `foo` with all their
dependencies.

## Not covered yet

- The Lmod software tree in `/data/opt` (compilers and OpenMPI come from `compute.yml`)
- User account propagation (real users, not service accounts)
- Terraform declarations
- xCAT's own `rpower` in the lab: VirtualBMC uses one IP with many ports, which xCAT cannot address; `hpc-node` powers the VMs instead
- A dedicated login node
- MariaDB hardening

## Troubleshooting

| Symptom | Check |
|---|---|
| base stops on addresses or default route | `ip -br address`, `ip route`; fix with nmcli, or correct `master_if_*` |
| bind stops on the lookup test | `journalctl -u named -b`; the addresses in `cluster_hosts` |
| External names don't resolve | `bind_forwarders`; try `bind_dnssec_validation: "no"` |
| nfs stops on `/home` | move the listed folders to `/data/home/` |
| xcat stops on a DNS lookup | bind role run? master using its own DNS (runbook 8.5)? `getent ahostsv4 c01.hpc` |
| xcat stops after copycds: missing packages | Minimal ISO without full mirrors: add them to `xcat_install_repos` / `xcat_pkg_search_dirs`, or use the DVD ISO |
| xcat stops: ISO version differs | the "9-latest" ISO is a newer minor release: use the matching ISO or change `xcat_osver` |
| `xcat` commands not found in your shell | `source /etc/profile.d/xcat.sh` (or log in again) |
| PXE gets no DHCP offer | `xcat_enable_dhcp` run done? `systemctl status dhcpd`; `makedhcp -q c01`; MAC in `lsdef c01` = VM MAC; node on the `hpc` network |
| Node gets DHCP, then "No such file" | `nodeset c01 osimage=...` run? `ls /tftpboot/xcat/xnba/nodes/c01`; `firewall-cmd --zone=internal --list-services` has tftp, http |
| Install stops at the package step | `/var/log/xcat/xcat.log` on the master; the media lacks a package (Minimal ISO) |
| Node status stays `installing` | port 3002 open on the internal zone; `tail /var/log/xcat/cluster.log` |
| `ssh c01.hpc` asks for a password | `hpc_bootstrap` ran? On the node: `journalctl -t hpc_bootstrap`; `/var/log/xcat/xcat.log` |
| Node reinstalls every boot | someone ran `nodeset c01 osimage=...` again: `nodeset c01 boot` |
| `hpc-node` stops at APPROVED | IPMI did not power the node: VirtualBMC running on the host? `ipmi c01 power status` after `source /etc/hpc-provision.conf`; or use `--no-power` |
| `hpc-node` FAILED at CONFIGURING | `/root/.vault_pass` missing, or `compute.yml` failed: `hpc-node log c01` |
| monitoring: a node target is down | `[monitored]` lists a node not installed yet; else on the node `systemctl status node_exporter`, `firewall-cmd --zone=internal --list-rich-rules` |
| monitoring: Slurm dashboards empty | `systemctl status slurm_exporter`; `curl -s 127.0.0.1:9341/metrics \| head`; the "Exporter Health" dashboard shows failing collectors |
| monitoring: download fails | the master needs github.com and rpm.grafana.com; `curl -I https://github.com` |
| slurm node `down` | `scontrol show node c01`; same Munge key, time in sync, port 6818 open, `slurm_node_params` correct |
