#!/bin/bash
# ============================================================
#  secure_wol.sh : on the CLIENT (the device that connects).
#  Asks the Debian gateway to wake the target, waits for it to
#  boot, then opens an SSH session on the target machine by
#  jumping through the gateway.
#
#  Usage :  ./secure_wol.sh              wake + wait + connect
#                                        (if the target is already on,
#                                        the wait ends immediately)
#           ./secure_wol.sh --wake       wake only
#           ./secure_wol.sh --connect    connect only
#
#  First run :  HOSTKEY_POLICY=ask ./secure_wol.sh --connect
#
#  Run as a normal user, NEVER with sudo : ssh must use YOUR
#  keys and YOUR known_hosts, not root's.
#
#  Real access control is enforced by the gateway (firewall
#  + sshd). This script deliberately contains no allowlist :
#  a client-side check could be bypassed.
#
#  See README.md for the full procedure.
# ============================================================
set -euo pipefail

# ------------------------------------------------------------
# CONFIGURATION : fill in before the first run
# ------------------------------------------------------------
# Address of the Debian gateway from OUTSIDE : public IP of its
# router, or a DynDNS name. If you only use it at home, put its
# local IP here.
PROXY_IP=""
PROXY_PORT="22"          # port forwarded by the router to the gateway

# Optional : local IP of the gateway. If it answers, it is used
# instead of PROXY_IP (useful at home : many routers cannot
# loop back to their own public IP).
PROXY_IP_LOCAL=""
PROXY_PORT_LOCAL="22"

PROXY_USER="jumpuser"    # jump account created by install_proxy_debian.sh
TARGET_IP=""             # local IP of the machine to wake
TARGET_PORT="22"
TARGET_USER=""           # your account on the machine to wake

# Two separate keys, protected by a passphrase
JUMP_KEY="${HOME}/.ssh/id_ed25519_wol_proxy"
TARGET_KEY="${HOME}/.ssh/id_ed25519_wol_target"
KNOWN_HOSTS="${HOME}/.ssh/known_hosts"

# "yes" in normal use. "ask" only for the very first
# connection, after checking the fingerprints.
HOSTKEY_POLICY="${HOSTKEY_POLICY:-yes}"

BOOT_TIMEOUT=120         # max seconds to wait for the boot
# ------------------------------------------------------------

R='\033[1;31m' G='\033[1;32m' Y='\033[1;33m' C='\033[1;36m' N='\033[0m'
info() { echo -e "${C}[i]${N} $*"; }
ok()   { echo -e "${G}[ok]${N} $*"; }
fail() { echo -e "${R}[x]${N} $*" >&2; }
warn() { echo -e "${Y}[!]${N} $*"; }
die()  { fail "$*"; exit 1; }

