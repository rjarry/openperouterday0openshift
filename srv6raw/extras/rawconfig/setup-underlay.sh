#!/bin/bash
set -euo pipefail

# setup-underlay.sh - Set up underlay infrastructure for OpenPERouter (ISIS + SRv6)
#
# This script:
# 1. Waits for FRR container to be ready
# 2. Derives addressing from host VF / br-ex (Router ID, IPv6 loopbacks, SRv6 locator, ISIS NET)
# 3. Moves underlay NIC to FRR namespace
# 4. Configures IPv4/IPv6 loopback addresses and SRv6 sysctls in FRR namespace
# 5. Saves variables for config generation
#
# Usage: Executed by systemd service setup-underlay.service
#
# Exit codes:
#   0   - Success
#   1   - General error
#   124 - Timeout waiting for FRR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
if [[ ! -f "$SCRIPT_DIR/openperouter-common.sh" ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: openperouter-common.sh not found at $SCRIPT_DIR/openperouter-common.sh" >&2
    exit 1
fi

source "$SCRIPT_DIR/openperouter-common.sh"

# Load environment configuration file
ENV_FILE="${ENV_FILE:-/etc/openperouter/vpn-setup.env}"
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

# Verify required functions
for func in frr_netns_pid inns isfrr_ready; do
    if ! declare -f "$func" >/dev/null 2>&1; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: Required function $func not found in openperouter-common.sh" >&2
        exit 1
    fi
done

# Load environment variables with defaults

UNDERLAY_NIC="${UNDERLAY_NIC:-eno12399v0}"
TRUNK_NIC="${TRUNK_NIC:-eno12399v1}"
HOST_VF="${HOST_VF:-eno12399v2}"
FRR_READY_TIMEOUT="${FRR_READY_TIMEOUT:-60}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
ISIS_AREA="${ISIS_AREA:-49.0001}"

# Output file for variables
VARS_FILE="${VARS_FILE:-/var/lib/openperouter/vpn-setup.vars}"

# Start main execution
log "Starting underlay setup (ISIS + SRv6 mode)"
log "Configuration: UNDERLAY_NIC=$UNDERLAY_NIC, NODE_NAME=$NODE_NAME"

log_step "Waiting for FRR container"
log "Timeout configured: ${FRR_READY_TIMEOUT}s"
ELAPSED=0
INTERVAL=2

while ! isfrr_ready 2>/dev/null; do
    if [ $ELAPSED -ge $FRR_READY_TIMEOUT ]; then
        error "FRR not ready after ${FRR_READY_TIMEOUT}s timeout"
        exit_timeout
    fi
    if [ $((ELAPSED % 10)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
        log "Still waiting for FRR... (${ELAPSED}s elapsed)"
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

log "FRR container is ready"

log_step "Deriving addressing from host interface"

HOST_IP_TIMEOUT="${HOST_IP_TIMEOUT:-120}"
HOST_IP=""
HOST_IP6=""
HOST_IFACE=""

SECONDS=0
while [[ -z "$HOST_IP" ]] || [[ -z "$HOST_IP6" ]]; do
    for iface in "$HOST_VF" br-ex; do
        HOST_IP=$(ip -4 addr show "$iface" scope global 2>/dev/null | sed -En 's,.*\<inet ([0-9\./]+).*,\1,p' | head -1)
        HOST_IP6=$(ip -6 addr show "$iface" scope global 2>/dev/null | sed -En 's,.*\<inet6 ([0-9a-f:/]+).*,\1,p' | head -1)
        if [[ -n "$HOST_IP" ]] && [[ -n "$HOST_IP6" ]]; then
            HOST_IFACE="$iface"
            break
        fi
    done
    if [ $SECONDS -ge $HOST_IP_TIMEOUT ]; then
        error "No host interface ($HOST_VF/br-ex) has an IP after ${SECONDS}s"
        exit_error "Host interface must have an IP address configured"
    fi
    log "Waiting for host IP address... (${SECONDS}s elapsed)"
    sleep 2
done

# Extract last octet — used as node index for all addressing
LAST_OCTET=$(echo "$HOST_IP" | sed -En 's,.*\.([0-9]+)/.*,\1,p')

# Derive all addresses from node index
ROUTER_ID="10.0.0.${LAST_OCTET}"
VTEP_IP="$ROUTER_ID"
LOOPBACK_V6="fc00:0:${LAST_OCTET}::1"
SRV6_SOURCE="fd00:${LAST_OCTET}::1"
SRV6_PREFIX="fd00:${LAST_OCTET}"
SRV6_NODE_ID="${LAST_OCTET}"
UNDERLAY_V6="fc00:100::${LAST_OCTET}"
ISIS_NET="${ISIS_AREA}.0000.0000.$(printf '%04d' "${LAST_OCTET}").00"

log "Host interface: $HOST_IFACE, IP: $HOST_IP, IPv6: $HOST_IP6"
log "Node index (last octet): $LAST_OCTET"
log "  Router ID / VTEP IP: $ROUTER_ID"
log "  Loopback IPv6:       $LOOPBACK_V6"
log "  SRv6 source:         $SRV6_SOURCE"
log "  SRv6 locator:        $SRV6_PREFIX:$SRV6_NODE_ID::/48"
log "  Underlay IPv6:       $UNDERLAY_V6"
log "  ISIS NET:            $ISIS_NET"

FRR_PID=$(frr_netns_pid)
if [[ -z "$FRR_PID" || "$FRR_PID" == "0" ]]; then
    error "Failed to get FRR container PID"
    exit_error "Cannot determine FRR namespace"
fi

log "FRR container PID: $FRR_PID"

UNDERLAY_PCI=$(cut -d' ' -f3 /run/grout-bind/$UNDERLAY_NIC) ||
    exit_error "Failed to determine underlay VF $UNDERLAY_NIC PCI address"
TRUNK_PCI=$(cut -d' ' -f3 /run/grout-bind/$TRUNK_NIC) ||
    exit_error "Failed to determine trunk VF $TRUNK_NIC PCI address"

grcli() {
    echo "+ grcli $*"
    podman exec grout grcli "$@"
}

log "Applying grout configuration..."

grcli interface add port $UNDERLAY_NIC devargs $UNDERLAY_PCI
grcli interface add port $TRUNK_NIC devargs $TRUNK_PCI

log "$UNDERLAY_NIC and $TRUNK_NIC configured"

#
# STEP 5: Save variables for config generation
#
log_step "Saving variables for config generation"

# Create directory if needed
mkdir -p "$(dirname "$VARS_FILE")"

# Write variables (will be sourced by generate-config.sh and setup-network.sh)
cat > "$VARS_FILE" <<EOF
# OpenPERouter VPN Setup Variables (ISIS + SRv6)
# Generated by setup-underlay.sh on $(date +'%Y-%m-%d %H:%M:%S')

# Node identity
NODE_NAME="$NODE_NAME"
LAST_OCTET="$LAST_OCTET"

# Router ID and VTEP (same address — L2 VXLAN uses router-id as source)
ROUTER_ID="$ROUTER_ID"
VTEP_IP="$VTEP_IP"
HOST_IP="$HOST_IP"
HOST_IP6="$HOST_IP6"
HOST_SUBNET="$(ip -4 route list dev "$HOST_IFACE" scope link proto kernel | awk '{print $1; exit}')"
HOST_SUBNET_V6="$(ip -6 route list dev "$HOST_IFACE" scope link proto kernel | awk '{print $1; exit}')"

# IPv6 loopback for BGP peering
LOOPBACK_V6="$LOOPBACK_V6"

# SRv6 addressing
SRV6_SOURCE="$SRV6_SOURCE"
SRV6_PREFIX="$SRV6_PREFIX"
SRV6_NODE_ID="$SRV6_NODE_ID"

# Underlay IPv6
UNDERLAY_V6="$UNDERLAY_V6"

# ISIS
ISIS_NET="$ISIS_NET"

# Underlay NIC
UNDERLAY_NIC="$UNDERLAY_NIC"
FRR_PID="$FRR_PID"
EOF

chmod 644 "$VARS_FILE"

log "Variables saved to $VARS_FILE"

exit_success "Underlay setup completed successfully"
