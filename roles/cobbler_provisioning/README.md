# cobbler_provisioning

Repeatable, unattended reinstall of HPC compute nodes (c01–c16) on AlmaLinux 9.8 with
Cobbler PXE + kickstart, followed by automatic Ansible configuration and validation.

## Install into /opt/hpc-ansible

    tar xzf cobbler_provisioning.tar.gz -C /opt/hpc-ansible/roles/
    # add the role to the master play in master.yml:
    #   roles:
    #     - cobblerd
    #     - cobbler_provisioning      # after cobblerd
    ansible-playbook -i inventory/kvm/cobbler.ini master.yml --tags all

Override defaults (profile name, NIC, IPMI command, validation checks) in
`group_vars/<master group>.yml` — see `defaults/main.yml`.

Install media only (verify the ISO you copied to /data/isos, then `cobbler import`):

    ansible-playbook -i inventory/kvm/cobbler.ini master.yml --tags media

## Use

    hpc-node provision c01      # erase + reinstall + configure + validate, unattended
    hpc-node status             # one line per node: state, netboot flag, job, message
    hpc-node log c01            # follow the run
    hpc-node configure c02      # re-run Ansible + validation only (no reinstall, data kept)
    hpc-node cancel c01         # abort: netboot off, mark FAILED

## What it installs

| Path | Purpose |
| --- | --- |
| /var/lib/cobbler/templates/hpc-compute.ks | the one kickstart all compute nodes use |
| /var/lib/cobbler/triggers/install/{pre,post}/90_hpc-queue.sh | drop install events into /var/lib/cobbler/hpc-queue |
| /usr/local/sbin/hpc-node | admin CLI |
| /usr/local/sbin/hpc-provision-dispatch | turns queued events into states (hpc-provision.path/.service) |
| /usr/local/sbin/hpc-node-configure | per-node worker (hpc-configure@<node>.service) |
| /etc/hpc-provision.conf | paths, IPMI function, timeouts |
| /opt/hpc-ansible/validate-compute.yml | mandatory checks before READY |
| /opt/hpc-ansible/provisioning/state/nodes/<node> | state history (tab separated) |
| /opt/hpc-ansible/provisioning/logs/<node>-<job>.log | full log of each run |

Cobbler settings changed: `pxe_just_once: true`, `run_install_triggers: true`.
