# hpc_provisioning

Unattended reinstall of compute nodes with xCAT, followed by automatic Ansible
configuration (`compute.yml`) and validation (`validate-compute.yml`). This is
the Cobbler-era `cobbler_provisioning` controller ported to xCAT: same commands,
same states, same state and log files.

## Use (on the master, as root)

    hpc-node provision c01      # erase + reinstall + configure + validate, unattended
    hpc-node status             # one line per node: state, netboot, xCAT status, job, message
    hpc-node log c01            # follow the run
    hpc-node configure c02      # re-run Ansible + validation only (no reinstall, data kept)
    hpc-node cancel c01         # abort: boot from disk, mark FAILED

`--no-power` skips IPMI: start the VM yourself (`virsh start c01` on the host).
For unattended Ansible runs put the vault password in `/root/.vault_pass` (mode 0600).

## What changed from the Cobbler version

| Cobbler (`cobbler_provisioning`) | xCAT (`hpc_provisioning`) |
|---|---|
| `cobbler system edit --netboot-enabled=1` + `cobbler sync` | `nodeset c01 osimage=hpc-alma9.8-x86_64-install-compute` |
| Kickstart `%pre`/`%post` call `/cblr/svc/op/trig/...` → trigger → queue → `hpc-provision.path` → dispatcher | the worker follows xCAT's own node status: `installing` → `booting` → `booted` |
| Kickstart calls `/cblr/svc/op/nopxe/...` (netboot off) | xCAT switches the node to "boot from disk" at the end of the install; the worker checks `chain.currstate` and runs `nodeset c01 boot` if needed |
| job ID passed as Cobbler autoinstall-meta | `hpc-node` writes `/install/hpc-provision/jobs/c01`; the Kickstart copies it to `/etc/hpc-provision-job` |
| new random host keys at every install (forget + ssh-keyscan) | xCAT gives every node the same host keys, trusted in `/etc/ssh/ssh_known_hosts` |
| NETBOOT column True/False | NETBOOT column `install`/`boot`, plus the XCAT status column |

States: APPROVED → INSTALLING → INSTALLED → NETBOOT_DISABLED → CONFIGURING → VALIDATING → READY (or FAILED).

## Files

| Path | Purpose |
|---|---|
| /usr/local/sbin/hpc-node | admin CLI |
| /usr/local/sbin/hpc-node-configure | per-node worker (hpc-configure@<node>.service) |
| /usr/local/lib/hpc-provision/lib.sh | shared helpers |
| /etc/hpc-provision.conf | paths, osimage, IPMI function, timeouts |
| /install/hpc-provision/jobs/<node> | job ID the node fetches during the install |
| /opt/hpc-ansible/validate-compute.yml | mandatory checks before READY |
| /opt/hpc-ansible/provisioning/state/nodes/<node> | state history (tab separated) |
| /opt/hpc-ansible/provisioning/logs/<node>-<job>.log | full log of each run |
