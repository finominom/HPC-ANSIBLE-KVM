# Lab rebuild loop (xCAT)

One-time, HOST:    cp vbmcd.service /etc/systemd/system/ && systemctl enable --now vbmcd
                   (mgmt network already has <ip address='192.168.0.254' .../>; firewall allows 6231-6246/udp)
One-time, MASTER:  1. put vault_ipmi_password (the VBMC_PASS) and vault_grafana_admin_password in the vault
                   2. ansible-playbook lab/provision-master.yml --ask-vault-pass            # xCAT, osimage, nodes; DHCP off
                   3. lab/preflight.sh                                                     # every FAIL fixed before the next step
                   4. ansible-playbook lab/provision-master.yml --ask-vault-pass -e xcat_enable_dhcp=true   # stop gate D
                   5. echo '<vault password>' > /root/.vault_pass && chmod 600 /root/.vault_pass   # unattended Ansible runs

Every rebuild:
  HOST    VBMC_PASS=... HPC_NET=hpc ./lab-node.sh recreate 1
  MASTER  hpc-node provision c01 --yes     # nodeset, power off/on, install, boot-from-disk, configure, validate
  MASTER  hpc-node status ; hpc-node log c01

Watch an install:  on the HOST virsh console c01 ; on the MASTER lsdef c01 -i status ; less /install/autoinst/c01