valid_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}
# IPv4 or host name (DynDNS)
valid_host() {
    valid_ipv4 "$1" && return 0
    [[ ! $1 =~ ^[0-9.]+$ ]] \
      && [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_user() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

check_prereqs() {
    [[ $EUID -ne 0 ]] || die "Do not run this script with sudo or as root."
    command -v ssh >/dev/null || die "ssh not found (package openssh-client)."

    local missing=() v
    for v in PROXY_IP TARGET_IP TARGET_USER; do [[ -n ${!v} ]] || missing+=("$v"); done
    (( ${#missing[@]} == 0 )) || die "Fill in the CONFIGURATION block : ${missing[*]}"

    valid_host "$PROXY_IP"    || die "Invalid PROXY_IP : '$PROXY_IP'"
    valid_ipv4 "$TARGET_IP"   || die "Invalid TARGET_IP : '$TARGET_IP'"
    valid_port "$PROXY_PORT"  || die "Invalid PROXY_PORT : '$PROXY_PORT'"
    valid_port "$TARGET_PORT" || die "Invalid TARGET_PORT : '$TARGET_PORT'"
    valid_user "$PROXY_USER"  || die "Invalid PROXY_USER : '$PROXY_USER'"
    valid_user "$TARGET_USER" || die "Invalid TARGET_USER : '$TARGET_USER'"
    if [[ -n $PROXY_IP_LOCAL ]]; then
        valid_ipv4 "$PROXY_IP_LOCAL"   || die "Invalid PROXY_IP_LOCAL : '$PROXY_IP_LOCAL'"
        valid_port "$PROXY_PORT_LOCAL" || die "Invalid PROXY_PORT_LOCAL : '$PROXY_PORT_LOCAL'"
    fi
    [[ $HOSTKEY_POLICY == yes || $HOSTKEY_POLICY == ask ]] \
        || die "HOSTKEY_POLICY must be yes or ask"
}

check_keys() {
    local k perm
    for k in "$@"; do
        [[ -f $k ]] || die "Missing key : $k (create it : ssh-keygen -t ed25519 -f $k)"
        perm=$(stat -c %a "$k")
        [[ $perm == 600 || $perm == 400 ]] || die "Permissions too open on $k (chmod 600 $k)"
    done
}

# Gateway address : local if it answers, otherwise the outside
# address. A wrong machine answering instead would be rejected
# by the host key check.
ACTIVE_IP="" ACTIVE_PORT=""
select_proxy() {
    ACTIVE_IP=$PROXY_IP ACTIVE_PORT=$PROXY_PORT
    if [[ -n $PROXY_IP_LOCAL ]] \
       && timeout 2 bash -c ": </dev/tcp/${PROXY_IP_LOCAL}/${PROXY_PORT_LOCAL}" 2>/dev/null; then
        ACTIVE_IP=$PROXY_IP_LOCAL ACTIVE_PORT=$PROXY_PORT_LOCAL
        info "Gateway reachable on the local network."
    fi
}

SSH_CFG=""
AGENT_STARTED=0
cleanup() {
    [[ -n $SSH_CFG ]] && rm -f "$SSH_CFG"
    # Only stop the agent started by this script
    if (( AGENT_STARTED )); then ssh-agent -k >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

# Loads the keys into an ssh agent : each passphrase is asked
# only ONCE, and the wait checks (no keyboard) can authenticate
# while the target boots.
load_keys() {
    local rc=0 k fp
    ssh-add -l >/dev/null 2>&1 || rc=$?
    if (( rc == 2 )); then          # 2 = no reachable agent
        eval "$(ssh-agent -s)" >/dev/null
        AGENT_STARTED=1
    fi
    for k in "$@"; do
        fp=$(ssh-keygen -lf "${k}.pub" 2>/dev/null | awk '{print $2}')
        if [[ -n $fp ]] && ssh-add -l 2>/dev/null | grep -qF "$fp"; then
            continue
        fi
        info "Passphrase for key $(basename "$k") :"
        ssh-add "$k" || die "Cannot load key $k"
    done
}

# Temporary ssh configuration. HostKeyAlias : a single remembered
# fingerprint per machine, whether reached by local or public IP.
make_ssh_config() {
    SSH_CFG=$(mktemp)
    cat > "$SSH_CFG" <<EOF
Host wol-proxy
    HostName ${ACTIVE_IP}
    Port ${ACTIVE_PORT}
    User ${PROXY_USER}
    HostKeyAlias wol-proxy
    IdentityFile ${JUMP_KEY}
    IdentitiesOnly yes
    StrictHostKeyChecking ${HOSTKEY_POLICY}
    UserKnownHostsFile ${KNOWN_HOSTS}
    ForwardAgent no
    ForwardX11 no
    RequestTTY no
    ConnectTimeout 8

Host wol-target
    HostName ${TARGET_IP}
    Port ${TARGET_PORT}
    User ${TARGET_USER}
    HostKeyAlias wol-target
    IdentityFile ${TARGET_KEY}
    IdentitiesOnly yes
    StrictHostKeyChecking ${HOSTKEY_POLICY}
    UserKnownHostsFile ${KNOWN_HOSTS}
    ProxyJump wol-proxy
    ForwardAgent no
    ForwardX11 no
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ConnectTimeout 10
EOF
}

# Wake-up : the gateway enforces (ForceCommand) the WoL command
# for the only allowed MAC. The client sends no command.
wake_target() {
    info "Asking ${PROXY_USER}@${ACTIVE_IP}:${ACTIVE_PORT} to wake the target ..."
    if ssh -F "$SSH_CFG" -T wol-proxy </dev/null; then
        ok "Wake-on-LAN packet sent by the gateway."
    else
        die "The gateway could not send the wake-up (key, allowed IP, network ? see README)."
    fi
}

# Wait : checks the target's SSH port THROUGH the gateway.
# A ready SSH server answers with an "SSH-" banner.
wait_target() {
    info "Waiting for ${TARGET_IP} to boot (max ${BOOT_TIMEOUT} s) ..."
    local start banner
    start=$SECONDS
    while (( SECONDS - start < BOOT_TIMEOUT )); do
        # BatchMode : no questions, fails at once instead of hanging
        banner=$( { sleep 3; } | timeout 10 ssh -F "$SSH_CFG" -o BatchMode=yes \
                    -W "${TARGET_IP}:${TARGET_PORT}" wol-proxy 2>/dev/null \
                    | head -c 4 || true )
        if [[ $banner == "SSH-" ]]; then
            ok "Target SSH is available."
            return 0
        fi
        sleep 5
    done
    warn "No SSH answer from the target after ${BOOT_TIMEOUT} s."
    return 1
}

connect_target() {
    info "Opening session ${TARGET_USER}@${TARGET_IP} through the gateway ..."
    ssh -F "$SSH_CFG" wol-target
}

main() {
    local mode=${1:-all} r
    case $mode in
        all|--wake|--connect) ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "Usage: $0 [--wake|--connect]"; exit 1 ;;
    esac

    check_prereqs
    case $mode in
        --wake)      check_keys "$JUMP_KEY" ;;
        *)           check_keys "$JUMP_KEY" "$TARGET_KEY" ;;
    esac
    select_proxy
    make_ssh_config

    echo
    info "Gateway : ${PROXY_USER}@${ACTIVE_IP}:${ACTIVE_PORT}"
    info "Target  : ${TARGET_USER}@${TARGET_IP}:${TARGET_PORT}"
    echo

    case $mode in
        --wake)      load_keys "$JUMP_KEY" ;;
        *)           load_keys "$JUMP_KEY" "$TARGET_KEY" ;;
    esac

    if [[ $mode == all || $mode == --wake ]]; then
        wake_target
        [[ $mode == --wake ]] && exit 0
        if ! wait_target; then
            read -rp "Try to connect anyway ? [y/N] " r
            [[ $r =~ ^[yYoO] ]] || exit 1
        fi
    fi

    connect_target
}

main "$@"
