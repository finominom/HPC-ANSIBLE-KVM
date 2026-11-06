# compute_packages

Node software (OpenMPI, compilers, hwloc, Slurm, MUNGE, Lmod, ...) is downloaded to
the master first, into the local repo `foo` (/var/www/html/foo), and compute nodes
install and update from `foo` only.

## Add to the project

    tar xzf hpc-ansible-roles.tar.gz -C /opt/hpc-ansible/roles/

master.yml (master play):

    roles:
      - { role: compute_packages, hpc_packages_action: stage }

compute.yml (compute play), before the lmod / slurm roles:

    roles:
      - { role: compute_packages, hpc_packages_action: install }

## Use

    # 1. edit hpc_compute_packages / hpc_epel_packages (group_vars or defaults/main.yml)
    # 2. stage on the master: download with all deps, createrepo, repoclosure check
    ansible-playbook -i inventory/kvm/cobbler.ini master.yml --tags packages
    # 3. update installed nodes, no reinstall
    ansible-playbook -i inventory/kvm/cobbler.ini compute.yml --tags packages
    #    (newly provisioned nodes get it automatically: hpc-node runs compute.yml)

If the master has no internet either, run the same `dnf download --resolve --alldeps`
on an AlmaLinux 9 machine that has (your WSL), rsync the RPMs into
/var/www/html/foo/staged/ on the master, and run step 2: download is skipped for
files already there.
