#!/bin/bash
set -euo pipefail

# setup-network.sh - Network infrastructure setup for SRv6 + L2 EVPN
#
# This script creates the network infrastructure (VRF, L2 VXLAN, bridge)
# via grout. L3VPN is handled by SRv6 (no L3VNI VXLAN needed).
# L2VPN still uses VXLAN overlay.
#
# Usage: Executed by setup-network.service after setup-underlay.service
#
# Exit codes:
#   0   - Success
#   1   - Error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
if [[ ! -f "$SCRIPT_DIR/openperouter-common.sh" ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: openperouter-common.sh not found" >&2
    exit 1
fi

source "$SCRIPT_DIR/openperouter-common.sh"

# Load variables from setup-underlay.sh if available
VARS_FILE="${VARS_FILE:-/var/lib/openperouter/vpn-setup.vars}"
if [[ -f "$VARS_FILE" ]]; then
    log "Loading variables from $VARS_FILE"
    source "$VARS_FILE"
else
    log "Variables file not found, using environment variables"
fi

# Parameters (from environment or defaults)
VRF_NAME="${VRF_NAME:-red}"
L2_VNI="${L2_VNI:-210}"
L2_GATEWAY_IP="${L2_GATEWAY_IP:-192.168.110.1/24}"
L2_GATEWAY_IP_V6="${L2_GATEWAY_IP_V6:-fd00:110::1/64}"
VTEP_IP="${VTEP_IP:-$ROUTER_ID}"
TRUNK_NIC="${TRUNK_NIC:-eno12399v1}"
TRUNK_VLAN="${TRUNK_NIC}.42"

if [[ -z "$VTEP_IP" ]]; then
    error "VTEP_IP not set - must be provided via $VARS_FILE or environment"
    error "Run setup-underlay.service first to generate variables"
    exit 1
fi

grcli() {
    echo "+ grcli $*"
    podman exec grout grcli "$@"
}

L2_BRIDGE="br-pe-${L2_VNI}"
L2_VXLAN="vni${L2_VNI}"

log "Setting up network infrastructure via grout"

# Assign addresses on underlay port (VTEP, loopback, SRv6 source)
grcli address add ${VTEP_IP}/32 iface $UNDERLAY_NIC
grcli address add ${UNDERLAY_V6}/128 iface $UNDERLAY_NIC
grcli address add ${LOOPBACK_V6}/128 iface $UNDERLAY_NIC
grcli address add ${SRV6_SOURCE}/128 iface $UNDERLAY_NIC

# Create VRF, bridge, VXLAN, VLAN sub-interface
grcli interface add vrf $VRF_NAME
grcli interface add bridge $L2_BRIDGE vrf $VRF_NAME
grcli interface add vxlan $L2_VXLAN vni $L2_VNI local $VTEP_IP encap_vrf main domain $L2_BRIDGE
grcli interface add vlan $TRUNK_VLAN parent $TRUNK_NIC vlan_id 42 domain $L2_BRIDGE

# Assign gateway IPs on bridge
grcli address add $L2_GATEWAY_IP iface $L2_BRIDGE
if [[ -n "${L2_GATEWAY_IP_V6}" ]]; then
    grcli address add $L2_GATEWAY_IP_V6 iface $L2_BRIDGE
fi

exit 0
