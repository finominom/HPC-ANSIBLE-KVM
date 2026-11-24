# shellcheck shell=bash
# lib.sh (/usr/local/lib/hpc-provision) -- shared helpers for hpc-node and hpc-node-configure
# shellcheck source=/dev/null
source /etc/hpc-provision.conf
# xCAT commands (nodeset, lsdef, nodels) and XCATROOT
[ -r /etc/profile.d/xcat.sh ] && { set +u; source /etc/profile.d/xcat.sh; set -u; }
export PATH="/opt/xcat/bin:/opt/xcat/sbin:$PATH" XCATROOT="${XCATROOT:-/opt/xcat}" HOME="${HOME:-/root}"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$JOB_DIR"

# ansible-playbook runs from systemd with nobody to type the vault password
if [ -n "${VAULT_PASSWORD_FILE:-}" ] && [ -r "$VAULT_PASSWORD_FILE" ]; then
    export ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PASSWORD_FILE"
fi

die() { echo "ERROR: $*" >&2; exit 1; }

valid_node() { [[ "$1" =~ $NODES_REGEX ]] || die "'$1' is not a compute node name ($NODES_REGEX)"; }

job_get() { cat "$STATE_DIR/$1.job" 2>/dev/null || echo none; }

# state_set <node> <STATE> [message]  -- append one line: time, state, job, message
state_set() {
    local node=$1 st=$2 msg=${3:-}
    printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$st" "$(job_get "$node")" "$msg" >> "$STATE_DIR/$node"
    logger -t hpc-provision "$node $st job=$(job_get "$node") $msg"
}

state_get()  { tail -n1 "$STATE_DIR/$1" 2>/dev/null | cut -f2; }
state_line() { tail -n1 "$STATE_DIR/$1" 2>/dev/null; }

# Is the node defined in xCAT?
xcat_node_exists() { lsdef -t node -o "$1" >/dev/null 2>&1; }

# What xCAT answers the node's next network boot with: "install" or "boot"
# (boot = "boot from the local disk"). Replaces Cobbler's netboot flag.
netboot_state() {
    nodels "$1" chain.currstate 2>/dev/null | awk -F': ' 'NR==1 {split($2, a, " "); print (a[1] == "" ? "-" : a[1])}'
}

# xCAT's install status of the node: installing, booting, booted, ...
node_status() {
    lsdef -t node -o "$1" -i status -c 2>/dev/null | awk -F'status=' 'NF > 1 {print $2; exit}'
}

node_ip() { getent hosts "$1.$NODE_DOMAIN" | awk '{print $1; exit}'; }

# Forget the node's old SSH host keys in root's own known_hosts (a Cobbler-era
# install left different ones there). The keys xCAT gives every node are in
# /etc/ssh/ssh_known_hosts (xcat role) and stay valid across reinstalls.
forget_hostkeys() {
    local node=$1 ip h
    ip=$(node_ip "$node")
    for h in "$node" "$node.$NODE_DOMAIN" $ip; do
        ssh-keygen -R "$h" -f /root/.ssh/known_hosts >/dev/null 2>&1 || true
    done
}

# Restart a node's power with plain off -> wait -> on.
# ("chassis power cycle" is rejected by VirtualBMC, and "reset" does not re-read a changed
#  boot order, so off/on is the only form that works everywhere.)
power_restart() {
    local n=$1
    if ipmi "$n" power status | grep -q 'is on'; then
        ipmi "$n" power off >/dev/null || return 1
        for _ in $(seq 1 30); do
            ipmi "$n" power status | grep -q 'is off' && break
            sleep 2
        done
    fi
    ipmi "$n" power on >/dev/null
}
