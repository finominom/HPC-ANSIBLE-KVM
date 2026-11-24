# Role: xcat

Turns the master into the xCAT management node for the compute nodes.
It replaces the old `cobbler` role and does the same job: DHCP on the
cluster network only, PXE (xNBA) and HTTP, AlmaLinux media on the
master, a Kickstart with the HPC settings, one record per node, and a stop
gate before DHCP goes live.

## Cobbler → xCAT, side by side

| Cobbler (old role) | xCAT (this role) |
|---|---|
| `dnf install cobbler dhcp-server tftp-server syslinux…` | `dnf install xCAT` from the xcat-core 2.18 and xcat-dep repositories |
| `/etc/cobbler/settings.yaml` (`server`, `next_server_v4`, `manage_dhcp`) | site table: `master`, `domain`, `nameservers`, `dhcpinterfaces` |
| `/etc/cobbler/dhcp.template` subnet block | network object `hpcnet` (every other network object is removed) |
| `cobbler import --path=/mnt/iso` | `copycds -n alma9.8 -a x86_64 ISO` → `/install/alma9.8/x86_64` |
| profile `AlmaLinux-9.8-x86_64` + `hpc-minimal.ks` | osimage `hpc-alma9.8-x86_64-install-compute`, template `/install/custom/install/hpc/hpc-compute.tmpl` |
| `default_password_crypted` | `passwd` table: `key=system`, `username=root`, the `$6$` hash |
| `cobbler system add --mac --ip-address --static` | `mkdef -t node c01 mac=… ip=… netboot=xnba` + `hpc_bootstrap` sets the static address at first boot |
| Kickstart `%post` (chrony, root key) | postbootscript `/install/postscripts/hpc_bootstrap` |
| `cobbler system get-autoinstall --name=c01` | `nodeset c01 osimage=…`, then `less /install/autoinst/c01` |
| `cobbler sync` (Stop Gate D) | `-e xcat_enable_dhcp=true` → `makedhcp -n`, `makedhcp c01,c02` |
| `pxe_just_once` | built in: after the install xCAT switches the node to boot from disk |
| `cobbler system edit --netboot-enabled=false` | `nodeset c01 boot` |
| distro mirror `/cobbler/distro_mirror/…/BaseOS` | `/install/alma9.8/x86_64/BaseOS` (xCAT also writes a repo file on each node) |

## What `dnf install xCAT` changes, and what the role puts back

The package runs `xcatconfig -i` on first install. It:

| xcatconfig does | Role does afterwards |
|---|---|
| sets `SELINUX=disabled` | sets **permissive** (xCAT does not support enforcing on the management node) |
| stops and disables firewalld | starts and enables firewalld; zones and the NAT policy are permanent, so they return |
| adds `/install` and `/tftpboot` to `/etc/exports` for `*` with `rw,no_root_squash` | removes both lines (installs use HTTP) |
| adds every NIC's subnet to the networks table | keeps only `hpcnet` |
| enables `named` | nothing: BIND stays under the bind role. **Never run `makedns`**: it rewrites `named.conf` |

## Stop Gate D

1. Run with the gate closed (default): `ansible-playbook master.yml --ask-vault-pass --tags xcat`
2. Read: `lsdef -t osimage -o hpc-alma9.8-x86_64-install-compute`, `lsdef c01,c02`,
   the template and `/install/postscripts/hpc_bootstrap`
3. Open the gate: `... --tags xcat -e xcat_enable_dhcp=true`. The role stops if
   `dhcpd.conf` has any subnet other than 192.168.16.0/20, and pins `dhcpd` to
   the cluster NIC with a systemd drop-in.
4. Install one node: `nodeset c01 osimage=hpc-alma9.8-x86_64-install-compute`,
   `less /install/autoinst/c01`, then start the VM (`virsh start c01` on the host).

## Variables you are most likely to change

| Variable | Default | Notes |
|---|---|---|
| `xcat_iso_path` | `/data/isos/AlmaLinux-9-latest-x86_64-dvd.iso` | DVD ISO. The role checks the version inside matches `xcat_osver` |
| `xcat_osver`, `xcat_arch` | group_vars/all.yml | `alma9.8`, `x86_64` |
| `xcat_enable_dhcp` | `false` | Stop Gate D |
| `xcat_node_selinux` | `enforcing` | nodes relabel once on first boot |
| `xcat_sshbetweennodes` | `NOGROUPS` | `compute` copies the master's root private key to the nodes |
| `xcat_dynamic_range` | `""` | set only for node discovery |
| `xcat_use_ipmi` | `false` | Supermicro: `true`, with `xcat_bmc_username` and `vault_bmc_password` |
