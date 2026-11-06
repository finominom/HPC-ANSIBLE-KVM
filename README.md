# hpc-ansible

Builds the UNIBEN HPC master and compute nodes on AlmaLinux 9, following
**HPC Master Node Runbook rev 1.1**. The same roles serve two clusters:

| Inventory | Use |
|---|---|
| `inventory/vbox` (default) | VirtualBox rehearsal: NICs `enp0s3/8/9`, nodes get packages through the master (NAT) |
| `inventory/supermicro` | Real cluster: NICs `eno1/2/3`, local repositories only. Campus DNS still to fill in |

## What each role does

| Role | Runs on | Runbook | Does |
|---|---|---|---|
| `base` | all | 1, 2 (checks), 3, 9.4 | hostname, time zone, EPEL/CRB or local repos, base packages, firewall zones, NAT (nat mode), root SSH key |
| `service_accounts` | all | 15 | fixed IDs: tutors 5000, install 5001, munge 5100, slurm 5101 |
| `chrony` | all | 4 | master syncs upstream and serves 192.168.16.0/20 and 192.168.0.0/20; nodes sync from the master |
| `bind` | master | 5 | `.hpc` and `.mgmt` zones, reverse zones, forwarders, then tests lookups (stop gate C) |
| `localrepo` | master | 9.2 | `http://192.168.16.1/foo` |
| `nfs_server` | master | 9.1 | exports `/data/home` (rw, root_squash) and `/data/opt` (ro), plus autofs `/home` → `/data/home` on the master |
| `cobbler` | master | 12 | Cobbler, DHCP (cluster subnet only), TFTP, legacy-BIOS PXE, Kickstart, ISO import, system records. **No `cobbler sync` until you allow it** (stop gate D) |
| `nfs_client` | compute | — | autofs `/home/USER` and `/data/opt` from the master |
| `slurm` | all | 13 | Munge, MariaDB + slurmdbd + slurmctld (master), slurmd (nodes) |

DNS names and addresses come from one place: `cluster_hosts` in
`inventory/<name>/group_vars/all.yml`. Add a node there and in `cobbler.ini`,
and DNS, Cobbler and Slurm all pick it up.

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

# 3. AlmaLinux DVD ISO for Cobbler (check it against the published CHECKSUM)
mkdir -p /srv/isos            # put AlmaLinux-9.8-x86_64-dvd.iso here
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

Tags: `base`, `service_accounts`, `chrony`, `bind`/`dns`, `localrepo`, `nfs`,
`cobbler`, `slurm` (plus `slurm_config`, `slurm_controller` and others).

Running a playbook again only changes what differs from the configuration.

## Provisioning the compute nodes (stop gate D)

1. Put each node's MAC in `host_vars/cNN.hpc.yml` as `cobbler_mac`, then run `--tags cobbler`.
2. Read what Cobbler will send a node:
   `cobbler system get-autoinstall --name=c01 | less`
   Then fix anything `cobbler check` reports.
3. Allow the sync (this writes `dhcpd.conf` and starts DHCP on the cluster network):
   `ansible-playbook master.yml --ask-vault-pass --tags cobbler -e cobbler_run_sync=true`
4. Check `grep subnet /etc/dhcp/dhcpd.conf`. It should show **only** `192.168.16.0`.
5. PXE-boot c01 alone. When it has installed and rebooted, check that `ssh c01.hpc` works.
6. Configure it: `ansible-playbook compute.yml --ask-vault-pass --limit c01.hpc`
7. Repeat for c02.

The Kickstart **wipes every disk** on the node it installs. `pxe_just_once`
stops a node from reinstalling at every boot.

## Checking the master

```bash
systemctl is-active firewalld chronyd named httpd nfs-server autofs cobblerd munge mariadb slurmdbd slurmctld
firewall-cmd --get-active-zones           # external in public, mgmt + cluster in internal
chronyc sources
dig +short c01.hpc @127.0.0.1; dig +short -x 192.168.17.1 @127.0.0.1
exportfs -v
cobbler check; cobbler profile list
sinfo; sacctmgr show cluster
```

Once BIND works, point the master at itself (runbook 8.5):

```bash
nmcli connection modify <external-profile> ipv4.ignore-auto-dns yes ipv4.dns ""
nmcli connection modify <cluster-profile> ipv4.dns 127.0.0.1 ipv4.dns-search "hpc mgmt"
nmcli connection up <external-profile>; nmcli connection up <cluster-profile>
```

## Option A (Supermicro, `cluster_pkg_source: local`)

Nodes install from the master's Cobbler mirror (BaseOS, AppStream) and from
`/var/www/html/foo`. Packages from EPEL, Slurm included, must be copied into
`foo` before running `compute.yml`:

```bash
cd /var/www/html/foo
dnf download --resolve slurm slurm-slurmd munge munge-libs   # on the master
createrepo_c --update /var/www/html/foo
# test from c01:  dnf --disablerepo='*' --enablerepo='hpc-*' install slurm-slurmd
```

## Not covered yet

- Compilers, OpenMPI and the Lmod software tree
- Ganglia
- User account propagation (real users, not service accounts)
- Terraform declarations
- A dedicated login node
- MariaDB hardening

## Troubleshooting

| Symptom | Check |
|---|---|
| base stops on addresses or default route | `ip -br address`, `ip route`; fix with nmcli, or correct `master_if_*` |
| bind stops on the lookup test | `journalctl -u named -b`; the addresses in `cluster_hosts` |
| External names don't resolve | `bind_forwarders`; try `bind_dnssec_validation: "no"` |
| nfs stops on `/home` | move the listed folders to `/data/home/` |
| cobbler stops on a missing settings key | different Cobbler version: compare `/etc/cobbler/settings.yaml` with `cobbler_settings` |
| PXE gets no DHCP offer | `cobbler_run_sync` done? `systemctl status dhcpd`; node on the `hpc` network; `firewall-cmd --zone=internal --list-services` |
| Node reinstalls every boot | `autoinstall_done` ran? `cobbler system edit --name=c01 --netboot-enabled=false` |
| slurm node `down` | `scontrol show node c01`; same Munge key, time in sync, port 6818 open, `slurm_node_params` correct |
