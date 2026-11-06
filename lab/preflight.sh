#!/usr/bin/env bash
# preflight.sh -- run on the MASTER VM as root, before provisioning or after any change.
# Turns each assumption about the build into a PASS/WARN/FAIL line.
set -u
ISO=${ISO:-/data/isos/AlmaLinux-9-latest-x86_64-minimal.iso}
EXPECT_SHA=${EXPECT_SHA:-}          # paste the SHA-256 from the mirror's CHECKSUM file
DISTRO=${DISTRO:-AlmaLinux-9-minimal-x86_64}
PROFILE=${PROFILE:-alma9-min}
SYSTEM=${SYSTEM:-c01}
MASTER_IP=${MASTER_IP:-192.168.16.1}
MNT=/mnt/preflight-iso
fails=0
ok()   { echo "PASS  $*"; }
warn() { echo "WARN  $*"; }
bad()  { echo "FAIL  $*"; fails=$((fails+1)); }

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }

echo "== ISO"
if [[ -f $ISO ]]; then
  sha=$(sha256sum "$ISO" | cut -d' ' -f1); echo "      sha256 $sha"
  if [[ -z $EXPECT_SHA ]]; then warn "EXPECT_SHA not set; compare the hash above with the mirror's CHECKSUM file"
  elif [[ $sha == "$EXPECT_SHA" ]]; then ok "hash matches"; else bad "hash differs from EXPECT_SHA"; fi
  mkdir -p $MNT; trap 'umount $MNT 2>/dev/null' EXIT
  if mount -o loop,ro "$ISO" $MNT 2>/dev/null; then
    grep -E '^(name|version|repository) ' $MNT/.treeinfo | sed 's/^/      /'
    comps=$(ls $MNT/Minimal/repodata/*comps*.xml 2>/dev/null | head -1)
    if [[ -n $comps ]]; then
      grep -q '<id>minimal-environment</id>' "$comps" && ok "environment minimal-environment exists" \
        || warn "no minimal-environment: use @core in the kickstart"
      grep -q '<id>core</id>' "$comps" && ok "group core exists" || bad "group core missing"
    else bad "no comps file under Minimal/repodata"; fi
    for p in nfs-utils chrony openssh-server python3 curl tar; do
      ls $MNT/Minimal/Packages/ | grep -q "^$p-[0-9]" && ok "package $p on ISO" || warn "package $p NOT on ISO (install it from Ansible/foo instead)"
    done
    umount $MNT
  else bad "cannot loop-mount $ISO"; fi
else bad "ISO not found: $ISO"; fi

echo "== Name resolution on the master"
getent hosts c01.hpc >/dev/null && ok "c01.hpc resolves" || warn "c01.hpc does not resolve: hpc-node-configure ssh by name will fail (hpc_manage_master_hosts adds it)"

echo "== Cobbler import signatures (will 'cobbler import' accept a Minimal ISO?)"
python3 - <<'PY'
import json
d=json.load(open('/var/lib/cobbler/distro_signatures.json'))
for breed,vers in d.get('breeds',{}).items():
    for osv,sig in vers.items():
        if 'alma' in osv.lower() or osv=='rhel9':
            print("      %s/%s signatures=%s" % (breed,osv,sig.get('signatures')))
PY
python3 -c "
import json
d=json.load(open('/var/lib/cobbler/distro_signatures.json'))
print(any('Minimal' in (s.get('signatures') or []) for v in d.get('breeds',{}).values() for o,s in v.items() if 'alma' in o.lower() or o=='rhel9'))" | grep -q True \
  && ok "a signature accepts 'Minimal'; import may work" \
  || warn "no signature accepts a Minimal tree: use rsync + 'cobbler distro add' (set tree=...), not 'cobbler import'"

echo "== Cobbler settings"
for k in pxe_just_once run_install_triggers server next_server_v4 manage_dhcp_v4 default_password_crypted; do
  line=$(grep -E "^$k:" /etc/cobbler/settings.yaml || echo "$k: <not set>"); echo "      ${line:0:60}"
done
grep -E '^default_password_crypted:' /etc/cobbler/settings.yaml | grep -q 'mF86/UHC' \
  && bad "default_password_crypted is still the shipped hash (password 'cobbler')" || ok "default_password_crypted changed"
grep -qE '^pxe_just_once: *(true|True)' /etc/cobbler/settings.yaml && ok "pxe_just_once on" || warn "pxe_just_once not true"
grep -qE '^run_install_triggers: *(true|True)' /etc/cobbler/settings.yaml && ok "run_install_triggers on" || warn "run_install_triggers not true"

echo "== Distro / profile / tree"
cobbler distro report --name="$DISTRO" >/dev/null 2>&1 && ok "distro $DISTRO" || bad "distro $DISTRO missing"
cobbler distro report --name="$DISTRO" 2>/dev/null | grep -qi 'tree' && ok "distro has tree metadata" || bad "no tree= in distro autoinstall-meta (installer gets literal \$tree)"
cobbler profile report --name="$PROFILE" >/dev/null 2>&1 && ok "profile $PROFILE" || bad "profile $PROFILE missing"
for p in .treeinfo Minimal/repodata/repomd.xml; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "http://$MASTER_IP/cobbler/distro_mirror/$DISTRO/$p")
  [[ $c == 200 ]] && ok "HTTP 200 $p" || bad "HTTP $c for $p"
done

echo "== Rendered kickstart for $SYSTEM"
if curl -fsS "http://$MASTER_IP/cblr/svc/op/autoinstall/system/$SYSTEM" -o /tmp/ks.rendered; then
  grep -nE '<paste|\$tree|#raw|#end raw|Traceback|Cheetah|\$getVar' /tmp/ks.rendered && bad "unrendered template text in kickstart" || ok "no leftover template text"
  grep -E '^rootpw' /tmp/ks.rendered | cut -c1-24 | sed 's/^/      /'
  grep -qE '^rootpw --iscrypted \$[0-9a-z]+\$[^ ]{8,}' /tmp/ks.rendered && ok "rootpw looks like a real hash" || bad "rootpw line is not a crypt hash"
  grep -E '^(url|repo|network)' /tmp/ks.rendered | sed 's/^/      /'
  command -v ksvalidator >/dev/null && { ksvalidator -v RHEL9 /tmp/ks.rendered >/dev/null 2>&1 && ok "ksvalidator RHEL9" || bad "ksvalidator reports errors"; }
else bad "cannot fetch kickstart for $SYSTEM (system missing?)"; fi

echo "== Services, network, boot files"
for s in cobblerd httpd dhcpd tftp.socket; do systemctl is-active -q $s && ok "$s active" || bad "$s not active"; done
fw=$(firewall-cmd --list-services 2>/dev/null); for s in dhcp tftp http; do [[ " $fw " == *" $s "* ]] && ok "firewall: $s" || bad "firewall missing $s"; done
[[ -f /var/lib/tftpboot/pxelinux.0 ]] && ok "pxelinux.0" || bad "pxelinux.0 missing (dnf install syslinux; cobbler mkloaders; cobbler sync)"
grep -q "^subnet" /etc/dhcp/dhcpd.conf && ok "dhcpd.conf has a subnet" || bad "no subnet in dhcpd.conf"
grep -q fixed-address /etc/dhcp/dhcpd.conf && ok "host entries in dhcpd.conf" || warn "no fixed-address entries"

echo "== cobbler check"; cobbler check 2>&1 | sed 's/^/      /'
echo; echo "Result: $fails FAIL"; exit $fails
