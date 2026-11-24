# Merge notes: Cobbler → xCAT, plus Prometheus/Grafana

This tree is your `hpc-ansible-main` (24 Nov 2026) with Cobbler replaced by
xCAT 2.18 and monitoring added. Your newer work is kept: `lab/` (VirtualBMC,
`lab-node.sh`), `roles/compute_packages`, local-mode mirrors, `validate-compute.yml`,
the `hpc-node` workflow and your inventory values (IPs, MACs, `slurm_node_params`,
`[slurm_nodes]` = c01, c02, master).

## Removed

| Path | Why |
|---|---|
| `roles/cobbler` | replaced by `roles/xcat` |
| `roles/cobbler_provisioning` | ported to `roles/hpc_provisioning` (same `hpc-node` commands and states) |
| `inventory/*/cobbler.ini` | renamed `hosts.ini` (`ansible.cfg` points to `inventory/kvm/hosts.ini`) |
| `slurm-2.out`, `hpc-ansible-roles-fixed-v2.tar.gz`, `provisioning/` | job output, an old archive and runtime state; not source |

## Added

| Path | What |
|---|---|
| `roles/xcat` | xCAT repos and install, site table, networks, `copycds` of the Minimal ISO (SHA-256 checked), osimage `hpc-alma9.8-x86_64-install-compute`, Kickstart (your partition layout, mirrors, `/scratch`), node definitions, DHCP (gate D) |
| `roles/hpc_provisioning` | `hpc-node` / `hpc-node-configure` / `hpc-configure@.service` for xCAT. It removes the old Cobbler `hpc-provision.path` units and queue |
| `roles/monitoring` | Prometheus 3.13 LTS, Alertmanager, node_exporter (all hosts), Slurm exporter and Grafana (master) |
| `inventory/*/hosts.ini` `[monitored]` | hosts scraped by Prometheus |
| `MERGE-NOTES.md` | this file |

## Changed in your files

| File | Change |
|---|---|
| `master.yml` | roles `cobbler`, `cobbler_provisioning` → `xcat` [tag xcat], `hpc_provisioning` [tag provisioning]; `monitoring` added last |
| `compute.yml` | `monitoring` role added after `slurm` (node_exporter); comment updated |
| `lab/provision-master.yml` | runs `xcat` + `hpc_provisioning` |
| `lab/preflight.sh` | rewritten for xCAT: ISO, site, networks, osimage, mirrors, node defs, DHCP, firewall, SELinux, exports, hpc-node, vault pass, VirtualBMC |
| `lab/RUNBOOK.md`, `lab/lab-node.sh` | Cobbler steps → xCAT (`nodeset`, `hpc-node`) |
| `inventory/kvm/group_vars/master/provisioning.yml` | Cobbler keys → `xcat_*`; `hpc_ipmi_*` / `hpc_validate_*` kept |
| `inventory/kvm/group_vars/all.yml` | `cobbler_distro_name`/`cobbler_arch` → `xcat_osver: alma9.8`, `xcat_arch` |
| `inventory/kvm/group_vars/master/main.yml` | Cobbler vars removed; VM name `master` |
| `inventory/*/host_vars/c0*.yml` | `cobbler_mac` → `xcat_mac` (same values) |
| `inventory/*/vault.yml.example` | adds `vault_ipmi_password`, `vault_grafana_admin_password`, `vault_alert_smtp_password` (optional) |
| `roles/base/tasks/main.yml` | local mode also removes the installer's `local-repository-0.repo` before the update |
| `roles/data_disk/tasks/dirs.yml` | explicit `mode: "0755"` (lint) |
| `roles/slurm/defaults/main.yml` | comment: `hosts.ini` |
| `host-prep/*` | `xcat_mac`; works on an Ubuntu or AlmaLinux host |
| `.gitignore` | also ignores `.vault_pass*` |
| `README.md`, `KVM-NOTES.md`, `roles/compute_packages/README.md`, `validate-compute.yml` | xCAT wording and steps |

## Checked here (not on your master)

- `--syntax-check` of master, compute, site, validate-compute and lab/provision-master for the kvm, vbox and supermicro inventories
- ansible-lint: production profile, 0 failures
- shellcheck: hpc-node, hpc-node-configure, lib.sh, preflight.sh, lab-node.sh
- Kickstart and `hpc_bootstrap` rendered with your KVM values; `bash -n` on both
- `hpc-node` run against stand-ins for xCAT, IPMI and SSH: provision → READY,
  playbook failure → FAILED, cancel, unknown node refused

Not yet run on a live xCAT master: take a snapshot before `--tags xcat,provisioning`.
