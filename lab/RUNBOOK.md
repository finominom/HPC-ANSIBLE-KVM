# Lab rebuild loop

One-time, HOST:    cp vbmcd.service /etc/systemd/system/ && systemctl enable --now vbmcd
                   (mgmt network already has <ip address='192.168.0.254' .../>; firewall allows 6231-6246/udp)
One-time, MASTER:  1. tar xzf hpc-ansible-roles-fixed.tar.gz -C /opt/hpc-ansible/roles/ --strip-components=0   (roles + lab/)
                   2. copy lab/group_vars-master.yml.example into group_vars, fill the sha256 and the vault secrets
                   3. ansible-playbook -i inventory/kvm/cobbler.ini lab/provision-master.yml
                   4. lab/preflight.sh            # every FAIL fixed before the next step
                   Back up first: tar czf /root/cobbler-backup-$(date +%F).tgz /etc/cobbler /var/lib/cobbler/collections /var/lib/cobbler/templates /etc/dhcp

Every rebuild:
  HOST    VBMC_PASS=... HPC_NET=hpc ./lab-node.sh recreate 1
  MASTER  hpc-node provision c01 --yes     # netboot on, power off/on, install, netboot off (kickstart callback), configure, validate
  MASTER  hpc-node status ; hpc-node log c01

If hpc-compute.ks fails where alma9-min.ks worked:  cobbler profile edit --name=alma9-min --autoinstall=alma9-min.ks
