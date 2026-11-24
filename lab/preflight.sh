#!/usr/bin/env bash
# preflight.sh -- run on the MASTER VM as root, after "lab/provision-master.yml"
# and before "hpc-node provision". Turns each assumption about the xCAT build
# into a PASS/WARN/FAIL line.
set -u
ISO=${ISO:-/data/isos/AlmaLinux-9-latest-x86_64-minimal.iso}
EXPECT_SHA=${EXPECT_SHA:-7762a4b45a66235726db145a573658964bf77bf7b9bc1c018afe86a4cf37cc2e}
OSVER=${OSVER:-alma9.8}
OSIMAGE=${OSIMAGE:-hpc-$OSVER-x86_64-install-compute}
NODE=${NODE:-c01}
MASTER_IP=${MASTER_IP:-192.168.16.1}
CLUSTER_IF=${CLUSTER_IF:-enp8s0}
CLUSTER_NET=${CLUSTER_NET:-192.168.16.0}
fails=0
ok()   { echo "PASS  $*"; }
warn() { echo "WARN  $*"; }
bad()  { echo "FAIL  $*"; fails=$((fails+1)); }

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }
# shellcheck source=/dev/null
[ -r /etc/profile.d/xcat.sh ] && source /etc/profile.d/xcat.sh

echo "== ISO"
if [[ -f $ISO ]]; then
  sha=$(sha256sum "$ISO" | cut -d' ' -f1)
  [[ $sha == "$EXPECT_SHA" ]] && ok "ISO hash matches" || bad "ISO hash $sha differs from EXPECT_SHA"
else bad "ISO not found: $ISO"; fi

echo "== xCAT"
systemctl is-active -q xcatd && ok "xcatd active" || bad "xcatd not active"
command -v lsxcatd >/dev/null && ok "xCAT $(lsxcatd -v 2>/dev/null | head -1)" || bad "xCAT commands missing"
m=$(lsdef -t site -o clustersite -i master -c 2>/dev/null | awk -F= '{print $2}')
[[ $m == "$MASTER_IP" ]] && ok "site.master = $m" || bad "site.master is '$m', expected $MASTER_IP"
d=$(lsdef -t site -o clustersite -i dhcpinterfaces -c 2>/dev/null | awk -F= '{print $2}')
[[ $d == "$CLUSTER_IF" ]] && ok "site.dhcpinterfaces = $d" || bad "site.dhcpinterfaces is '$d', expected $CLUSTER_IF"
nets=$(lsdef -t network -s 2>/dev/null | grep -c '(network)')
[[ $nets == 1 ]] && ok "one network object (hpcnet)" || bad "$nets network objects; only hpcnet should exist"

echo "== Media, osimage, mirrors"
[[ -f /install/$OSVER/x86_64/.treeinfo ]] && ok "copycds done (/install/$OSVER/x86_64)" || bad "media not in /install/$OSVER/x86_64"
lsdef -t osimage -o "$OSIMAGE" >/dev/null 2>&1 && ok "osimage $OSIMAGE" || bad "osimage $OSIMAGE missing"
for p in install/$OSVER/x86_64/.treeinfo repos/baseos/repodata/repomd.xml repos/appstream/repodata/repomd.xml \
         repos/crb/repodata/repomd.xml repos/epel-lmod/repodata/repomd.xml; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "http://$MASTER_IP/$p")
  [[ $c == 200 ]] && ok "HTTP 200 /$p" || bad "HTTP $c for /$p"
done

echo "== Node $NODE"
if lsdef -t node -o "$NODE" >/dev/null 2>&1; then
  ok "node $NODE defined"
  lsdef "$NODE" -i mac,ip,netboot,postbootscripts -c | sed 's/^/      /'
  getent hosts "$NODE.hpc" >/dev/null && ok "$NODE.hpc resolves" || bad "$NODE.hpc does not resolve (bind role, self-DNS)"
  grep -q "^$NODE.hpc," /etc/ssh/ssh_known_hosts 2>/dev/null && ok "$NODE host key trusted" || warn "$NODE not in /etc/ssh/ssh_known_hosts"
else bad "node $NODE not defined (xcat_mac in host_vars?)"; fi
[[ -x /install/postscripts/hpc_bootstrap ]] && ok "first-boot script hpc_bootstrap" || bad "hpc_bootstrap missing"

echo "== DHCP (stop gate D)"
if systemctl is-active -q dhcpd; then
  ok "dhcpd active"
  subs=$(grep -cE '^\s*subnet ' /etc/dhcp/dhcpd.conf)
  grep -qE "^\s*subnet $CLUSTER_NET " /etc/dhcp/dhcpd.conf && [[ $subs == 1 ]] \
    && ok "dhcpd.conf has only the cluster subnet" || bad "dhcpd.conf subnets: $subs (only $CLUSTER_NET allowed)"
  ps -C dhcpd -o args= | grep -q "$CLUSTER_IF\$" && ok "dhcpd pinned to $CLUSTER_IF" || bad "dhcpd not pinned to $CLUSTER_IF"
  makedhcp -q "$NODE" 2>/dev/null | grep -q hardware-address && ok "$NODE has a fixed address" || warn "$NODE not in DHCP yet (makedhcp $NODE)"
else warn "dhcpd not running: stop gate D not opened yet"; fi

echo "== Services and firewall"
for s in httpd xcatd named firewalld; do systemctl is-active -q $s && ok "$s active" || bad "$s not active"; done
fw=$(firewall-cmd --zone=internal --list-all 2>/dev/null)
for s in dhcp tftp http; do echo "$fw" | grep -q "services:.*\b$s\b" && ok "firewall internal: $s" || bad "firewall internal missing $s"; done
for p in 3001/tcp 3002/tcp; do echo "$fw" | grep -q "$p" && ok "firewall internal: $p" || bad "firewall internal missing $p"; done
[[ $(getenforce) != Disabled ]] && ok "SELinux $(getenforce)" || warn "SELinux disabled (role sets permissive; reboot once)"
grep -qE '^/(install|tftpboot)\s' /etc/exports && bad "/install or /tftpboot exported over NFS" || ok "no xCAT NFS exports"

echo "== hpc-node"
[[ -x /usr/local/sbin/hpc-node ]] && ok "hpc-node installed" || bad "hpc-node missing (hpc_provisioning role)"
[[ -r /root/.vault_pass ]] && ok "/root/.vault_pass present (unattended Ansible)" || warn "/root/.vault_pass missing: hpc-node's Ansible step will fail on vault files"
[[ -r /root/.ipmi-mhpc ]] && ok "BMC password file" || warn "/root/.ipmi-mhpc missing (vault_ipmi_password)"
# shellcheck source=/dev/null
( source /etc/hpc-provision.conf && ipmi "$NODE" power status ) 2>/dev/null | grep -q 'Chassis Power' \
  && ok "VirtualBMC answers for $NODE" || warn "no IPMI answer for $NODE (vbmcd on the host? use --no-power)"

echo; echo "Result: $fails FAIL"; exit $fails
