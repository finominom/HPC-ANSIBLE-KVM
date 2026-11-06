# /usr/local/lib/hpc-provision/lib.sh -- shared helpers for the hpc-* provisioning scripts
# shellcheck shell=bash
source /etc/hpc-provision.conf

mkdir -p "$STATE_DIR" "$LOG_DIR"

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

# prints True or False as Cobbler reports it
netboot_enabled() {
    cobbler system report --name="$1" 2>/dev/null \
        | awk -F: '/^Netboot Enabled/ {gsub(/[[:space:]]/, "", $2); print $2; exit}'
}

node_ip() { getent hosts "$1.$NODE_DOMAIN" | awk '{print $1; exit}'; }

# forget the node's old SSH host keys (they change on every reinstall)
forget_hostkeys() {
    local node=$1 ip
    ip=$(node_ip "$node")
    for h in "$node" "$node.$NODE_DOMAIN" $ip; do
        ssh-keygen -R "$h" >/dev/null 2>&1 || true
    done
}

learn_hostkeys() {
    local node=$1 ip
    ip=$(node_ip "$node")
    ssh-keyscan -T 10 "$node" "$node.$NODE_DOMAIN" $ip 2>/dev/null >> /root/.ssh/known_hosts
}

# Restart a node's power with plain off -> wait -> on.
# ("chassis power cycle" is rejected by VirtualBMC, and "reset" does not re-read a changed
#  boot order, so off/on is the only form that works everywhere.)
power_restart() {
    local n=$1 i
    if ipmi "$n" power status | grep -q 'is on'; then
        ipmi "$n" power off >/dev/null || return 1
        for i in $(seq 1 30); do
            ipmi "$n" power status | grep -q 'is off' && break
            sleep 2
        done
    fi
    ipmi "$n" power on >/dev/null
}
